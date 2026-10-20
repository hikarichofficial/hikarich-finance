/**
 * The confirmation roadmap: a numbered list of steps ("Langkah 2 dari 4") the owner walks through before anything is
 * recorded, with a Back button. Pure state machine: `startDraft` builds the state from a parsed message, `render`
 * turns it into text plus buttons, `apply` takes a button press or typed text and returns the new state.
 *
 * Rules that matter:
 * - The Entity (PT or Pribadi) is NEVER guessed. It is taken from the words of the message ("pt", "pribadi"), from a
 *   group topic the owner mapped to an Entity, or - when the owner belongs to only one Entity - that one. Otherwise the
 *   bot asks "dicatat di entitas yang mana?".
 * - Nothing is saved without the final summary step.
 * Decision 422.
 */
import {
  ASSET_QUESTION_THRESHOLD,
  type CategoryOption,
  type LearnedRule,
  looksLikeAsset,
  learningKeyword,
  matchCategoryByName,
  orderForPicker,
  suggestCategories,
} from "./categorize";
import { formatDateId, parseDateHint } from "./dates";
import { type AccountOption, type EntityWord, matchAccount, type ParsedExpense } from "./message";
import { escapeHtml, entityIcon, entityShort, fit, weekdayName } from "./report";
import { formatRupiah, parseAmounts } from "./rupiah";

export type StepId = "nominal" | "entity" | "rekening" | "aset" | "kategori" | "ringkasan";

export interface EntityContext {
  entityId: string;
  entityType: string;
  entityName: string;
  today: string;
  canConfirm: boolean;
  categories: CategoryOption[];
  accounts: AccountOption[];
  vendors: Array<{ id: string; name: string }>;
  rules: LearnedRule[];
}

export interface DraftLine {
  description: string;
  amount: number;
  kind: "expense" | "asset";
  categoryId: string | null;
  /** The owner chose or confirmed the category (or a learned rule was certain). */
  categoryOk: boolean;
  assetAsked: boolean;
}

export type Awaiting = null | "amount" | "date" | "payee" | "category";

export interface DraftState {
  v: 1;
  nonce: string;
  /** Idempotency key for the save: one draft, one entry, however often a button is pressed. */
  key: string;
  messageId: number | null;
  source: "text" | "photo";
  step: StepId;
  history: StepId[];
  entityId: string | null;
  entityStated: boolean;
  accountId: string | null;
  accountStated: boolean;
  date: string;
  payeeName: string | null;
  lines: DraftLine[];
  nominalOk: boolean;
  awaiting: Awaiting;
  lineIndex: number;
  page: number;
  /** The words of the original message that point at an account. */
  accountWords: string[];
  /** An earlier bot entry this one replaces (a correction). */
  replaces: string | null;
}

export interface Env {
  contexts: readonly EntityContext[];
  /** Per-entry limit above which an entry stays a draft. */
  maxEntry: number;
}

export interface StartOptions {
  nonce: string;
  key: string;
  source: "text" | "photo";
  /** The Entity a group topic is mapped to, if any. */
  topicEntityId: string | null;
  today: string;
  replaces?: string | null;
}

export type Effect = { kind: "none" } | { kind: "save" } | { kind: "cancel" } | { kind: "stale" };

export interface Keyboard {
  rows: Array<Array<{ text: string; data: string }>>;
}

export interface Rendered {
  text: string;
  keyboard: Keyboard;
}

export type Input =
  { type: "callback"; action: string; arg: string } | { type: "text"; text: string };

const PAGE_SIZE = 6;

function contextOf(env: Env, entityId: string | null): EntityContext | null {
  return env.contexts.find((c) => c.entityId === entityId) ?? null;
}

function pickEntityByWord(env: Env, word: EntityWord): EntityContext | null {
  const matches = env.contexts.filter((c) =>
    word === "personal" ? c.entityType === "personal" : c.entityType !== "personal",
  );
  return matches.length === 1 ? (matches[0] ?? null) : null;
}

