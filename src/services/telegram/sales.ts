import { randomInt } from "node:crypto";
import { formatDateId } from "@/domain/telegram/dates";
import { formatDateEn, L, type Lang } from "@/domain/telegram/i18n";
import { entityWordOf, matchAccount } from "@/domain/telegram/message";
import { escapeHtml } from "@/domain/telegram/report";
import { formatRupiah, parseAmounts } from "@/domain/telegram/rupiah";
import {
  beginVerification,
  invoiceLink,
  newOp,
  parseOpArg,
  parseSalesIntent,
  readChoice,
  readDupAnswer,
  receiptLink,
  renderOp,
  settlementLabel,
  totalOf,
  type EntityChoice,
  type InvoiceRef,
  type SalesIntent,
  type SalesOp,
} from "@/domain/telegram/sales";
import { answer, saysNo, type VerifyInput } from "@/domain/telegram/verify";
import { todayInBusinessZone } from "@/lib/time";
import type { TgCallbackQuery } from "./api";
import type { BotDeps } from "./bot";
import { errorLine } from "./errors";
import type { FoundInvoice, Identity } from "./store";

/**
 * Sales through the bot (decision 425). The owner says what to do in a sentence; the bot asks what is missing, asks
 * about a customer that may already exist, shows a summary, and runs the layered verification (domain/telegram/verify)
 * before it calls the website's own commands through the `telegram_sales_*` functions. It records nothing until the last
 * verification step is answered. Every answer can be a button or typed text.
 */

type Step = { op: SalesOp } | { refuse: string };

function threadOpts(thread: number) {
  return thread ? { threadId: thread } : {};
}

function dateOf(lang: Lang, iso: string): string {
  return lang === "en" ? formatDateEn(iso) : formatDateId(iso);
}

function entityChoices(who: Identity): EntityChoice[] {
  return who.memberships.map((m) => ({ id: m.entityId, name: m.entityName, type: m.entityType }));
}

function setEntity(op: SalesOp, id: string): SalesOp {
  const entity = op.entities.find((e) => e.id === id);
  return entity ? { ...op, entityId: entity.id, entityName: entity.name } : op;
}

function refusalOf(lang: Lang, id: string, en: string): Step {
  return { refuse: L(lang, id, en) };
}

// ---- starting ---------------------------------------------------------------------------------------------------

/** Reads a sales sentence and starts the conversation. Returns false when the text is not a sales sentence. */
export async function startSales(
  text: string,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
): Promise<boolean> {
  const intent = parseSalesIntent(text);
  if (!intent) return false;
  if (intent.kind === "status") {
    await showInvoice(intent.number, who, chat, thread, deps);
    return true;
  }
  const id = deps.newId().replace(/-/g, "");
  let op = newOp({
    kind: intent.kind,
    nonce: id.slice(0, 6),
    key: `tg-${id}`,
    lang: who.lang,
    today: todayInBusinessZone(deps.now()),
    entities: entityChoices(who),
  });
  op = fillFromIntent(op, intent, who);
  if (intent.kind === "payment") {
    await startPayment(op, intent, who, chat, thread, deps);
    return true;
  }
  await proceed(op, who, chat, thread, deps, "send");
  return true;
}

function fillFromIntent(op: SalesOp, intent: SalesIntent, who: Identity): SalesOp {
  let next = op;
  if (intent.kind === "invoice") {
    next = {
      ...next,
      customerName: intent.customer,
      amount: intent.amount ?? 0,
      description: intent.description,
      dueDays: intent.dueDays,
    };
  } else if (intent.kind === "customer") {
    next = { ...next, customerName: intent.name, email: intent.email, phone: intent.phone };
  }
  if (intent.kind === "status") return next;
  const topic = who.chatEntityId ? next.entities.find((e) => e.id === who.chatEntityId) : undefined;
  if (topic) return setEntity(next, topic.id);
  const word = intent.entityWord;
  const byWord = word
    ? next.entities.filter((e) => (word === "personal") === (e.type === "personal"))
    : [];
  if (byWord.length === 1 && byWord[0]) return setEntity(next, byWord[0].id);
  if (next.entities.length === 1 && next.entities[0]) return setEntity(next, next.entities[0].id);
  return next;
}

