import { aiToParsed, type AiExtraction } from "@/domain/telegram/ai";
import { formatDateId } from "@/domain/telegram/dates";
import { formatDateEn, L, parseLang, type Lang } from "@/domain/telegram/i18n";
import {
  classifyIntent,
  entityWordOf,
  looksLikeLoanPayment,
  parseExpenseText,
  type ParsedExpense,
} from "@/domain/telegram/message";
import {
  entityIcon,
  entityShort,
  escapeHtml,
  formatSummary,
  joinSummaries,
  parsePeriod,
} from "@/domain/telegram/report";
import {
  apply,
  type DraftState,
  type Env,
  type Keyboard,
  learnEntries,
  parseCallbackData,
  payeeFor,
  render,
  startDraft,
  toRecordPayload,
} from "@/domain/telegram/roadmap";
import { formatRupiah, parseAmounts } from "@/domain/telegram/rupiah";
import { todayInBusinessZone } from "@/lib/time";
import type { SendOptions, TgCallbackQuery, TgMessage, TgResult, TgUpdate } from "./api";
import { errorLine, refusalText } from "./errors";
import { handleAssetCallback, handleLoanCallback, offerAssets, startLoanPayment } from "./followups";
import type { Identity, RecentEntry, RecordResult, TelegramStore } from "./store";

/**
 * The bot's brain (decision 422): one function per Telegram update. It reads the message with fixed rules first and
 * the AI helper only when the rules find nothing, walks the owner through the confirmation roadmap, and records only
 * after the owner presses Simpan. Everything it does to the books goes through the `telegram_*` database functions.
 * Dependencies are injected so the whole flow can be tested without Telegram, Gemini or a database.
 */

export interface BotApi {
  sendMessage(chatId: number, text: string, options?: SendOptions): Promise<TgResult<TgMessage>>;
  editMessage(
    chatId: number,
    messageId: number,
    text: string,
    keyboard?: Keyboard,
  ): Promise<TgResult<TgMessage>>;
  clearKeyboard(chatId: number, messageId: number): Promise<TgResult<unknown>>;
  answerCallback(id: string, text?: string): Promise<TgResult<boolean>>;
  downloadFile(
    fileId: string,
  ): Promise<{ ok: true; bytes: Uint8Array; mime: string } | { ok: false; error: string }>;
  sendChatAction(chatId: number, action: "typing", threadId?: number | null): Promise<unknown>;
}

export interface BotAi {
  enabled(): boolean;
  readText(message: string, today: string): Promise<AiExtraction | null>;
  readReceipt(
    image: { bytes: Uint8Array; mime: string },
    caption: string | undefined,
    today: string,
  ): Promise<AiExtraction | null>;
}

export interface BotDeps {
  store: TelegramStore;
  api: BotApi;
  ai: BotAi;
  now: () => Date;
  /** A random id (crypto.randomUUID). */
  newId: () => string;
  appUrl: string;
}

function helpText(lang: Lang): string {
  return lang === "en"
    ? [
        "👋 <b>I am the Hikarich expense assistant.</b>",
        "",
        "<b>Record an expense</b> — just type like you are chatting:",
        "• <i>lunch at the warteg 35k paid with gopay</i>",
        "• <i>bought an iPhone 15 for the business 15m</i>",
        "• <i>yesterday fuel 50k and parking 5k personal</i>",
        "Or send a <b>receipt photo</b>. I always show a summary and wait for the <b>Save</b> button before recording.",
        "",
        "<b>Entity</b> — say <i>PT</i> (company) or <i>personal</i> in the message. If you do not, I ask first.",
        "",
        "<b>Durable purchases & loan instalments</b> — for a purchase like an iPhone for the business I ask how long it lasts and then activate it as an asset. For a loan instalment type <i>pay instalment</i> or /loan; the amount follows the loan schedule.",
        "",
        "<b>Receipt photos</b> you save are attached to the entry.",
        "",
        "<b>Ask for a summary</b>: <i>expenses today</i>, <i>recap last week</i>, <i>how much this month?</i>",
        "",
        "<b>Commands</b>: /today /thisweek /thismonth /lastmonth /last /loan /undo /cancel /tips /settings /language",
        "Automatic reports (daily, weekly, monthly) and the amount limit are set on the website.",
      ].join("\n")
    : [
        "👋 <b>Saya asisten pencatat pengeluaran Hikarich.</b>",
        "",
        "<b>Catat pengeluaran</b> — cukup ketik seperti ngobrol:",
        "• <i>makan siang di warteg 35rb pakai gopay</i>",
        "• <i>beli iPhone 15 untuk usaha 15jt</i>",
        "• <i>kemarin bensin 50rb dan parkir 5rb pribadi</i>",
        "Atau kirim <b>foto struk</b>. Saya selalu menunjukkan ringkasan dan menunggu tombol <b>Simpan</b> sebelum mencatat.",
        "",
        "<b>Entitas</b> — sebut <i>PT</i> atau <i>pribadi</i> di pesan. Kalau tidak disebut, saya akan bertanya dulu.",
        "",
        "<b>Barang tahan lama & cicilan</b> — pembelian seperti iPhone untuk usaha saya tanyakan masa manfaatnya lalu saya aktifkan sebagai aset. Untuk cicilan pinjaman ketik <i>bayar cicilan</i> atau /cicilan; jumlahnya mengikuti jadwal pinjaman.",
        "",
        "<b>Foto struk</b> yang kamu simpan ikut terlampir di catatan.",
        "",
        "<b>Tanya ringkasan</b>: <i>pengeluaran hari ini</i>, <i>rekap minggu lalu</i>, <i>bulan ini berapa?</i>",
        "",
        "<b>Perintah</b>: /hariini /mingguini /bulanini /bulanlalu /terakhir /cicilan /batalkan /batal /tips /pengaturan /bahasa",
        "Laporan otomatis (harian, mingguan, bulanan) dan batas nominal diatur di website.",
      ].join("\n");
}