/** Builds the first state from a parsed message. The Entity may still be unknown. */
export function startDraft(parsed: ParsedExpense, env: Env, opts: StartOptions): DraftState {
  let entity: EntityContext | null = null;
  let stated = false;
  if (parsed.entityWord) {
    entity = pickEntityByWord(env, parsed.entityWord);
    stated = entity !== null;
  }
  if (!entity && opts.topicEntityId) {
    entity = contextOf(env, opts.topicEntityId);
    stated = entity !== null;
  }
  if (!entity && env.contexts.length === 1) {
    entity = env.contexts[0] ?? null;
    stated = entity !== null;
  }
  const state: DraftState = {
    v: 1,
    nonce: opts.nonce,
    key: opts.key,
    messageId: null,
    source: opts.source,
    step: "entity",
    history: [],
    entityId: entity?.entityId ?? null,
    entityStated: stated,
    accountId: null,
    accountStated: false,
    date: parsed.date ?? entity?.today ?? opts.today,
    payeeName: parsed.payee,
    lines: parsed.lines.map((l) => ({
      description: l.description,
      amount: l.amount,
      kind: "expense",
      categoryId: null,
      categoryOk: false,
      assetAsked: false,
    })),
    nominalOk: opts.source === "text",
    awaiting: null,
    lineIndex: 0,
    page: 0,
    accountWords: parsed.accountWords,
    replaces: opts.replaces ?? null,
  };
  if (entity) fillEntityDefaults(state, entity);
  return settle(state, env);
}

/** Account and category guesses that depend on the chosen Entity. */
function fillEntityDefaults(state: DraftState, ctx: EntityContext): void {
  state.accountId = null;
  state.accountStated = false;
  const named = matchAccount(state.accountWords, ctx.accounts);
  if (named) {
    state.accountId = named.id;
    state.accountStated = true;
  } else {
    for (const line of state.lines) {
      const rule = ctx.rules.find(
        (r) => r.accountId && textHas(line.description, state.payeeName, r.keyword),
      );
      if (rule?.accountId && ctx.accounts.some((a) => a.id === rule.accountId)) {
        state.accountId = rule.accountId;
        state.accountStated = true;
        break;
      }
    }
  }
  if (!state.accountId && ctx.accounts.length === 1) {
    state.accountId = ctx.accounts[0]?.id ?? null;
    state.accountStated = state.accountId !== null;
  }
  for (const line of state.lines) {
    line.kind = "expense";
    line.assetAsked = false;
    guessCategory(line, state, ctx);
  }
}

function textHas(description: string, payee: string | null, keyword: string): boolean {
  const k = keyword.toLowerCase();
  return `${description} ${payee ?? ""}`.toLowerCase().includes(k);
}

function guessCategory(line: DraftLine, state: DraftState, ctx: EntityContext): void {
  const text = `${line.description} ${state.payeeName ?? ""}`;
  const [best] = suggestCategories(text, line.kind, ctx.categories, ctx.rules);
  line.categoryId = best?.id ?? null;
  line.categoryOk = best?.confidence === "high";
}

function needsAssetQuestion(line: DraftLine, ctx: EntityContext): boolean {
  return (
    !line.assetAsked &&
    line.amount >= ASSET_QUESTION_THRESHOLD &&
    looksLikeAsset(line.description) &&
    ctx.categories.some((c) => c.kind === "asset")
  );
}

/** Is the step settled without asking? */
function resolved(step: StepId, state: DraftState, env: Env): boolean {
  const ctx = contextOf(env, state.entityId);
  switch (step) {
    case "nominal":
      return state.nominalOk;
    case "entity":
      return state.entityId !== null && state.entityStated;
    case "rekening":
      return state.accountId !== null && state.accountStated;
    case "aset":
      return !ctx || !state.lines.some((l) => needsAssetQuestion(l, ctx));
    case "kategori":
      return state.lines.every((l) => l.categoryId !== null && l.categoryOk);
    case "ringkasan":
      return false;
  }
}

/** The steps this draft goes through, in order. */
export function planFor(state: DraftState, env: Env): StepId[] {
  const ctx = contextOf(env, state.entityId);
  const steps: StepId[] = [];
  if (state.source === "photo") steps.push("nominal");
  steps.push("entity", "rekening");
  const assetRelevant = state.lines.some(
    (l) =>
      l.assetAsked ||
      l.kind === "asset" ||
      (l.amount >= ASSET_QUESTION_THRESHOLD && looksLikeAsset(l.description)),
  );
  if (assetRelevant && (!ctx || ctx.categories.some((c) => c.kind === "asset"))) steps.push("aset");
  steps.push("kategori", "ringkasan");
  return steps;
}