async function startPayment(
  op: SalesOp,
  intent: Extract<SalesIntent, { kind: "payment" }>,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
): Promise<void> {
  let found: FoundInvoice[];
  try {
    found = await deps.store.salesFindInvoice(who.linkId, intent.number);
  } catch (error) {
    await deps.api.sendMessage(chat, `⚠️ ${errorLine(error, who.lang)}`, threadOpts(thread));
    return;
  }
  const word = intent.entityWord;
  const narrowed =
    word && found.length > 1
      ? found.filter((f) => (word === "personal") === (f.entityType === "personal"))
      : found;
  const pool = narrowed.length > 0 ? narrowed : found;
  if (pool.length === 0) {
    await deps.api.sendMessage(
      chat,
      L(
        who.lang,
        `Invoice <b>${escapeHtml(intent.number)}</b> tidak ditemukan, atau akunmu tidak boleh melihatnya.`,
        `Invoice <b>${escapeHtml(intent.number)}</b> was not found, or your account may not see it.`,
      ),
      threadOpts(thread),
    );
    return;
  }
  const refs = pool.map(refOf);
  const base = {
    ...op,
    amount: intent.amount ?? 0,
    accountWords: intent.accountWords,
    choices: refs,
  };
  if (pool.length > 1) {
    await proceed({ ...base, phase: "invoice" }, who, chat, thread, deps, "send");
    return;
  }
  const only = refs[0] as InvoiceRef;
  await proceed(
    {
      ...base,
      invoice: only,
      entityId: only.entityId,
      entityName: only.entityName,
      customerName: only.customerName,
    },
    who,
    chat,
    thread,
    deps,
    "send",
  );
}

function refOf(f: FoundInvoice): InvoiceRef {
  return {
    invoiceId: f.invoiceId,
    entityId: f.entityId,
    entityName: f.entityName,
    number: f.number,
    customerName: f.customer,
    currency: f.currency,
    total: f.total,
    outstanding: f.outstanding,
    status: f.status,
    canRecordPayment: f.canRecordPayment,
  };
}

// ---- moving the conversation forward ----------------------------------------------------------------------------

async function advance(op: SalesOp, who: Identity, deps: BotDeps): Promise<Step> {
  const lang = op.lang;
  if (op.kind === "payment") return advancePayment(op, who, deps);
  if (!op.entityId) return { op: { ...op, phase: "entity" } };

  if (op.kind === "invoice") {
    if (op.amount <= 0) return { op: { ...op, phase: "amount" } };
    if (op.amount > 100_000_000_000)
      return refusalOf(
        lang,
        "Nominal terlalu besar untuk dicatat lewat bot.",
        "That amount is too large for the bot.",
      );
    if (!op.description) return { op: { ...op, phase: "describe" } };
  }

  let next = op;
  if (!next.looked) {
    if (!next.customerId && !next.allowSimilar) {
      const found = await deps.store.salesCustomers(who.linkId, op.entityId, op.customerName);
      if (found.length > 0)
        return {
          op: {
            ...next,
            phase: "dup",
            candidates: found.map((c) => ({
              id: c.id,
              name: c.name,
              email: c.email,
              severity: c.severity,
            })),
          },
        };
    }
    next = { ...next, looked: true };
  }

  if (next.kind === "invoice" && !next.channelAsked) {
    const ctx = await deps.store.salesContext(who.linkId, op.entityId);
    if (ctx.currency !== "IDR")
      return refusalOf(
        lang,
        "Entitas ini memakai mata uang selain rupiah. Terbitkan invoicenya di website.",
        "This entity uses a currency other than rupiah. Issue the invoice on the website.",
      );
    next = {
      ...next,
      today: ctx.today,
      accounts: ctx.accounts.map((a) => ({ id: a.id, name: a.name })),
    };
    if (ctx.channels.length > 0)
      return {
        op: {
          ...next,
          phase: "channel",
          channels: ctx.channels.map((c) => ({
            id: c.id,
            name: c.hasUrl ? `🔗 ${c.name}` : c.name,
            accountId: c.accountId,
          })),
        },
      };
    next = { ...next, channelAsked: true };
  }
  return { op: beginVerification(next) };
}