const COMMAND_PERIODS: Readonly<Record<string, string>> = {
  hariini: "hari ini",
  kemarin: "kemarin",
  mingguini: "minggu ini",
  minggulalu: "minggu lalu",
  bulanini: "bulan ini",
  bulanlalu: "bulan lalu",
  today: "hari ini",
  yesterday: "kemarin",
  thisweek: "minggu ini",
  lastweek: "minggu lalu",
  thismonth: "bulan ini",
  lastmonth: "bulan lalu",
};

function opts(thread: number, extra: Partial<SendOptions> = {}): SendOptions {
  return { ...(thread ? { threadId: thread } : {}), ...extra };
}

/** Entry point. Never throws: a failing update must not make Telegram retry it forever. */
export async function handleUpdate(update: TgUpdate, deps: BotDeps): Promise<void> {
  try {
    if (!(await deps.store.claimUpdate(update.update_id))) return;
    if (update.callback_query) await handleCallback(update.callback_query, deps);
    else if (update.message) await handleMessage(update.message, deps);
  } catch (error) {
    console.error(
      "telegram update failed",
      update.update_id,
      error instanceof Error ? error.message : "unknown",
    );
    const chat = update.message?.chat.id ?? update.callback_query?.message?.chat.id;
    if (chat !== undefined) {
      await deps.api.sendMessage(
        chat,
        "⚠️ Maaf, ada gangguan saat memproses pesan ini. Coba kirim lagi. / Sorry, something went wrong. Please send it again.",
        opts(update.message?.message_thread_id ?? 0),
      );
    }
  }
}

