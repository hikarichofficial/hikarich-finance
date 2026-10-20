import { aiToParsed, type AiExtraction } from "@/domain/telegram/ai";
import { formatDateId } from "@/domain/telegram/dates";
import {
  classifyIntent,
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
import { refusalText, StoreError } from "./errors";
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

const HELP = [
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
  "<b>Tanya ringkasan</b>: <i>pengeluaran hari ini</i>, <i>rekap minggu lalu</i>, <i>bulan ini berapa?</i>",
  "",
  "<b>Perintah</b>: /hariini /mingguini /bulanini /bulanlalu /terakhir /batalkan /batal /tips /pengaturan",
  "Laporan otomatis (harian, mingguan, bulanan) dan batas nominal diatur di website.",
].join("\n");

const COMMAND_PERIODS: Readonly<Record<string, string>> = {
  hariini: "hari ini",
  kemarin: "kemarin",
  mingguini: "minggu ini",
  minggulalu: "minggu lalu",
  bulanini: "bulan ini",
  bulanlalu: "bulan lalu",
};

function opts(thread: number, extra: Partial<SendOptions> = {}): SendOptions {
  return { ...(thread ? { threadId: thread } : {}), ...extra };
}

function errorLine(error: unknown): string {
  if (error instanceof StoreError) {
    if (error.code === "FORBIDDEN") return "Akunmu tidak punya hak untuk itu.";
    return refusalText(error.message).slice(0, 200) || "Terjadi kesalahan.";
  }
  return "Terjadi kesalahan di server. Coba lagi sebentar lagi.";
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
        "⚠️ Maaf, ada gangguan saat memproses pesan ini. Coba kirim lagi.",
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
        `✅ Terhubung sebagai <b>${escapeHtml(paired.displayName)}</b>.\n\n${HELP}`,
      );
    } catch {
      await api.sendMessage(
        chat,
        "Kode tidak dikenal, sudah dipakai, atau sudah kedaluwarsa. Buat kode baru di website (menu Admin → Telegram).",
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
          "✅ Grup ini terdaftar. Hanya kamu yang bisa mencatat dari sini.\nAtur entitasnya: /topik pt atau /topik pribadi (jalankan di topik yang diinginkan). Ringkasan di grup hanya menampilkan entitas yang diatur.",
          opts(thread),
        );
      } else {
        await store.unregisterChat(owner.linkId, chat);
        await api.sendMessage(chat, "Grup ini tidak lagi terhubung.", opts(thread));
      }
    } catch (error) {
      await api.sendMessage(chat, errorLine(error), opts(thread));
    }
    return;
  }

  const who = await store.identify(from.id, chat, thread);
  if (!who) {
    if (isPrivate) {
      await api.sendMessage(
        chat,
        "Bot ini pribadi. Untuk menghubungkan, buka website Hikarich Finance → Admin → Telegram, buat kode, lalu kirim <code>/start KODE</code> di sini.",
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
    await api.sendMessage(chat, HELP, opts(thread));
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
      "Akunmu belum punya hak mencatat pengeluaran di entitas mana pun.",
      opts(thread),
    );
    return;
  }
  const today = contexts[0]?.today ?? todayInBusinessZone(deps.now());

  let parsed: ParsedExpense | null = null;
  let source: "text" | "photo" = "text";

  if (msg.photo && msg.photo.length > 0) {
    source = "photo";
    parsed = await readPhoto(msg, text, today, deps);
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
      "Saya belum menangkap nominalnya. Coba tulis seperti: <i>makan siang 35rb pakai gopay</i>, atau ketik /bantuan.",
      opts(thread),
    );
    return;
  }

  if (source === "text" && looksLikeLoanPayment(text)) {
    await api.sendMessage(
      chat,
      "Ini terlihat seperti <b>cicilan atau pelunasan pinjaman</b>. Cicilan memecah pokok dan bunga serta mengurangi utang, jadi catat pembayarannya di website, di menu Pinjaman. Saya tidak mencatatnya sebagai pengeluaran biasa supaya pembukuan tidak salah. Kalau sebenarnya ini biaya biasa, tulis ulang tanpa kata cicilan/angsuran.",
      opts(thread),
    );
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
  });
  if (session?.messageId) await api.clearKeyboard(chat, session.messageId);
  await present(state, env, who, chat, thread, deps, "send");
}