async function advancePayment(op: SalesOp, who: Identity, deps: BotDeps): Promise<Step> {
  const lang = op.lang;
  const inv = op.invoice;
  if (!inv) return { op: { ...op, phase: "invoice" } };
  if (!inv.canRecordPayment)
    return refusalOf(
      lang,
      "Akunmu tidak boleh mencatat pembayaran di entitas ini.",
      "Your account may not record payments in this entity.",
    );
  if (inv.status !== "issued")
    return refusalOf(
      lang,
      `Invoice ${inv.number} berstatus <b>${escapeHtml(inv.status)}</b>, jadi tidak bisa menerima pembayaran.`,
      `Invoice ${inv.number} is <b>${escapeHtml(inv.status)}</b>, so it cannot receive a payment.`,
    );
  if (inv.outstanding <= 0)
    return refusalOf(
      lang,
      `Invoice ${inv.number} sudah lunas.`,
      `Invoice ${inv.number} is already paid in full.`,
    );
  if (inv.currency !== "IDR")
    return refusalOf(
      lang,
      "Invoice berbeda mata uang dengan rupiah. Catat pembayarannya di website.",
      "That invoice is not in rupiah. Record the payment on the website.",
    );
  const amount = op.amount > 0 ? op.amount : inv.outstanding;
  if (amount > inv.outstanding)
    return refusalOf(
      lang,
      `Nominal ${formatRupiah(amount)} melebihi sisa tagihan ${formatRupiah(inv.outstanding)}.`,
      `${formatRupiah(amount)} is more than what is outstanding (${formatRupiah(inv.outstanding)}).`,
    );
  let next: SalesOp = { ...op, amount, customerName: inv.customerName };
  if (!next.accountId) {
    const ctx = await deps.store.salesContext(who.linkId, inv.entityId);
    next = {
      ...next,
      today: ctx.today,
      accounts: ctx.accounts
        .filter((a) => a.currency === "IDR")
        .map((a) => ({ id: a.id, name: a.name })),
    };
    if (next.accounts.length === 0)
      return refusalOf(
        lang,
        "Entitas ini belum punya rekening rupiah untuk menerima pembayaran.",
        "This entity has no rupiah account to receive the payment.",
      );
    const named = matchAccount(next.accountWords, next.accounts);
    const only = next.accounts.length === 1 ? next.accounts[0] : undefined;
    const chosen = named ?? only;
    if (!chosen) return { op: { ...next, phase: "account" } };
    next = { ...next, accountId: chosen.id, accountName: chosen.name };
  }
  return { op: beginVerification(next) };
}

/** Runs `advance` and shows the result, or refuses and ends the conversation. */
async function proceed(
  op: SalesOp,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
  mode: "send" | "edit",
): Promise<void> {
  let step: Step;
  try {
    step = await advance(op, who, deps);
  } catch (error) {
    await deps.store.clearSession(who.linkId, chat, thread);
    await deps.api.sendMessage(chat, `⚠️ ${errorLine(error, who.lang)}`, threadOpts(thread));
    return;
  }
  if ("refuse" in step) {
    await deps.store.clearSession(who.linkId, chat, thread);
    if (op.messageId) await deps.api.clearKeyboard(chat, op.messageId);
    await deps.api.sendMessage(chat, step.refuse, threadOpts(thread));
    return;
  }
  await present(step.op, who, chat, thread, deps, mode);
}

async function present(
  op: SalesOp,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
  mode: "send" | "edit",
  notice?: string,
): Promise<void> {
  const rendered = renderOp(op);
  const view = notice ? { ...rendered, text: `${notice}\n\n${rendered.text}` } : rendered;
  let next = op;
  let how = mode;
  if (how === "edit" && op.messageId) {
    const edited = await deps.api.editMessage(chat, op.messageId, view.text, view.keyboard);
    if (!edited.ok && !/not modified/i.test(edited.error ?? "")) how = "send";
  } else {
    how = "send";
  }
  if (how === "send") {
    const sent = await deps.api.sendMessage(chat, view.text, {
      ...threadOpts(thread),
      keyboard: view.keyboard,
    });
    next = { ...op, messageId: sent.result?.message_id ?? null };
  }
  await deps.store.putOpSession(who.linkId, chat, thread, next);
}

// ---- answers ----------------------------------------------------------------------------------------------------