async function handleMessage(msg: TgMessage, deps: BotDeps): Promise<void> {
  const from = msg.from;
  if (!from || from.is_bot) return;
  const { api, store } = deps;
  const chat = msg.chat.id;
  const thread = msg.message_thread_id ?? 0;
  const isPrivate = msg.chat.type === "private";
  const text = (msg.text ?? msg.caption ?? "").trim();
  const intent = classifyIntent(text);

  // Pairing: /start CODE in a private chat.
  if (isPrivate && intent.kind === "command" && intent.name === "start" && intent.arg.length >= 6) {
    try {
      const paired = await store.redeemCode(intent.arg, from.id, chat, from.username ?? null);
      await api.sendMessage(
        chat,
        `✅ Terhubung sebagai <b>${escapeHtml(paired.displayName)}</b>.\n\n${helpText("id")}\n\n🇬🇧 English: /language`,
      );
    } catch {
      await api.sendMessage(
        chat,
        "Kode tidak dikenal, sudah dipakai, atau sudah kedaluwarsa. Buat kode baru di website (menu Admin → Telegram).\n\nThe code is unknown, already used or expired. Create a new one on the website (Admin → Telegram).",
      );
    }
    return;
  }

  // Registering a group is proven by the owner's identity in the private chat (a Telegram id is the same everywhere).
  if (
    !isPrivate &&
    intent.kind === "command" &&
    (intent.name === "daftargrup" || intent.name === "hapusgrup")
  ) {
    const owner = await store.identify(from.id, from.id, 0);
    if (!owner) return;
    try {
      if (intent.name === "daftargrup") {
        await store.registerChat(
          owner.linkId,
          chat,
          msg.chat.type === "supergroup" ? "supergroup" : "group",
          msg.chat.title ?? "",
        );
        await api.sendMessage(
          chat,
          L(
            owner.lang,
            "✅ Grup ini terdaftar. Hanya kamu yang bisa mencatat dari sini.\nAtur entitasnya: /topik pt atau /topik pribadi (jalankan di topik yang diinginkan). Ringkasan di grup hanya menampilkan entitas yang diatur.",
            "✅ This group is registered. Only you can record from here.\nSet its entity: /topik pt or /topik pribadi (run it in the topic you want). Summaries in the group only show the entity you set.",
          ),
          opts(thread),
        );
      } else {
        await store.unregisterChat(owner.linkId, chat);
        await api.sendMessage(
          chat,
          L(owner.lang, "Grup ini tidak lagi terhubung.", "This group is no longer connected."),
          opts(thread),
        );
      }
    } catch (error) {
      await api.sendMessage(chat, errorLine(error, owner.lang), opts(thread));
    }
    return;
  }

  const who = await store.identify(from.id, chat, thread);
  if (!who) {
    if (isPrivate) {
      await api.sendMessage(
        chat,
        "Bot ini pribadi. Untuk menghubungkan, buka website Hikarich Finance → Admin → Telegram, buat kode, lalu kirim <code>/start KODE</code> di sini.\n\nThis bot is private. To connect, open the Hikarich Finance website → Admin → Telegram, create a code, then send <code>/start CODE</code> here.",
      );
    }
    return;
  }

  const session = await store.getSession(who.linkId, chat, thread);

  if (intent.kind === "command") {
    await handleCommand(intent.name, intent.arg, msg, who, session, deps);
    return;
  }
  if (intent.kind === "help") {
    await api.sendMessage(chat, helpText(who.lang), opts(thread));
    return;
  }
  if (intent.kind === "undo") {
    await startUndo(who, chat, thread, deps);
    return;
  }

  // Typed answers inside the roadmap ("40rb", "kemarin", "transport").
  if (
    session &&
    (session.awaiting !== null || parseAmounts(text).length === 0) &&
    text.length > 0 &&
    !msg.photo
  ) {
    await continueSession(session, text, who, msg, deps);
    return;
  }

  if (intent.kind === "report") {
    await answerReport(who, text, chat, thread, deps);
    return;
  }

  const contexts = await store.context(who.linkId);
  if (contexts.length === 0) {
    await api.sendMessage(
      chat,
      L(
        who.lang,
        "Akunmu belum punya hak mencatat pengeluaran di entitas mana pun.",
        "Your account may not record expenses in any entity yet.",
      ),
      opts(thread),
    );
    return;
  }
  const today = contexts[0]?.today ?? todayInBusinessZone(deps.now());

  let parsed: ParsedExpense | null = null;
  let source: "text" | "photo" = "text";

  if (msg.photo && msg.photo.length > 0) {
    source = "photo";
    parsed = await readPhoto(msg, text, today, deps, who.lang);
    if (!parsed) return;
  } else if (intent.kind === "record") {
    parsed = parseExpenseText(text, today);
  } else if (text.length >= 4 && deps.ai.enabled()) {
    await api.sendChatAction(chat, "typing", thread || null);
    const ai = await deps.ai.readText(text, today);
    if (ai?.kind === "report") {
      await answerReport(who, ai.periodText ?? text, chat, thread, deps);
      return;
    }
    parsed = ai ? aiToParsed(ai, today) : null;
  }

  if (!parsed) {
    await api.sendMessage(
      chat,
      L(
        who.lang,
        "Saya belum menangkap nominalnya. Coba tulis seperti: <i>makan siang 35rb pakai gopay</i>, atau ketik /bantuan.",
        "I did not catch the amount. Try writing like: <i>lunch 35k paid with gopay</i>, or type /help.",
      ),
      opts(thread),
    );
    return;
  }

  if (source === "text" && looksLikeLoanPayment(text)) {
    // An instalment splits principal and interest and lowers the debt, so it is never an ordinary expense. The bot
    // offers the loan flow instead; to record an ordinary cost, write the message again without "cicilan".
    await startLoanPayment(who, chat, thread, deps);
    return;
  }

  const env: Env = { contexts, maxEntry: who.maxEntryAmount };
  const id = deps.newId().replace(/-/g, "");
  const state = startDraft(parsed, env, {
    nonce: id.slice(0, 6),
    key: `tg-${id}`,
    source,
    topicEntityId: who.chatEntityId,
    today,
    photoFileId: msg.photo?.[msg.photo.length - 1]?.file_id ?? null,
    lang: who.lang,
  });
  if (session?.messageId) await api.clearKeyboard(chat, session.messageId);
  await present(state, env, who, chat, thread, deps, "send");
}

async function readPhoto(
  msg: TgMessage,
  caption: string,
  today: string,
  deps: BotDeps,
  lang: Lang,
): Promise<ParsedExpense | null> {
  const { api, ai } = deps;
  const chat = msg.chat.id;
  const thread = msg.message_thread_id ?? 0;
  if (!ai.enabled()) {
    await api.sendMessage(
      chat,
      L(
        lang,
        "Membaca foto struk butuh kunci Gemini yang belum dipasang. Ketik nominalnya saja, mis. <i>makan 35rb</i>.",
        "Reading receipt photos needs a Gemini key that is not set up yet. Just type the amount, e.g. <i>lunch 35k</i>.",
      ),
      opts(thread),
    );
    return null;
  }
  const best = msg.photo?.[msg.photo.length - 1];
  if (!best) return null;
  await api.sendChatAction(chat, "typing", thread || null);
  const file = await api.downloadFile(best.file_id);
  if (!file.ok) {
    await api.sendMessage(
      chat,
      L(
        lang,
        "Fotonya tidak bisa diunduh. Coba kirim ulang, atau ketik nominalnya.",
        "The photo could not be downloaded. Try sending it again, or type the amount.",
      ),
      opts(thread),
    );
    return null;
  }
  const result = await ai.readReceipt(
    { bytes: file.bytes, mime: file.mime },
    caption || undefined,
    today,
  );
  const parsed = result ? aiToParsed(result, today) : null;
  if (!parsed) {
    await api.sendMessage(
      chat,
      L(
        lang,
        "Saya tidak bisa membaca struknya dengan jelas. Coba foto lebih dekat dan terang, atau ketik nominalnya.",
        "I cannot read the receipt clearly. Try a closer, brighter photo, or type the amount.",
      ),
      opts(thread),
    );
    return null;
  }
  // The owner's own words in the caption ("pt", "pribadi") win over what the model guessed.
  const stated = entityWordOf(caption);
  return stated ? { ...parsed, entityWord: stated } : parsed;
}