async function readPhoto(
  msg: TgMessage,
  caption: string,
  today: string,
  deps: BotDeps,
): Promise<ParsedExpense | null> {
  const { api, ai } = deps;
  const chat = msg.chat.id;
  const thread = msg.message_thread_id ?? 0;
  if (!ai.enabled()) {
    await api.sendMessage(
      chat,
      "Membaca foto struk butuh kunci Gemini yang belum dipasang. Ketik nominalnya saja, mis. <i>makan 35rb</i>.",
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
      "Fotonya tidak bisa diunduh. Coba kirim ulang, atau ketik nominalnya.",
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
      "Saya tidak bisa membaca struknya dengan jelas. Coba foto lebih dekat dan terang, atau ketik nominalnya.",
      opts(thread),
    );
    return null;
  }
  return parsed;
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
      "Belum cocok. Pilih dengan tombol di atas, atau ketik lagi dengan lebih jelas. /batal untuk membatalkan.",
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

  if (data.nonce === "u") {
    await handleUndoCallback(data.action, data.arg, cb, who, chat, message.message_id, deps);
    return;
  }

  const session = await store.getSession(who.linkId, chat, thread);
  if (!session || session.nonce !== data.nonce) {
    await api.answerCallback(cb.id, "Tombol ini sudah kedaluwarsa.");
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
      await api.answerCallback(cb.id, "Pilihan itu tidak berlaku lagi.");
      return;
    case "cancel":
      await store.clearSession(who.linkId, chat, thread);
      await api.answerCallback(cb.id, "Dibatalkan");
      await api.editMessage(chat, message.message_id, "❌ Dibatalkan. Tidak ada yang dicatat.");
      return;
    case "save":
      await api.answerCallback(cb.id, "Menyimpan…");
      await save(result.state, env, who, chat, thread, message.message_id, deps);
      return;
    case "none":
      await api.answerCallback(cb.id);
      await present(result.state, env, who, chat, thread, deps, "edit");
      return;
  }
}

function describeResult(state: DraftState, env: Env, result: RecordResult): string {
  const ctx = env.contexts.find((c) => c.entityId === state.entityId);
  const category = (id: string | null) => ctx?.categories.find((c) => c.id === id)?.name ?? "—";
  const lines = state.lines.map(
    (l) =>
      `• ${escapeHtml(l.description)} — ${formatRupiah(l.amount)} → ${escapeHtml(category(l.categoryId))}`,
  );
  const where = ctx ? `${entityIcon(ctx.entityType)} ${entityShort(ctx.entityType)}` : "";
  const account = ctx?.accounts.find((a) => a.id === state.accountId)?.name ?? "";
  const head =
    result.status === "confirmed"
      ? `✅ <b>Tercatat</b>${result.number ? ` · ${escapeHtml(result.number)}` : ""}`
      : result.reasonCode === "ABOVE_LIMIT"
        ? `📝 <b>Disimpan sebagai draf</b> (melebihi batas bot ${formatRupiah(env.maxEntry)})`
        : result.reasonCode === "FORBIDDEN"
          ? "📝 <b>Disimpan sebagai draf</b> (akunmu tidak berhak mengonfirmasi)"
          : `📝 <b>Disimpan sebagai draf</b> — ${escapeHtml(refusalText(result.reason ?? "tidak bisa dikonfirmasi").slice(0, 200))}`;
  const out = [
    head,
    `${where} · ${formatDateId(state.date)} · ${escapeHtml(account)}`,
    `Penerima: ${escapeHtml(payeeFor(state) ?? "—")}`,
    ...lines,
    `<b>Total: ${formatRupiah(result.total)}</b>`,
  ];
  if (result.status !== "confirmed")
    out.push("", "Konfirmasi atau ubah di website (menu Pembelian → Pengeluaran).");
  if (state.lines.some((l) => l.kind === "asset"))
    out.push(
      "",
      "🏷️ Ada barang tahan lama: daftarkan sebagai aset tetap di website (menu Aset) supaya disusutkan.",
    );
  if (result.status === "confirmed") out.push("", "Salah catat? Ketik <i>batalkan yang tadi</i>.");
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
      "Data belum lengkap. Ketik pesan barumu untuk mulai lagi.",
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
      `⚠️ <b>Belum tersimpan:</b> ${escapeHtml(errorLine(error))}\n\n${view.text}`,
      view.keyboard,
    );
    return;
  }
  await deps.store.clearSession(who.linkId, chat, thread);
  let text = describeResult(state, env, result);
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
    text += `\n\n🧠 Saya ingat: ${remembered.join(", ")}. Lain kali otomatis.`;
  await deps.api.editMessage(chat, messageId, text);
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
      "Belum ada catatan dari bot yang bisa dibatalkan.",
      opts(thread),
    );
    return;
  }
  const text = `Batalkan catatan ini?\n\n${describeEntry(last)}\n\n${last.status === "confirmed" ? "Catatan yang sudah dikonfirmasi akan <b>dibalik</b> (jurnal pembalik), bukan dihapus." : "Draf akan dibatalkan."}`;
  await deps.api.sendMessage(chat, text, {
    ...opts(thread),
    keyboard: {
      rows: [
        [
          { text: "✅ Ya, batalkan", data: `u|do|${last.expenseId}` },
          { text: "Tidak", data: "u|no|" },
        ],
      ],
    },
  });
}