/** Handles a message while a sales conversation is open. Returns false when there is none. */
export async function continueSales(
  op: SalesOp,
  text: string,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
): Promise<void> {
  const lang = op.lang;
  const retry = async (hintId: string, hintEn: string) => {
    await deps.api.sendMessage(
      chat,
      `${L(lang, hintId, hintEn)} ${L(lang, "Atau ketik /batal.", "Or type /cancel.")}`,
      threadOpts(thread),
    );
  };

  if (op.phase !== "verify" && saysNo(text) && text.trim().split(/\s+/).length <= 2) {
    await cancel(op, who, chat, thread, deps, op.messageId);
    return;
  }

  let next: SalesOp | null = null;
  switch (op.phase) {
    case "entity": {
      const word = entityWordOf(text);
      const byWord = word
        ? op.entities.filter((e) => (word === "personal") === (e.type === "personal"))
        : [];
      let chosen: EntityChoice | undefined = byWord.length === 1 ? byWord[0] : undefined;
      if (!chosen) {
        const i = readChoice(
          text,
          op.entities.map((e) => e.name),
        );
        chosen = i !== null ? op.entities[i] : undefined;
      }
      if (!chosen)
        return retry(
          "Sebut PT atau pribadi, atau tekan tombolnya.",
          "Say PT or personal, or press a button.",
        );
      next = setEntity(op, chosen.id);
      break;
    }
    case "amount": {
      const amounts = parseAmounts(text);
      const value = amounts[0]?.value;
      if (amounts.length === 1 && value && value > 0) next = { ...op, amount: value };
      else
        return retry(
          "Nominalnya belum terbaca. Contoh: 2,5jt atau 2.500.000.",
          "I could not read the amount. Example: 2.5m or 2,500,000.",
        );
      break;
    }
    case "describe": {
      const description = text.trim().slice(0, 200);
      if (description.length >= 2) next = { ...op, description };
      else return retry("Tulis nama barang atau jasanya.", "Type the item or service.");
      break;
    }
    case "dup": {
      const a = readDupAnswer(text, op.candidates.length);
      if (a.kind === "unclear")
        return retry(
          op.candidates.length > 1
            ? "Ketik nomor pelanggan yang dipakai, atau <i>buat baru</i>."
            : "Ketik <i>pakai yang lama</i> atau <i>buat baru</i>.",
          op.candidates.length > 1
            ? "Type the number of the customer to use, or <i>create new</i>."
            : "Type <i>use the existing one</i> or <i>create new</i>.",
        );
      next = a.kind === "new" ? chooseNew(op) : chooseExisting(op, a.index);
      if (next.kind === "customer" && a.kind === "use")
        return finishWithExisting(next, who, chat, thread, deps);
      break;
    }
    case "channel": {
      if (/\b(?:tanpa|tidak|none|no|nggak|gak)\b/i.test(text))
        next = { ...op, channelId: null, channelName: null, channelAsked: true };
      else {
        const i = readChoice(
          text,
          op.channels.map((c) => c.name.replace(/^🔗\s*/, "")),
        );
        if (i === null)
          return retry(
            "Pilih tautan pembayarannya dengan tombol atau ketik namanya.",
            "Pick the payment link with a button or type its name.",
          );
        next = chooseChannel(op, i);
      }
      break;
    }
    case "invoice": {
      const i = readChoice(
        text,
        op.choices.map((c) => c.entityName),
      );
      if (i === null)
        return retry("Pilih entitasnya dengan tombol.", "Pick the entity with a button.");
      next = pickInvoice(op, i);
      break;
    }
    case "account": {
      const i = readChoice(
        text,
        op.accounts.map((a) => a.name),
      );
      const a = i !== null ? op.accounts[i] : undefined;
      if (!a)
        return retry(
          "Pilih rekeningnya dengan tombol atau ketik namanya.",
          "Pick the account with a button or type its name.",
        );
      next = { ...op, accountId: a.id, accountName: a.name };
      break;
    }
    case "verify":
      await verifyStep(op, { type: "text", text }, who, chat, thread, deps, "send");
      return;
  }
  if (!next) return;
  if (op.messageId) await deps.api.clearKeyboard(chat, op.messageId);
  await proceed({ ...next, messageId: null }, who, chat, thread, deps, "send");
}

function chooseNew(op: SalesOp): SalesOp {
  return { ...op, allowSimilar: true, looked: true, candidates: [] };
}

function chooseExisting(op: SalesOp, index: number): SalesOp {
  const c = op.candidates[index];
  if (!c) return op;
  return { ...op, customerId: c.id, customerName: c.name, looked: true, candidates: [] };
}