/** Moves to the first step that needs the owner, starting from the beginning of the plan. */
function settle(state: DraftState, env: Env): DraftState {
  const plan = planFor(state, env);
  let next: StepId = "ringkasan";
  for (const step of plan) {
    if (step === "ringkasan" || !resolved(step, state, env)) {
      next = step;
      break;
    }
  }
  return {
    ...state,
    step: next,
    awaiting: null,
    page: 0,
    lineIndex: firstOpenLine(state, next, env),
  };
}

function firstOpenLine(state: DraftState, step: StepId, env: Env): number {
  const ctx = contextOf(env, state.entityId);
  if (step === "kategori") {
    const i = state.lines.findIndex((l) => l.categoryId === null || !l.categoryOk);
    return i < 0 ? 0 : i;
  }
  if (step === "aset" && ctx) {
    const i = state.lines.findIndex((l) => needsAssetQuestion(l, ctx));
    return i < 0 ? 0 : i;
  }
  return 0;
}

function goTo(state: DraftState, step: StepId, env: Env): DraftState {
  const history = state.step === step ? state.history : [...state.history, state.step].slice(-12);
  return {
    ...state,
    step,
    history,
    awaiting: null,
    page: 0,
    lineIndex: firstOpenLine(state, step, env),
  };
}

/** The next step after finishing `state.step`, skipping steps that need nothing. */
function advance(state: DraftState, env: Env): DraftState {
  const plan = planFor(state, env);
  const at = plan.indexOf(state.step);
  for (const step of plan.slice(at + 1)) {
    if (step === "ringkasan" || !resolved(step, state, env)) return goTo(state, step, env);
  }
  return goTo(state, "ringkasan", env);
}

function stepLabel(step: StepId): string {
  switch (step) {
    case "nominal":
      return "Nominal";
    case "entity":
      return "Entitas";
    case "rekening":
      return "Rekening";
    case "aset":
      return "Aset atau biaya";
    case "kategori":
      return "Kategori";
    case "ringkasan":
      return "Ringkasan & simpan";
  }
}

function total(state: DraftState): number {
  return state.lines.reduce((s, l) => s + l.amount, 0);
}

function entityText(ctx: EntityContext): string {
  return `${entityIcon(ctx.entityType)} ${entityShort(ctx.entityType)}`;
}

function valueOf(step: StepId, state: DraftState, env: Env): string | null {
  const ctx = contextOf(env, state.entityId);
  switch (step) {
    case "nominal":
      return state.nominalOk ? formatRupiah(total(state)) : null;
    case "entity":
      return ctx && state.entityStated ? entityText(ctx) : null;
    case "rekening":
      return ctx?.accounts.find((a) => a.id === state.accountId)?.name ?? null;
    case "aset":
      return state.lines.some((l) => l.kind === "asset") ? "ada aset tetap" : "biaya biasa";
    case "kategori": {
      if (!ctx || !state.lines.every((l) => l.categoryId !== null)) return null;
      const names = state.lines.map(
        (l) => ctx.categories.find((c) => c.id === l.categoryId)?.name ?? "?",
      );
      return [...new Set(names)].join(", ");
    }
    case "ringkasan":
      return null;
  }
}

function roadmapBlock(state: DraftState, env: Env): { block: string; n: number; of: number } {
  const plan = planFor(state, env);
  const at = Math.max(0, plan.indexOf(state.step));
  const rows = plan.map((step, i) => {
    const num = i + 1;
    if (i < at || (step !== state.step && step !== "ringkasan" && resolved(step, state, env))) {
      const value = valueOf(step, state, env);
      const auto = i >= at ? " (otomatis)" : "";
      return `✅ ${num}. ${stepLabel(step)}${value ? `: ${escapeHtml(value)}` : ""}${auto}`;
    }
    if (step === state.step) return `▶️ <b>${num}. ${stepLabel(step)}</b>`;
    return `⚪ ${num}. ${stepLabel(step)}`;
  });
  return { block: rows.join("\n"), n: at + 1, of: plan.length };
}

function btn(
  state: DraftState,
  text: string,
  action: string,
  arg = "",
): { text: string; data: string } {
  return { text, data: `${state.nonce}|${action}|${arg}` };
}

function navRow(state: DraftState): Array<{ text: string; data: string }> {
  const row: Array<{ text: string; data: string }> = [];
  if (state.history.length > 0) row.push(btn(state, "◀️ Kembali", "back"));
  row.push(btn(state, "❌ Batal", "cancel"));
  return row;
}