function describeEntry(e: RecentEntry): string {
  const status = e.status === "confirmed" ? "dikonfirmasi" : "draf";
  return `${e.number ? `${escapeHtml(e.number)} · ` : ""}${formatDateId(e.date)} · ${escapeHtml(e.payee ?? "—")}\n${escapeHtml(e.lines ?? "")} — <b>${formatRupiah(e.total)}</b> (${status})`;
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
    await deps.api.answerCallback(cb.id, "Tidak jadi.");
    await deps.api.editMessage(chat, messageId, "Oke, tidak dibatalkan.");
    return;
  }
  try {
    await deps.store.undoEntry(who.linkId, `undo-${arg}`, arg);
    await deps.api.answerCallback(cb.id, "Dibatalkan");
    await deps.api.editMessage(chat, messageId, "↩️ Catatan dibatalkan.");
  } catch (error) {
    await deps.api.answerCallback(cb.id, "Gagal");
    await deps.api.editMessage(
      chat,
      messageId,
      `⚠️ Tidak bisa dibatalkan: ${escapeHtml(errorLine(error))}`,
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
  const period = parsePeriod(text, today);
  const lower = text.toLowerCase();
  const wantsPersonal = /\bpribadi\b/.test(lower);
  const wantsCompany = /\b(?:pt|usaha|perusahaan|bisnis)\b/.test(lower);
  const inGroup = chat < 0;

  let targets = who.memberships.filter((m) => m.canView);
  if (inGroup) {
    targets = targets.filter((m) => m.entityId === who.chatEntityId);
    if (targets.length === 0) {
      await deps.api.sendMessage(
        chat,
        "Di grup, ringkasan hanya untuk entitas yang diatur. Jalankan /topik pt atau /topik pribadi dulu.",
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
    await deps.api.sendMessage(chat, "Akunmu belum punya hak melihat pengeluaran.", opts(thread));
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
      parts.push(formatSummary("ask", period, current, previous.total));
    }
  } catch (error) {
    await deps.api.sendMessage(chat, `⚠️ ${escapeHtml(errorLine(error))}`, opts(thread));
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
    case "start":
    case "bantuan":
    case "help":
    case "menu":
      await api.sendMessage(chat, HELP, opts(thread));
      return;
    case "ringkasan":
    case "laporan":
    case "rekap":
      await answerReport(who, arg || "bulan ini", chat, thread, deps);
      return;
    case "batal":
      if (session) {
        await store.clearSession(who.linkId, chat, thread);
        if (session.messageId) await api.clearKeyboard(chat, session.messageId);
        await api.sendMessage(chat, "❌ Dibatalkan. Tidak ada yang dicatat.", opts(thread));
      } else {
        await api.sendMessage(chat, "Tidak ada yang sedang dicatat.", opts(thread));
      }
      return;
    case "batalkan":
    case "undo":
      await startUndo(who, chat, thread, deps);
      return;
    case "terakhir": {
      const entries = await store.recentEntries(who.linkId, 5);
      await api.sendMessage(
        chat,
        entries.length === 0
          ? "Belum ada catatan dari bot."
          : `<b>Catatan terakhir dari bot</b>\n\n${entries.map(describeEntry).join("\n\n")}`,
        opts(thread),
      );
      return;
    }
    case "tips":
      await api.sendMessage(chat, await tips(who, deps), opts(thread));
      return;
    case "pengaturan": {
      const on = (v: boolean) => (v ? "aktif" : "mati");
      await api.sendMessage(
        chat,
        [
          "<b>Pengaturan bot</b>",
          `Laporan harian 21.00: ${on(who.reportDaily)}`,
          `Laporan mingguan (Senin 08.00): ${on(who.reportWeekly)}`,
          `Laporan bulanan (tanggal 1, 08.00): ${on(who.reportMonthly)}`,
          `Batas per catatan: ${formatRupiah(who.maxEntryAmount)} (di atas itu jadi draf)`,
          "",
          `Ubah di website: ${escapeHtml(deps.appUrl)}/admin/telegram`,
        ].join("\n"),
        opts(thread),
      );
      return;
    }
    case "topik": {
      if (chat >= 0) {
        await api.sendMessage(
          chat,
          "Perintah ini dipakai di grup yang sudah didaftarkan (/daftargrup).",
          opts(thread),
        );
        return;
      }
      const word = arg.toLowerCase();
      const wantPersonal = /pribadi/.test(word);
      const wantCompany = /\b(pt|usaha|perusahaan)\b/.test(word);
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
          "Tulis <code>/topik pt</code> atau <code>/topik pribadi</code>.",
          opts(thread),
        );
        return;
      }
      try {
        await store.setTopicEntity(who.linkId, chat, thread, found.entityId);
        await api.sendMessage(
          chat,
          `✅ ${thread ? "Topik" : "Grup"} ini dicatat ke ${entityIcon(found.entityType)} <b>${escapeHtml(entityShort(found.entityType))}</b>.`,
          opts(thread),
        );
      } catch (error) {
        await api.sendMessage(chat, errorLine(error), opts(thread));
      }
      return;
    }
    default:
      await api.sendMessage(chat, "Perintah itu belum saya kenal. Ketik /bantuan.", opts(thread));
  }
}