/** Shows the roadmap (new message or edit) and keeps the draft for the next press. */
async function present(
  state: DraftState,
  env: Env,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
  mode: "send" | "edit",
): Promise<void> {
  const view = render(state, env);
  let next = state;
  if (mode === "edit" && state.messageId) {
    const edited = await deps.api.editMessage(chat, state.messageId, view.text, view.keyboard);
    if (!edited.ok && !/not modified/i.test(edited.error ?? "")) mode = "send";
  } else {
    mode = "send";
  }
  if (mode === "send") {
    const sent = await deps.api.sendMessage(
      chat,
      view.text,
      opts(thread, { keyboard: view.keyboard }),
    );
    next = { ...state, messageId: sent.result?.message_id ?? null };
  }
  await deps.store.putSession(who.linkId, chat, thread, next);
}

async function continueSession(
  session: DraftState,
  text: string,
  who: Identity,
  msg: TgMessage,
  deps: BotDeps,
): Promise<void> {
  const chat = msg.chat.id;
  const thread = msg.message_thread_id ?? 0;
  const contexts = await deps.store.context(who.linkId);
  const env: Env = { contexts, maxEntry: who.maxEntryAmount };
  const result = apply(session, env, { type: "text", text });
  if (result.state === session) {
    await deps.api.sendMessage(
      chat,
      L(
        who.lang,
        "Belum cocok. Pilih dengan tombol di atas, atau ketik lagi dengan lebih jelas. /batal untuk membatalkan.",
        "No match yet. Pick with the buttons above, or type it more clearly. /cancel to cancel.",
      ),
      opts(thread),
    );
    return;
  }
  if (session.messageId) await deps.api.clearKeyboard(chat, session.messageId);
  await present({ ...result.state, messageId: null }, env, who, chat, thread, deps, "send");
}

async function handleCallback(cb: TgCallbackQuery, deps: BotDeps): Promise<void> {
  const { api, store } = deps;
  const message = cb.message;
  if (!message) {
    await api.answerCallback(cb.id);
    return;
  }
  const chat = message.chat.id;
  const thread = message.message_thread_id ?? 0;
  const who = await store.identify(cb.from.id, chat, thread);
  if (!who) {
    await api.answerCallback(cb.id);
    return;
  }
  const data = parseCallbackData(cb.data ?? "");
  if (!data) {
    await api.answerCallback(cb.id);
    return;
  }

  if (data.nonce === "a") {
    await handleAssetCallback(data.action, data.arg, cb, who, chat, message.message_id, deps);
    return;
  }
  if (data.nonce === "l") {
    await handleLoanCallback(data.action, data.arg, cb, who, chat, message.message_id, deps);
    return;
  }
  if (data.nonce === "u") {
    await handleUndoCallback(data.action, data.arg, cb, who, chat, message.message_id, deps);
    return;
  }

  const session = await store.getSession(who.linkId, chat, thread);
  if (!session || session.nonce !== data.nonce) {
    await api.answerCallback(cb.id, L(who.lang, "Tombol ini sudah kedaluwarsa.", "This button has expired."));
    await api.clearKeyboard(chat, message.message_id);
    return;
  }
  const contexts = await store.context(who.linkId);
  const env: Env = { contexts, maxEntry: who.maxEntryAmount };
  const result = apply({ ...session, messageId: message.message_id }, env, {
    type: "callback",
    action: data.action,
    arg: data.arg,
  });

  switch (result.effect.kind) {
    case "stale":
      await api.answerCallback(
        cb.id,
        L(who.lang, "Pilihan itu tidak berlaku lagi.", "That choice no longer applies."),
      );
      return;
    case "cancel":
      await store.clearSession(who.linkId, chat, thread);
      await api.answerCallback(cb.id, L(who.lang, "Dibatalkan", "Cancelled"));
      await api.editMessage(
        chat,
        message.message_id,
        L(who.lang, "❌ Dibatalkan. Tidak ada yang dicatat.", "❌ Cancelled. Nothing was recorded."),
      );
      return;
    case "save":
      await api.answerCallback(cb.id, L(who.lang, "Menyimpan…", "Saving…"));
      await save(result.state, env, who, chat, thread, message.message_id, deps);
      return;
    case "none":
      await api.answerCallback(cb.id);
      await present(result.state, env, who, chat, thread, deps, "edit");
      return;
  }
}