function pagedChoices(
  state: DraftState,
  items: ReadonlyArray<{ label: string }>,
  action: string,
): Array<Array<{ text: string; data: string }>> {
  const start = state.page * PAGE_SIZE;
  const rows = items
    .slice(start, start + PAGE_SIZE)
    .map((item, i) => [btn(state, item.label.slice(0, 40), action, String(start + i))]);
  const pager: Array<{ text: string; data: string }> = [];
  if (state.page > 0) pager.push(btn(state, "‹ Sebelumnya", "page", String(state.page - 1)));
  if (start + PAGE_SIZE < items.length)
    pager.push(btn(state, "Lainnya ›", "page", String(state.page + 1)));
  if (pager.length > 0) rows.push(pager);
  return rows;
}

function categoryChoices(state: DraftState, ctx: EntityContext): CategoryOption[] {
  const line = state.lines[state.lineIndex];
  if (!line) return [];
  const text = `${line.description} ${state.payeeName ?? ""}`;
  const suggestions = suggestCategories(text, line.kind, ctx.categories, ctx.rules);
  return orderForPicker(ctx.categories, line.kind, suggestions).filter(
    (c) => !c.isParent || suggestions.some((s) => s.id === c.id),
  );
}

function limitNote(state: DraftState, env: Env, ctx: EntityContext | null): string {
  const sum = total(state);
  if (!ctx?.canConfirm)
    return "Akunmu tidak berhak mengonfirmasi, jadi ini disimpan sebagai <b>draf</b> untuk dikonfirmasi di website.";
  if (sum > env.maxEntry) {
    return `Melebihi batas bot (${formatRupiah(env.maxEntry)}), jadi disimpan sebagai <b>draf</b> untuk dikonfirmasi di website.`;
  }
  return "Setelah kamu tekan Simpan, catatan ini langsung <b>dikonfirmasi</b> ke pembukuan.";
}

/** Text and buttons for the current step. */
export function render(state: DraftState, env: Env): Rendered {
  const ctx = contextOf(env, state.entityId);
  const { block, n, of } = roadmapBlock(state, env);
  const head = `📝 <b>Catat pengeluaran</b> — Langkah ${n} dari ${of}\n\n${block}\n\n`;
  const rows: Keyboard["rows"] = [];
  let body = "";

  switch (state.step) {
    case "nominal": {
      body = `Total yang terbaca: <b>${formatRupiah(total(state))}</b>.\nSudah benar? Kalau salah, ketik nominal yang benar.`;
      rows.push([btn(state, "✅ Benar", "ok")]);
      break;
    }
    case "entity": {
      body =
        "Pengeluaran ini dicatat di <b>entitas yang mana</b>? Di chat tadi belum disebut PT atau pribadi.";
      for (const c of env.contexts)
        rows.push([
          btn(state, `${entityText(c)} · ${c.entityName}`.slice(0, 40), "ent", c.entityId),
        ]);
      break;
    }
    case "rekening": {
      if (!ctx || ctx.accounts.length === 0) {
        body = `Entitas ${ctx ? entityText(ctx) : ""} belum punya rekening/dompet aktif. Tambahkan dulu di website (menu Keuangan), lalu kirim ulang pesannya.`;
        break;
      }
      body = "Dibayar <b>pakai rekening mana</b>?";
      rows.push(
        ...pagedChoices(
          state,
          ctx.accounts.map((a) => ({ label: a.name })),
          "acc",
        ),
      );
      break;
    }
    case "aset": {
      const line = state.lines[state.lineIndex];
      body = line
        ? `<b>${escapeHtml(line.description)}</b> (${formatRupiah(line.amount)}) terlihat seperti barang tahan lama.\nDicatat sebagai <b>aset tetap</b> (nanti didaftarkan di website) atau <b>biaya biasa</b>?`
        : "Aset atau biaya?";
      rows.push(
        [btn(state, "🏷️ Aset tetap", "as", "a")],
        [btn(state, "🧾 Biaya biasa", "as", "e")],
      );
      break;
    }
    case "kategori": {
      const line = state.lines[state.lineIndex];
      if (!ctx || !line) break;
      const options = categoryChoices(state, ctx);
      const many = state.lines.length > 1 ? ` (${state.lineIndex + 1}/${state.lines.length})` : "";
      body = `Kategori untuk <b>${escapeHtml(line.description)}</b> — ${formatRupiah(line.amount)}${many}?\nPilih, atau ketik nama kategorinya.`;
      rows.push(
        ...pagedChoices(
          state,
          options.map((o) => ({ label: o.name })),
          "cat",
        ),
      );
      break;
    }
    case "ringkasan": {
      const rek = ctx?.accounts.find((a) => a.id === state.accountId)?.name ?? "—";
      const lineRows = state.lines.map((l) => {
        const cat = ctx?.categories.find((c) => c.id === l.categoryId)?.name ?? "—";
        const kind = l.kind === "asset" ? " 🏷️ aset" : "";
        return `• ${escapeHtml(l.description)} — ${formatRupiah(l.amount)} → ${escapeHtml(cat)}${kind}`;
      });
      body = [
        "<b>Cek dulu sebelum disimpan:</b>",
        `Entitas: ${ctx ? entityText(ctx) : "—"}${ctx ? ` · ${escapeHtml(ctx.entityName)}` : ""}`,
        `Tanggal: ${weekdayName(state.date)}, ${formatDateId(state.date)}`,
        `Rekening: ${escapeHtml(rek)}`,
        `Penerima: ${escapeHtml(payeeFor(state) ?? "—")}`,
        ...lineRows,
        `<b>Total: ${formatRupiah(total(state))}</b>`,
        "",
        limitNote(state, env, ctx),
      ].join("\n");
      rows.push([btn(state, "✅ Simpan", "save")]);
      rows.push([
        btn(state, "🏢 Entitas", "go", "entity"),
        btn(state, "💳 Rekening", "go", "rekening"),
        btn(state, "🏷️ Kategori", "go", "kategori"),
      ]);
      rows.push([
        btn(state, "💰 Nominal", "edit", "amount"),
        btn(state, "📅 Tanggal", "edit", "date"),
        btn(state, "🏪 Penerima", "edit", "payee"),
      ]);
      break;
    }
  }
  if (state.awaiting) {
    const prompts: Record<Exclude<Awaiting, null>, string> = {
      amount: "Ketik nominal yang benar (contoh: 85rb atau 1,2jt).",
      date: "Ketik tanggalnya (contoh: kemarin, 20 okt, 3 hari lalu).",
      payee: "Ketik nama penerima/toko (contoh: Warteg Bu Sri).",
      category: "Ketik nama kategorinya.",
    };
    body += `\n\n✏️ ${prompts[state.awaiting]}`;
  }
  rows.push(navRow(state));
  return { text: fit(head + body), keyboard: { rows } };
}