function chooseChannel(op: SalesOp, index: number): SalesOp {
  const c = op.channels[index];
  if (!c) return op;
  const account = c.accountId ? op.accounts.find((a) => a.id === c.accountId) : undefined;
  return {
    ...op,
    channelId: c.id,
    channelName: c.name.replace(/^🔗\s*/, ""),
    channelAsked: true,
    accountId: c.accountId ?? op.accountId,
    accountName: account?.name ?? op.accountName,
  };
}

function pickInvoice(op: SalesOp, index: number): SalesOp {
  const ref = op.choices[index];
  if (!ref) return op;
  return {
    ...op,
    invoice: ref,
    entityId: ref.entityId,
    entityName: ref.entityName,
    customerName: ref.customerName,
    choices: [],
  };
}

async function finishWithExisting(
  op: SalesOp,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
) {
  await deps.store.clearSession(who.linkId, chat, thread);
  if (op.messageId) await deps.api.clearKeyboard(chat, op.messageId);
  await deps.api.sendMessage(
    chat,
    L(
      op.lang,
      `Oke, tidak membuat pelanggan baru. <b>${escapeHtml(op.customerName)}</b> yang sudah terdaftar dipakai.`,
      `OK, no new customer was created. The existing <b>${escapeHtml(op.customerName)}</b> is used.`,
    ),
    threadOpts(thread),
  );
}

async function cancel(
  op: SalesOp,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
  messageId: number | null,
  reason: "said_no" | "too_many" = "said_no",
): Promise<void> {
  await deps.store.clearSession(who.linkId, chat, thread);
  if (messageId) await deps.api.clearKeyboard(chat, messageId);
  await deps.api.sendMessage(
    chat,
    reason === "too_many"
      ? L(
          op.lang,
          "❌ Dibatalkan karena jawaban salah tiga kali. Tidak ada yang dicatat.",
          "❌ Cancelled after three wrong answers. Nothing was recorded.",
        )
      : L(op.lang, "❌ Dibatalkan. Tidak ada yang dicatat.", "❌ Cancelled. Nothing was recorded."),
    threadOpts(thread),
  );
}

async function verifyStep(
  op: SalesOp,
  input: VerifyInput,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
  mode: "send" | "edit",
): Promise<void> {
  const v = op.verification;
  if (!v) return;
  const outcome = answer(v, input, {
    total: totalOf(op),
    now: deps.now().getTime(),
    newCode: () => String(randomInt(0, 10_000)).padStart(4, "0"),
  });
  switch (outcome.kind) {
    case "cancel":
      await cancel(op, who, chat, thread, deps, op.messageId, outcome.reason);
      return;
    case "done":
      await deps.store.clearSession(who.linkId, chat, thread);
      if (op.messageId) await deps.api.clearKeyboard(chat, op.messageId);
      await execute(op, who, chat, thread, deps);
      return;
    case "again": {
      const hint =
        outcome.reason === "expired"
          ? L(
              op.lang,
              "⏱️ Kodenya kedaluwarsa, ini kode baru.",
              "⏱️ The code expired, here is a new one.",
            )
          : L(op.lang, "Jawabannya belum cocok. Coba lagi.", "That did not match. Try again.");
      if (op.messageId) await deps.api.clearKeyboard(chat, op.messageId);
      await present(
        { ...op, verification: outcome.v, messageId: null },
        who,
        chat,
        thread,
        deps,
        "send",
        hint,
      );
      return;
    }
    case "next":
      if (mode === "send" && op.messageId) await deps.api.clearKeyboard(chat, op.messageId);
      await present(
        { ...op, verification: outcome.v, messageId: mode === "send" ? null : op.messageId },
        who,
        chat,
        thread,
        deps,
        mode,
      );
      return;
  }
}

// ---- buttons ----------------------------------------------------------------------------------------------------