function describeResult(state: DraftState, env: Env, result: RecordResult): string {
  const lang = state.lang;
  const ctx = env.contexts.find((c) => c.entityId === state.entityId);
  const category = (id: string | null) => ctx?.categories.find((c) => c.id === id)?.name ?? "—";
  const lines = state.lines.map(
    (l) =>
      `• ${escapeHtml(l.description)} — ${formatRupiah(l.amount)} → ${escapeHtml(category(l.categoryId))}`,
  );
  const where = ctx ? `${entityIcon(ctx.entityType)} ${entityShort(ctx.entityType, lang)}` : "";
  const account = ctx?.accounts.find((a) => a.id === state.accountId)?.name ?? "";
  const asDraft = L(lang, "Disimpan sebagai draf", "Saved as a draft");
  const head =
    result.status === "confirmed"
      ? `✅ <b>${L(lang, "Tercatat", "Recorded")}</b>${result.number ? ` · ${escapeHtml(result.number)}` : ""}`
      : result.reasonCode === "ABOVE_LIMIT"
        ? `📝 <b>${asDraft}</b> (${L(lang, `melebihi batas bot ${formatRupiah(env.maxEntry)}`, `above the bot's limit of ${formatRupiah(env.maxEntry)}`)})`
        : result.reasonCode === "FORBIDDEN"
          ? `📝 <b>${asDraft}</b> (${L(lang, "akunmu tidak berhak mengonfirmasi", "your account may not confirm")})`
          : `📝 <b>${asDraft}</b> — ${escapeHtml(refusalText(result.reason ?? L(lang, "tidak bisa dikonfirmasi", "could not be confirmed")).slice(0, 200))}`;
  const date = lang === "en" ? formatDateEn(state.date) : formatDateId(state.date);
  const out = [
    head,
    `${where} · ${date} · ${escapeHtml(account)}`,
    `${L(lang, "Penerima", "Payee")}: ${escapeHtml(payeeFor(state) ?? "—")}`,
    ...lines,
    `<b>Total: ${formatRupiah(result.total)}</b>`,
  ];
  if (result.status !== "confirmed")
    out.push(
      "",
      L(
        lang,
        "Konfirmasi atau ubah di website (menu Pembelian → Pengeluaran).",
        "Confirm or change it on the website (Purchases → Expenses).",
      ),
    );
  if (state.lines.some((l) => l.kind === "asset"))
    out.push(
      "",
      result.status === "confirmed"
        ? L(
            lang,
            "🏷️ Ada barang tahan lama: saya tanyakan masa manfaatnya di bawah ini.",
            "🏷️ This includes durable equipment: I ask how long it lasts below.",
          )
        : L(
            lang,
            "🏷️ Ada barang tahan lama: setelah dikonfirmasi di website, daftarkan sebagai aset (menu Aset).",
            "🏷️ This includes durable equipment: once confirmed on the website, register it as an asset (Assets menu).",
          ),
    );
  if (result.status === "confirmed")
    out.push(
      "",
      L(lang, "Salah catat? Ketik <i>batalkan yang tadi</i>.", "Wrong entry? Type <i>undo the last one</i>."),
    );
  return out.join("\n");
}

async function save(
  state: DraftState,
  env: Env,
  who: Identity,
  chat: number,
  thread: number,
  messageId: number,
  deps: BotDeps,
): Promise<void> {
  const payload = toRecordPayload(state);
  if (!payload) {
    await deps.api.editMessage(
      chat,
      messageId,
      L(state.lang, "Data belum lengkap. Ketik pesan barumu untuk mulai lagi.", "The data is incomplete. Type your message again to start over."),
    );
    await deps.store.clearSession(who.linkId, chat, thread);
    return;
  }
  let result: RecordResult;
  try {
    result = await deps.store.recordExpense(who.linkId, payload, true);
  } catch (error) {
    // Keep the draft so the owner can fix the cause (closed period, disabled account) and press Simpan again.
    const view = render(state, env);
    await deps.api.editMessage(
      chat,
      messageId,
      `⚠️ <b>${L(state.lang, "Belum tersimpan", "Not saved")}:</b> ${escapeHtml(errorLine(error, state.lang))}\n\n${view.text}`,
      view.keyboard,
    );
    return;
  }
  await deps.store.clearSession(who.linkId, chat, thread);
  let text = describeResult(state, env, result);
  if (state.photoFileId && state.entityId && result.expenseId) {
    text += `\n\n${await attachPhoto(state, result.expenseId, who, deps)}`;
  }
  const learned = learnEntries(state, env);
  const remembered: string[] = [];
  for (const entry of learned.slice(0, 5)) {
    try {
      await deps.store.learn(who.linkId, entry);
      const ctx = env.contexts.find((c) => c.entityId === entry.entityId);
      const name = ctx?.categories.find((c) => c.id === entry.categoryId)?.name;
      if (name) remembered.push(`“${escapeHtml(entry.keyword)}” → ${escapeHtml(name)}`);
    } catch {
      /* learning is a convenience; never block the receipt */
    }
  }
  if (remembered.length > 0)
    text += L(
      state.lang,
      `\n\n🧠 Saya ingat: ${remembered.join(", ")}. Lain kali otomatis.`,
      `\n\n🧠 I will remember: ${remembered.join(", ")}. Next time it is automatic.`,
    );
  await deps.api.editMessage(chat, messageId, text);
  if (result.status === "confirmed" && state.lines.some((l) => l.kind === "asset")) {
    await offerAssets(result.expenseId, who, chat, thread, deps);
  }
}