/** The name the books need as payee: the stated one, else the first description. */
export function payeeFor(state: DraftState): string | null {
  const stated = state.payeeName?.trim();
  if (stated) return stated.slice(0, 120);
  const first = state.lines[0]?.description.trim();
  if (!first) return null;
  return `Pembelian: ${first}`.slice(0, 120);
}

function sameTotalGuard(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0 && value <= 100_000_000_000;
}

/** Applies a button press or typed text. */
export function apply(
  state: DraftState,
  env: Env,
  input: Input,
): { state: DraftState; effect: Effect } {
  const ctx = contextOf(env, state.entityId);

  if (input.type === "callback") {
    const { action, arg } = input;
    const idx = Number(arg);
    switch (action) {
      case "cancel":
        return { state, effect: { kind: "cancel" } };
      case "back": {
        const previous = state.history[state.history.length - 1];
        if (!previous) return { state, effect: { kind: "none" } };
        return {
          state: {
            ...state,
            step: previous,
            history: state.history.slice(0, -1),
            awaiting: null,
            page: 0,
            lineIndex: firstOpenLine(state, previous, env),
          },
          effect: { kind: "none" },
        };
      }
      case "page":
        return {
          state: { ...state, page: Math.max(0, Number.isInteger(idx) ? idx : 0) },
          effect: { kind: "none" },
        };
      case "ok":
        if (state.step === "nominal")
          return { state: advance({ ...state, nominalOk: true }, env), effect: { kind: "none" } };
        return { state, effect: { kind: "none" } };
      case "ent": {
        if (state.step !== "entity" && state.step !== "ringkasan")
          return { state, effect: { kind: "stale" } };
        const chosen = env.contexts.find((c) => c.entityId === arg);
        if (!chosen) return { state, effect: { kind: "stale" } };
        const changed = chosen.entityId !== state.entityId;
        const next: DraftState = { ...state, entityId: chosen.entityId, entityStated: true };
        if (changed) {
          fillEntityDefaults(next, chosen);
          next.lines = next.lines.map((l) => ({ ...l }));
        }
        return { state: advance(next, env), effect: { kind: "none" } };
      }
      case "acc": {
        if (!ctx || !Number.isInteger(idx)) return { state, effect: { kind: "stale" } };
        const account = ctx.accounts[idx];
        if (!account) return { state, effect: { kind: "stale" } };
        return {
          state: advance({ ...state, accountId: account.id, accountStated: true }, env),
          effect: { kind: "none" },
        };
      }
      case "as": {
        const line = state.lines[state.lineIndex];
        if (!ctx || !line || (arg !== "a" && arg !== "e"))
          return { state, effect: { kind: "stale" } };
        const lines = state.lines.map((l, i) =>
          i === state.lineIndex ? { ...l, assetAsked: true } : l,
        );
        const target = lines[state.lineIndex];
        if (target) {
          target.kind = arg === "a" ? "asset" : "expense";
          guessCategory(target, { ...state, lines }, ctx);
        }
        const next = { ...state, lines };
        const another = lines.findIndex((l) => needsAssetQuestion(l, ctx));
        if (another >= 0)
          return { state: { ...next, lineIndex: another }, effect: { kind: "none" } };
        return { state: advance(next, env), effect: { kind: "none" } };
      }
      case "cat": {
        if (!ctx || !Number.isInteger(idx)) return { state, effect: { kind: "stale" } };
        const chosen = categoryChoices(state, ctx)[idx];
        if (!chosen) return { state, effect: { kind: "stale" } };
        return { state: chooseCategory(state, env, chosen.id), effect: { kind: "none" } };
      }
      case "go": {
        const step = arg as StepId;
        if (state.step !== "ringkasan" || !["entity", "rekening", "kategori"].includes(step))
          return { state, effect: { kind: "stale" } };
        const moved = goTo(state, step, env);
        if (step === "kategori") {
          const lines = moved.lines.map((l) => ({ ...l, categoryOk: false }));
          return { state: { ...moved, lines, lineIndex: 0 }, effect: { kind: "none" } };
        }
        return { state: moved, effect: { kind: "none" } };
      }
      case "edit": {
        if (state.step !== "ringkasan" || !["amount", "date", "payee"].includes(arg))
          return { state, effect: { kind: "stale" } };
        return { state: { ...state, awaiting: arg as Awaiting }, effect: { kind: "none" } };
      }
      case "save":
        if (state.step !== "ringkasan") return { state, effect: { kind: "stale" } };
        if (!state.entityId || !state.accountId || state.lines.some((l) => l.categoryId === null))
          return { state, effect: { kind: "stale" } };
        return { state, effect: { kind: "save" } };
      default:
        return { state, effect: { kind: "stale" } };
    }
  }

  return applyText(state, env, input.text, ctx);
}