export async function handleSalesCallback(
  action: string,
  arg: string,
  cb: TgCallbackQuery,
  who: Identity,
  chat: number,
  messageId: number,
  thread: number,
  deps: BotDeps,
): Promise<void> {
  const { nonce, value } = parseOpArg(arg);
  const op = await deps.store.getOpSession(who.linkId, chat, thread);
  if (!op || op.nonce !== nonce) {
    await deps.api.answerCallback(
      cb.id,
      L(who.lang, "Tombol ini sudah kedaluwarsa.", "This button has expired."),
    );
    await deps.api.clearKeyboard(chat, messageId);
    return;
  }
  const here: SalesOp = { ...op, messageId };
  const index = Number(value);
  await deps.api.answerCallback(cb.id);
  switch (action) {
    case "no":
      await cancel(here, who, chat, thread, deps, messageId);
      return;
    case "go":
      await verifyStep(here, { type: "button", action: "go" }, who, chat, thread, deps, "edit");
      return;
    case "ent": {
      const e = here.entities[index];
      if (!e) return;
      await proceed(setEntity(here, e.id), who, chat, thread, deps, "edit");
      return;
    }
    case "use": {
      const next = chooseExisting(here, index);
      if (next.kind === "customer") return finishWithExisting(next, who, chat, thread, deps);
      await proceed(next, who, chat, thread, deps, "edit");
      return;
    }
    case "new":
      await proceed(chooseNew(here), who, chat, thread, deps, "edit");
      return;
    case "chan":
      await proceed(
        value === "-"
          ? { ...here, channelId: null, channelName: null, channelAsked: true }
          : chooseChannel(here, index),
        who,
        chat,
        thread,
        deps,
        "edit",
      );
      return;
    case "inv":
      await proceed(pickInvoice(here, index), who, chat, thread, deps, "edit");
      return;
    case "acc": {
      const a = here.accounts[index];
      if (!a) return;
      await proceed(
        { ...here, accountId: a.id, accountName: a.name },
        who,
        chat,
        thread,
        deps,
        "edit",
      );
      return;
    }
  }
}

// ---- doing it ---------------------------------------------------------------------------------------------------

async function execute(
  op: SalesOp,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
): Promise<void> {
  const lang = op.lang;
  const reply = (text: string) => deps.api.sendMessage(chat, text, threadOpts(thread));
  try {
    if (!op.entityId) return;
    if (op.kind === "customer") {
      await deps.store.salesCreateCustomer(who.linkId, op.entityId, `${op.key}:c`, {
        name: op.customerName,
        email: op.email,
        phone: op.phone,
        allowSimilar: op.allowSimilar,
      });
      await reply(
        L(
          lang,
          `✅ Pelanggan <b>${escapeHtml(op.customerName)}</b> dibuat di ${escapeHtml(op.entityName)}.`,
          `✅ Customer <b>${escapeHtml(op.customerName)}</b> created in ${escapeHtml(op.entityName)}.`,
        ),
      );
      return;
    }
    if (op.kind === "invoice") {
      const customerId =
        op.customerId ??
        (await deps.store.salesCreateCustomer(who.linkId, op.entityId, `${op.key}:c`, {
          name: op.customerName,
          email: null,
          phone: null,
          allowSimilar: op.allowSimilar,
        }));
      const issued = await deps.store.salesIssueInvoice(who.linkId, op.entityId, op.key, {
        customerId,
        issueDate: op.today,
        dueDate: addDaysIso(op.today, op.dueDays),
        description: op.description,
        amount: op.amount,
        channelId: op.channelId,
        accountId: op.accountId,
      });
      const link = issued.token ? invoiceLink(deps.appUrl, issued.token) : null;
      await reply(
        [
          L(
            lang,
            `✅ Invoice <b>${escapeHtml(issued.number)}</b> resmi terbit — ${escapeHtml(op.entityName)}`,
            `✅ Invoice <b>${escapeHtml(issued.number)}</b> issued — ${escapeHtml(op.entityName)}`,
          ),
          `${L(lang, "Pelanggan", "Customer")}: ${escapeHtml(op.customerName)} · ${formatRupiah(issued.total)}`,
          `${L(lang, "Jatuh tempo", "Due")}: ${dateOf(lang, issued.dueDate)}`,
          `${L(lang, "Status", "Status")}: ${L(lang, "Dibuat → Diterbitkan, tercatat di jurnal · belum dibayar", "Draft → Issued, posted to the ledger · unpaid")}`,
          link
            ? `\n${L(lang, "Link invoice untuk pelanggan (memuat tautan pembayaran invoice ini):", "Invoice link for the customer (it carries this invoice's payment link):")}\n${link}`
            : `\n${L(lang, "Akunmu tidak boleh membagikan link invoice. Ambil linknya di website.", "Your account may not share invoice links. Get the link on the website.")}`,
          `\n${L(lang, "Cek kapan saja: <code>status", "Check any time: <code>status")} ${escapeHtml(issued.number)}</code>`,
        ].join("\n"),
      );
      return;
    }
    const inv = op.invoice;
    if (!inv || !op.accountId) return;
    const paid = await deps.store.salesRecordPayment(who.linkId, op.key, {
      invoiceId: inv.invoiceId,
      accountId: op.accountId,
      date: op.today,
      amount: op.amount,
    });
    const before = inv.outstanding === inv.total ? "unpaid" : "partial";
    const links = paid.token
      ? [
          `\n${L(lang, "Link invoice:", "Invoice link:")} ${invoiceLink(deps.appUrl, paid.token)}`,
          `${L(lang, "Link kuitansi:", "Receipt link:")} ${receiptLink(deps.appUrl, paid.token, paid.receiptNumber)}`,
        ]
      : [];
    await reply(
      [
        L(
          lang,
          `✅ Pembayaran <b>${formatRupiah(op.amount)}</b> untuk invoice <b>${escapeHtml(paid.invoiceNumber)}</b> resmi tercatat.`,
          `✅ Payment of <b>${formatRupiah(op.amount)}</b> for invoice <b>${escapeHtml(paid.invoiceNumber)}</b> recorded.`,
        ),
        `${L(lang, "Status", "Status")}: ${settlementLabel(before, lang)} → <b>${settlementLabel(paid.settlement, lang)}</b>${paid.outstanding > 0 ? ` (${L(lang, "sisa", "left")} ${formatRupiah(paid.outstanding)})` : ""}`,
        `${L(lang, "Kuitansi", "Receipt")}: ${escapeHtml(paid.receiptNumber)} · ${L(lang, "tercatat di jurnal", "posted to the ledger")}`,
        ...links,
      ].join("\n"),
    );
  } catch (error) {
    await reply(
      `⚠️ ${errorLine(error, lang)}\n${L(lang, "Tidak ada yang dicatat. Kirim perintahnya lagi bila perlu.", "Nothing was recorded. Send the command again if needed.")}`,
    );
  }
}