async function tips(who: Identity, deps: BotDeps): Promise<string> {
  const today = todayInBusinessZone(deps.now());
  const from = `${today.slice(0, 7)}-01`;
  const out: string[] = ["💡 <b>Tips supaya lebih mudah</b>"];
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
      `• Ada <b>${drafts} draf</b> bulan ini yang belum dikonfirmasi. Konfirmasi di website supaya masuk laporan.`,
    );
  if (assets > 0)
    out.push(
      `• Ada <b>${assets} pembelian</b> yang menunggu didaftarkan sebagai aset tetap (menu Aset).`,
    );
  out.push(
    "• Sebut cara bayarnya (<i>pakai gopay</i>, <i>tunai</i>) supaya langkah rekening terlewati otomatis.",
    "• Sebut <i>PT</i> atau <i>pribadi</i> di pesan supaya saya tidak perlu bertanya entitasnya.",
    "• Kategori yang kamu pilih saya ingat: belanja di tempat yang sama berikutnya otomatis.",
    "• Kirim foto struk langsung setelah bayar; lebih cepat daripada mengetik.",
    "• Banyak barang dalam satu pesan boleh: <i>kopi 25rb dan roti 15rb</i>.",
    "• Pengeluaran besar (di atas batas) jadi draf; atur batasnya di website.",
  );
  return out.join("\n");
}