function chooseCategory(state: DraftState, env: Env, categoryId: string): DraftState {
  const lines = state.lines.map((l, i) =>
    i === state.lineIndex ? { ...l, categoryId, categoryOk: true } : l,
  );
  const next = { ...state, lines };
  const open = lines.findIndex((l) => l.categoryId === null || !l.categoryOk);
  if (open >= 0 && state.step === "kategori") return { ...next, lineIndex: open, page: 0 };
  return advance(next, env);
}

function applyText(
  state: DraftState,
  env: Env,
  text: string,
  ctx: EntityContext | null,
): { state: DraftState; effect: Effect } {
  const none = { state, effect: { kind: "none" } as Effect };
  const clean = text.trim();
  if (clean.length === 0 || clean.length > 200) return none;

  const mode: Awaiting =
    state.awaiting ??
    (state.step === "nominal" ? "amount" : state.step === "kategori" ? "category" : null);

  if (mode === "amount") {
    const [first] = parseAmounts(clean);
    const value = first?.value ?? Number(clean.replace(/[^\d]/g, ""));
    if (!sameTotalGuard(value)) return none;
    const lines =
      state.lines.length === 1
        ? state.lines.map((l) => ({ ...l, amount: value }))
        : scaleLines(state.lines, value);
    const next = { ...state, lines, nominalOk: true, awaiting: null };
    return {
      state: state.step === "nominal" ? advance(next, env) : next,
      effect: { kind: "none" },
    };
  }
  if (mode === "date") {
    const today = ctx?.today ?? state.date;
    const hint = parseDateHint(clean, today);
    if (!hint) return none;
    return { state: { ...state, date: hint.date, awaiting: null }, effect: { kind: "none" } };
  }
  if (mode === "payee") {
    return {
      state: { ...state, payeeName: clean.slice(0, 120), awaiting: null },
      effect: { kind: "none" },
    };
  }
  if (mode === "category" && ctx) {
    const line = state.lines[state.lineIndex];
    if (!line) return none;
    const found = matchCategoryByName(clean, ctx.categories, line.kind);
    if (!found) return none;
    return { state: chooseCategory(state, env, found.id), effect: { kind: "none" } };
  }
  if (state.step === "entity") {
    const lower = clean.toLowerCase();
    const wanted = /\bpribadi\b/.test(lower)
      ? "personal"
      : /\b(?:pt|perusahaan|usaha)\b/.test(lower)
        ? "company"
        : null;
    const chosen = wanted ? pickEntityByWord(env, wanted) : null;
    if (!chosen) return none;
    const next: DraftState = { ...state, entityId: chosen.entityId, entityStated: true };
    fillEntityDefaults(next, chosen);
    return { state: advance(next, env), effect: { kind: "none" } };
  }
  if (state.step === "rekening" && ctx) {
    const account =
      matchAccount([clean.toLowerCase()], ctx.accounts) ??
      ctx.accounts.find((a) => a.name.toLowerCase().includes(clean.toLowerCase()));
    if (!account) return none;
    return {
      state: advance({ ...state, accountId: account.id, accountStated: true }, env),
      effect: { kind: "none" },
    };
  }
  return none;
}