function addDaysIso(iso: string, days: number): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

// ---- looking an invoice up --------------------------------------------------------------------------------------

async function showInvoice(
  number: string,
  who: Identity,
  chat: number,
  thread: number,
  deps: BotDeps,
): Promise<void> {
  const lang = who.lang;
  let found: FoundInvoice[];
  try {
    found = await deps.store.salesFindInvoice(who.linkId, number);
  } catch (error) {
    await deps.api.sendMessage(chat, `⚠️ ${errorLine(error, lang)}`, threadOpts(thread));
    return;
  }
  if (found.length === 0) {
    await deps.api.sendMessage(
      chat,
      L(
        lang,
        `Invoice <b>${escapeHtml(number)}</b> tidak ditemukan, atau akunmu tidak boleh melihatnya.`,
        `Invoice <b>${escapeHtml(number)}</b> was not found, or your account may not see it.`,
      ),
      threadOpts(thread),
    );
    return;
  }
  for (const f of found) {
    const link = f.token ? invoiceLink(deps.appUrl, f.token) : null;
    const lines = [
      `🧾 <b>${escapeHtml(f.number)}</b> — ${escapeHtml(f.entityName)}`,
      `${L(lang, "Pelanggan", "Customer")}: ${escapeHtml(f.customer)}`,
      `${L(lang, "Total", "Total")} ${formatRupiah(f.total)} · ${L(lang, "dibayar", "paid")} ${formatRupiah(f.settled)} · ${L(lang, "sisa", "left")} ${formatRupiah(f.outstanding)}`,
      `${L(lang, "Status", "Status")}: <b>${f.status === "issued" ? settlementLabel(f.settlement, lang) : escapeHtml(f.status)}</b>${f.overdue ? ` ⚠️ ${L(lang, "lewat jatuh tempo", "overdue")} (${dateOf(lang, f.dueDate)})` : ` · ${L(lang, "jatuh tempo", "due")} ${dateOf(lang, f.dueDate)}`}`,
      link ? `${L(lang, "Link invoice:", "Invoice link:")} ${link}` : null,
      ...f.receipts.map(
        (r) =>
          `${L(lang, "Kuitansi", "Receipt")} ${escapeHtml(r.number)} · ${formatRupiah(r.amount)} · ${dateOf(lang, r.date)}${f.token ? `\n${receiptLink(deps.appUrl, f.token, r.number)}` : ""}`,
      ),
    ].filter(Boolean);
    await deps.api.sendMessage(chat, lines.join("\n"), threadOpts(thread));
  }
}