/** Attaches the receipt photo to the saved entry. Never fails the save: the entry exists either way. */
async function attachPhoto(
  state: DraftState,
  expenseId: string,
  who: Identity,
  deps: BotDeps,
): Promise<string> {
  const lang = who.lang;
  try {
    const file = await deps.api.downloadFile(state.photoFileId ?? "");
    if (!file.ok)
      return L(
        lang,
        "📎 Foto struk belum terlampir (gagal diunduh). Lampirkan di website bila perlu.",
        "📎 The receipt photo is not attached (download failed). Attach it on the website if needed.",
      );
    const done = await deps.store.attachReceipt(who.linkId, state.entityId ?? "", expenseId, {
      bytes: file.bytes,
      mime: file.mime,
    });
    return done
      ? L(lang, "📎 Foto struk terlampir di catatan.", "📎 The receipt photo is attached to the entry.")
      : L(
          lang,
          "📎 Foto struk belum terlampir (penyimpanan gagal). Lampirkan di website bila perlu.",
          "📎 The receipt photo is not attached (storage failed). Attach it on the website if needed.",
        );
  } catch (error) {
    return L(
      lang,
      `📎 Foto struk belum terlampir: ${escapeHtml(errorLine(error, lang))}`,
      `📎 The receipt photo is not attached: ${escapeHtml(errorLine(error, lang))}`,
    );
  }
}

// ---- undo -----------------------------------------------------------------------------------------------------

async function startUndo(
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
): Promise<void> {
  const [last] = await deps.store.recentEntries(who.linkId, 1);
  if (!last) {
    await deps.api.sendMessage(
      chat,
      L(who.lang, "Belum ada catatan dari bot yang bisa dibatalkan.", "There is no bot entry to undo yet."),
      opts(thread),
    );
    return;
  }
  const lang = who.lang;
  const text = L(
    lang,
    `Batalkan catatan ini?\n\n${describeEntry(last, lang)}\n\n${last.status === "confirmed" ? "Catatan yang sudah dikonfirmasi akan <b>dibalik</b> (jurnal pembalik), bukan dihapus." : "Draf akan dibatalkan."}`,
    `Undo this entry?\n\n${describeEntry(last, lang)}\n\n${last.status === "confirmed" ? "A confirmed entry is <b>reversed</b> (a reversing journal), never deleted." : "The draft will be cancelled."}`,
  );
  await deps.api.sendMessage(chat, text, {
    ...opts(thread),
    keyboard: {
      rows: [
        [
          { text: L(lang, "✅ Ya, batalkan", "✅ Yes, undo"), data: `u|do|${last.expenseId}` },
          { text: L(lang, "Tidak", "No"), data: "u|no|" },
        ],
      ],
    },
  });
}

function describeEntry(e: RecentEntry, lang: Lang): string {
  const status =
    e.status === "confirmed" ? L(lang, "dikonfirmasi", "confirmed") : L(lang, "draf", "draft");
  const date = lang === "en" ? formatDateEn(e.date) : formatDateId(e.date);
  return `${e.number ? `${escapeHtml(e.number)} · ` : ""}${date} · ${escapeHtml(e.payee ?? "—")}\n${escapeHtml(e.lines ?? "")} — <b>${formatRupiah(e.total)}</b> (${status})`;
}

async function handleUndoCallback(
  action: string,
  arg: string,
  cb: TgCallbackQuery,
  who: Identity,
  chat: number,
  messageId: number,
  deps: BotDeps,
): Promise<void> {
  if (action !== "do" || !/^[0-9a-f-]{36}$/.test(arg)) {
    await deps.api.answerCallback(cb.id, L(who.lang, "Tidak jadi.", "Never mind."));
    await deps.api.editMessage(
      chat,
      messageId,
      L(who.lang, "Oke, tidak dibatalkan.", "OK, not undone."),
    );
    return;
  }
  try {
    await deps.store.undoEntry(who.linkId, `undo-${arg}`, arg);
    await deps.api.answerCallback(cb.id, L(who.lang, "Dibatalkan", "Cancelled"));
    await deps.api.editMessage(
      chat,
      messageId,
      L(who.lang, "↩️ Catatan dibatalkan.", "↩️ Entry undone."),
    );
  } catch (error) {
    await deps.api.answerCallback(cb.id, L(who.lang, "Gagal", "Failed"));
    await deps.api.editMessage(
      chat,
      messageId,
      `⚠️ ${L(who.lang, "Tidak bisa dibatalkan", "Could not undo")}: ${escapeHtml(errorLine(error, who.lang))}`,
    );
  }
}

// ---- reports ------------------------------------------------------------------------------------------------------