/** A new total over several lines: scale each line, the last takes the rounding remainder. */
function scaleLines(lines: DraftLine[], newTotal: number): DraftLine[] {
  const old = lines.reduce((s, l) => s + l.amount, 0);
  if (old <= 0) return lines;
  let used = 0;
  return lines.map((l, i) => {
    const amount =
      i === lines.length - 1 ? newTotal - used : Math.round((l.amount / old) * newTotal);
    used += amount;
    return { ...l, amount: Math.max(1, amount) };
  });
}

export interface RecordPayload {
  entityId: string;
  accountId: string;
  date: string;
  payeeName: string;
  lines: Array<{ description: string; quantity: number; unit_price: number; category_id: string }>;
  key: string;
  replaces: string | null;
}

/** What `telegram_record_expense` needs. Null while something is still missing. */
export function toRecordPayload(state: DraftState): RecordPayload | null {
  const payee = payeeFor(state);
  if (!state.entityId || !state.accountId || !payee) return null;
  const lines: RecordPayload["lines"] = [];
  for (const l of state.lines) {
    if (!l.categoryId) return null;
    lines.push({
      description: l.description.slice(0, 200),
      quantity: 1,
      unit_price: l.amount,
      category_id: l.categoryId,
    });
  }
  return {
    entityId: state.entityId,
    accountId: state.accountId,
    date: state.date,
    payeeName: payee,
    lines,
    key: state.key,
    replaces: state.replaces,
  };
}

export interface LearnEntry {
  entityId: string;
  keyword: string;
  categoryId: string;
  accountId: string | null;
  payeeName: string | null;
}

/** What the bot should remember from a saved draft: one rule per line the owner decided. */
export function learnEntries(state: DraftState, env: Env): LearnEntry[] {
  const ctx = contextOf(env, state.entityId);
  if (!ctx || !state.entityId) return [];
  const out: LearnEntry[] = [];
  for (const l of state.lines) {
    if (!l.categoryId) continue;
    const keyword = learningKeyword(l.description, state.payeeName);
    if (!keyword) continue;
    const known = ctx.rules.find((r) => r.keyword === keyword && r.categoryId === l.categoryId);
    if (known) continue;
    out.push({
      entityId: state.entityId,
      keyword,
      categoryId: l.categoryId,
      accountId: state.accountId,
      payeeName: state.payeeName,
    });
  }
  return out;
}

/** Parses `nonce|action|arg`. Null when it is not one of ours. */
export function parseCallbackData(
  data: string,
): { nonce: string; action: string; arg: string } | null {
  const parts = data.split("|");
  if (parts.length !== 3 || !parts[0] || !parts[1]) return null;
  return { nonce: parts[0], action: parts[1], arg: parts[2] ?? "" };
}