export async function answerReport(
  who: Identity,
  text: string,
  chat: number,
  thread: number,
  deps: BotDeps,
): Promise<void> {
  const today = todayInBusinessZone(deps.now());
  const lang = who.lang;
  const period = parsePeriod(text, today, lang);
  const lower = text.toLowerCase();
  const wantsPersonal = /\b(?:pribadi|personal)\b/.test(lower);
  const wantsCompany = /\b(?:pt|usaha|perusahaan|bisnis|company|business)\b/.test(lower);
  const inGroup = chat < 0;

  let targets = who.memberships.filter((m) => m.canView);
  if (inGroup) {
    targets = targets.filter((m) => m.entityId === who.chatEntityId);
    if (targets.length === 0) {
      await deps.api.sendMessage(
        chat,
        L(
          lang,
          "Di grup, ringkasan hanya untuk entitas yang diatur. Jalankan /topik pt atau /topik pribadi dulu.",
          "In a group, summaries only cover the entity you set. Run /topik pt or /topik pribadi first.",
        ),
        opts(thread),
      );
      return;
    }
  } else if (wantsPersonal !== wantsCompany) {
    targets = targets.filter((m) =>
      wantsPersonal ? m.entityType === "personal" : m.entityType !== "personal",
    );
  }
  if (targets.length === 0) {
    await deps.api.sendMessage(
      chat,
      L(lang, "Akunmu belum punya hak melihat pengeluaran.", "Your account may not view expenses yet."),
      opts(thread),
    );
    return;
  }

  const parts: string[] = [];
  try {
    for (const target of targets) {
      const current = await deps.store.summary(who.linkId, target.entityId, period.from, period.to);
      const previous = await deps.store.summary(
        who.linkId,
        target.entityId,
        period.prevFrom,
        period.prevTo,
      );
      parts.push(formatSummary("ask", period, current, previous.total, lang));
    }
  } catch (error) {
    await deps.api.sendMessage(chat, `⚠️ ${escapeHtml(errorLine(error, lang))}`, opts(thread));
    return;
  }
  for (const message of joinSummaries(parts))
    await deps.api.sendMessage(chat, message, opts(thread));
}

// ---- commands -----------------------------------------------------------------------------------------------------

async function handleCommand(
  name: string,
  arg: string,
  msg: TgMessage,
  who: Identity,
  session: DraftState | null,
  deps: BotDeps,
): Promise<void> {
  const chat = msg.chat.id;
  const thread = msg.message_thread_id ?? 0;
  const { api, store } = deps;

  if (name in COMMAND_PERIODS) {
    await answerReport(who, `${COMMAND_PERIODS[name]} ${arg}`, chat, thread, deps);
    return;
  }
  switch (name) {
    case "bahasa":
    case "language":
    case "lang": {
      const asked = arg.trim().toLowerCase();
      const next: Lang | null = /^(en|english|inggris)$/.test(asked)
        ? "en"
        : /^(id|indonesia|indonesian)$/.test(asked)
          ? "id"
          : null;
      if (!next) {
        await api.sendMessage(
          chat,
          `🌐 ${L(who.lang, "Bahasa sekarang: Indonesia. Ketik <code>/bahasa en</code> untuk English.", "Current language: English. Type <code>/language id</code> for Indonesian.")}`,
          opts(thread),
        );
        return;
      }
      try {
        await store.setLanguage(who.linkId, next);
        await api.sendMessage(
          chat,
          next === "en"
            ? "✅ Language set to English. Reports and messages will now be in English."
            : "✅ Bahasa diatur ke Indonesia. Pesan dan laporan sekarang berbahasa Indonesia.",
          opts(thread),
        );
      } catch (error) {
        await api.sendMessage(chat, errorLine(error, who.lang), opts(thread));
      }
      return;
    }
    case "start":
    case "bantuan":
    case "help":
    case "menu":
      await api.sendMessage(chat, helpText(who.lang), opts(thread));
      return;
    case "ringkasan":
    case "laporan":
    case "rekap":
      await answerReport(who, arg || "bulan ini", chat, thread, deps);
      return;
    case "summary":
    case "report":
      await answerReport(who, arg || "this month", chat, thread, deps);
      return;
    case "batal":
    case "cancel":
      if (session) {
        await store.clearSession(who.linkId, chat, thread);
        if (session.messageId) await api.clearKeyboard(chat, session.messageId);
        await api.sendMessage(
          chat,
          L(who.lang, "❌ Dibatalkan. Tidak ada yang dicatat.", "❌ Cancelled. Nothing was recorded."),
          opts(thread),
        );
      } else {
        await api.sendMessage(
          chat,
          L(who.lang, "Tidak ada yang sedang dicatat.", "Nothing is being recorded."),
          opts(thread),
        );
      }
      return;
    case "cicilan":
    case "pinjaman":
    case "loan":
    case "loans":
      await startLoanPayment(who, chat, thread, deps);
      return;
    case "batalkan":
    case "undo":
      await startUndo(who, chat, thread, deps);
      return;
    case "terakhir":
    case "last": {
      const entries = await store.recentEntries(who.linkId, 5);
      await api.sendMessage(
        chat,
        entries.length === 0
          ? L(who.lang, "Belum ada catatan dari bot.", "No entries from the bot yet.")
          : `<b>${L(who.lang, "Catatan terakhir dari bot", "Latest entries from the bot")}</b>\n\n${entries.map((e) => describeEntry(e, who.lang)).join("\n\n")}`,
        opts(thread),
      );
      return;
    }
    case "tips":
      await api.sendMessage(chat, await tips(who, deps), opts(thread));
      return;
    case "settings":
    case "pengaturan": {
      const lang = who.lang;
      const on = (v: boolean) => (v ? L(lang, "aktif", "on") : L(lang, "mati", "off"));
      await api.sendMessage(
        chat,
        [
          `<b>${L(lang, "Pengaturan bot", "Bot settings")}</b>`,
          `${L(lang, "Laporan harian 21.00", "Daily report 21:00")}: ${on(who.reportDaily)}`,
          `${L(lang, "Laporan mingguan (Senin 08.00)", "Weekly report (Monday 08:00)")}: ${on(who.reportWeekly)}`,
          `${L(lang, "Laporan bulanan (tanggal 1, 08.00)", "Monthly report (the 1st, 08:00)")}: ${on(who.reportMonthly)}`,
          `${L(lang, "Batas per catatan", "Limit per entry")}: ${formatRupiah(who.maxEntryAmount)} ${L(lang, "(di atas itu jadi draf)", "(above it, a draft)")}`,
          `${L(lang, "Bahasa", "Language")}: ${lang === "en" ? "English" : "Indonesia"} (/language)`,
          "",
          `${L(lang, "Ubah di website", "Change on the website")}: ${escapeHtml(deps.appUrl)}/admin/telegram`,
        ].join("\n"),
        opts(thread),
      );
      return;
    }
    case "topik": {
      if (chat >= 0) {
        await api.sendMessage(
          chat,
          L(
            who.lang,
            "Perintah ini dipakai di grup yang sudah didaftarkan (/daftargrup).",
            "This command is used in a registered group (/daftargrup).",
          ),
          opts(thread),
        );
        return;
      }
      const word = arg.toLowerCase();
      const wantPersonal = /pribadi|personal/.test(word);
      const wantCompany = /\b(pt|usaha|perusahaan|company|business)\b/.test(word);
      const found = who.memberships.find(
        (m) =>
          m.canCreate &&
          (wantPersonal
            ? m.entityType === "personal"
            : wantCompany
              ? m.entityType !== "personal"
              : false),
      );
      if (!found) {
        await api.sendMessage(
          chat,
          L(
            who.lang,
            "Tulis <code>/topik pt</code> atau <code>/topik pribadi</code>.",
            "Write <code>/topik pt</code> or <code>/topik pribadi</code>.",
          ),
          opts(thread),
        );
        return;
      }
      try {
        await store.setTopicEntity(who.linkId, chat, thread, found.entityId);
        await api.sendMessage(
          chat,
          L(
            who.lang,
            `✅ ${thread ? "Topik" : "Grup"} ini dicatat ke ${entityIcon(found.entityType)} <b>${escapeHtml(entityShort(found.entityType, who.lang))}</b>.`,
            `✅ This ${thread ? "topic" : "group"} now records to ${entityIcon(found.entityType)} <b>${escapeHtml(entityShort(found.entityType, who.lang))}</b>.`,
          ),
          opts(thread),
        );
      } catch (error) {
        await api.sendMessage(chat, errorLine(error, who.lang), opts(thread));
      }
      return;
    }
    default:
      await api.sendMessage(
        chat,
        L(who.lang, "Perintah itu belum saya kenal. Ketik /bantuan.", "I do not know that command. Type /help."),
        opts(thread),
      );
  }
}

async function tips(who: Identity, deps: BotDeps): Promise<string> {
  const lang = who.lang;
  const today = todayInBusinessZone(deps.now());
  const from = `${today.slice(0, 7)}-01`;
  const out: string[] = [`💡 <b>${L(lang, "Tips supaya lebih mudah", "Tips to make it easier")}</b>`];
  let drafts = 0;
  let assets = 0;
  for (const m of who.memberships.filter((x) => x.canView)) {
    try {
      const s = await deps.store.summary(who.linkId, m.entityId, from, today);
      drafts += s.drafts;
      assets += s.assetsToRegister;
    } catch {
      /* a tip must never fail the command */
    }
  }
  if (drafts > 0)
    out.push(
      L(
        lang,
        `• Ada <b>${drafts} draf</b> bulan ini yang belum dikonfirmasi. Konfirmasi di website supaya masuk laporan.`,
        `• There are <b>${drafts} draft(s)</b> this month not confirmed yet. Confirm them on the website so they reach the reports.`,
      ),
    );
  if (assets > 0)
    out.push(
      L(
        lang,
        `• Ada <b>${assets} pembelian</b> yang menunggu didaftarkan sebagai aset tetap (menu Aset).`,
        `• <b>${assets} purchase(s)</b> are waiting to be registered as fixed assets (Assets menu).`,
      ),
    );
  out.push(
    ...(lang === "en"
      ? [
          "• Say how you paid (<i>with gopay</i>, <i>cash</i>) so the account step is skipped automatically.",
          "• Say <i>PT</i> or <i>personal</i> in the message so I do not have to ask for the entity.",
          "• I remember the category you pick: shopping at the same place next time is automatic.",
          "• Send the receipt photo right after paying; it is faster than typing.",
          "• Several items in one message are fine: <i>coffee 25k and bread 15k</i>.",
          "• Large expenses (above the limit) become drafts; set the limit on the website.",
        ]
      : [
          "• Sebut cara bayarnya (<i>pakai gopay</i>, <i>tunai</i>) supaya langkah rekening terlewati otomatis.",
          "• Sebut <i>PT</i> atau <i>pribadi</i> di pesan supaya saya tidak perlu bertanya entitasnya.",
          "• Kategori yang kamu pilih saya ingat: belanja di tempat yang sama berikutnya otomatis.",
          "• Kirim foto struk langsung setelah bayar; lebih cepat daripada mengetik.",
          "• Banyak barang dalam satu pesan boleh: <i>kopi 25rb dan roti 15rb</i>.",
          "• Pengeluaran besar (di atas batas) jadi draf; atur batasnya di website.",
        ]),
  );
  return out.join("\n");
}
