import { L, type Lang } from "./i18n";
import { parseAmounts } from "./rupiah";

/**
 * Layered verification for everything the bot does to the books beyond a plain expense (decision 425). The owner asked
 * that every kind of transaction be verified several times. How many times depends on the risk:
 *
 *   master  (a customer, a contact)             review -> final yes
 *   money   (invoice, payment, sending)         review -> retype the amount -> one-time code
 *   tax     (paying or filing tax)              review -> retype the amount -> recap -> one-time code
 *
 * Each step is answered with a button OR typed text. A wrong answer repeats the step (three wrong answers cancel), a
 * code expires after five minutes (a fresh one is issued), and any change to the thing being confirmed starts the
 * verification over, so a confirmation never covers something the owner did not see. Pure: no I/O, no clock, no random.
 */

export type VerifyLevel = "master" | "money" | "tax";
export type VerifyStep = "review" | "final" | "amount" | "recap" | "code";

export const STEPS: Record<VerifyLevel, readonly VerifyStep[]> = {
  master: ["review", "final"],
  money: ["review", "amount", "code"],
  tax: ["review", "amount", "recap", "code"],
};

export const CODE_TTL_MS = 5 * 60 * 1000;
export const MAX_WRONG = 3;

export interface Verification {
  level: VerifyLevel;
  /** Index into STEPS[level]. */
  index: number;
  wrong: number;
  /** The one-time code shown to the owner and the time it stops being valid. */
  code: string | null;
  codeUntil: number | null;
}

export function startVerification(level: VerifyLevel): Verification {
  return { level, index: 0, wrong: 0, code: null, codeUntil: null };
}

export function currentStep(v: Verification): VerifyStep {
  return STEPS[v.level][v.index] ?? "review";
}

export type VerifyInput = { type: "button"; action: "go" | "no" } | { type: "text"; text: string };

export type VerifyOutcome =
  | { kind: "next"; v: Verification }
  | { kind: "again"; v: Verification; reason: "wrong" | "expired" }
  | { kind: "done" }
  | { kind: "cancel"; reason: "said_no" | "too_many" };

export interface VerifyContext {
  /** The whole amount the owner must retype (the total of the operation). */
  total: number;
  now: number;
  /** Makes a fresh one-time code (four digits). */
  newCode: () => string;
}

const YES = new Set([
  "ya",
  "y",
  "yes",
  "ok",
  "oke",
  "okay",
  "lanjut",
  "lanjutkan",
  "setuju",
  "simpan",
  "benar",
  "betul",
  "siap",
  "confirm",
  "continue",
]);
const NO = new Set(["batal", "tidak", "tdk", "no", "n", "cancel", "stop", "jangan", "gak", "ga"]);

function words(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .split(/\s+/)
    .filter(Boolean);
}

/** True for a typed "ya"/"lanjut"/"ok" and the like, false for anything else. */
export function saysYes(text: string): boolean {
  const w = words(text);
  return w.length >= 1 && w.length <= 3 && w.every((x) => YES.has(x));
}

export function saysNo(text: string): boolean {
  const w = words(text);
  return w.length >= 1 && w.length <= 3 && w.some((x) => NO.has(x));
}

function advance(v: Verification, ctx: VerifyContext): VerifyOutcome {
  const index = v.index + 1;
  if (index >= STEPS[v.level].length) return { kind: "done" };
  const next: Verification = { ...v, index, wrong: 0, code: null, codeUntil: null };
  if (STEPS[v.level][index] === "code") {
    next.code = ctx.newCode();
    next.codeUntil = ctx.now + CODE_TTL_MS;
  }
  return { kind: "next", v: next };
}

function repeat(v: Verification, reason: "wrong" | "expired", ctx: VerifyContext): VerifyOutcome {
  if (reason === "expired") {
    return {
      kind: "again",
      reason,
      v: { ...v, wrong: 0, code: ctx.newCode(), codeUntil: ctx.now + CODE_TTL_MS },
    };
  }
  const wrong = v.wrong + 1;
  if (wrong >= MAX_WRONG) return { kind: "cancel", reason: "too_many" };
  return { kind: "again", reason, v: { ...v, wrong } };
}

/** Applies one answer to the current step. */
export function answer(v: Verification, input: VerifyInput, ctx: VerifyContext): VerifyOutcome {
  const step = currentStep(v);
  if (input.type === "button" && input.action === "no")
    return { kind: "cancel", reason: "said_no" };
  if (input.type === "text" && saysNo(input.text)) return { kind: "cancel", reason: "said_no" };

  switch (step) {
    case "review":
    case "recap":
    case "final": {
      const yes = input.type === "button" ? input.action === "go" : saysYes(input.text);
      return yes ? advance(v, ctx) : repeat(v, "wrong", ctx);
    }
    case "amount": {
      // The amount must be typed: pressing a button cannot prove the figure was read.
      if (input.type !== "text") return repeat(v, "wrong", ctx);
      const amounts = parseAmounts(input.text);
      const typed = amounts.length === 1 ? amounts[0]?.value : undefined;
      return typed === ctx.total ? advance(v, ctx) : repeat(v, "wrong", ctx);
    }
    case "code": {
      if (input.type !== "text") return repeat(v, "wrong", ctx);
      if (v.codeUntil !== null && ctx.now > v.codeUntil) return repeat(v, "expired", ctx);
      const typed = input.text.replace(/\D/g, "");
      return v.code !== null && typed === v.code ? { kind: "done" } : repeat(v, "wrong", ctx);
    }
  }
}

/** What the owner is asked at the current step (without the summary, which the operation supplies). */
export function stepPrompt(v: Verification, total: string, lang: Lang): string {
  const n = STEPS[v.level].length;
  const head = `🔐 ${L(lang, "Verifikasi", "Verification")} ${v.index + 1}/${n}`;
  switch (currentStep(v)) {
    case "review":
      return `${head}\n${L(lang, "Periksa ringkasan di atas. Lanjut?", "Check the summary above. Continue?")}`;
    case "final":
      return `${head}\n${L(lang, "Ketik <b>ya</b> (atau tekan tombol) untuk menyimpan.", "Type <b>yes</b> (or press the button) to save.")}`;
    case "amount":
      return `${head}\n${L(lang, `Ketik ulang nominalnya untuk memastikan Anda sudah membacanya: <b>${total}</b>`, `Type the amount again to show you read it: <b>${total}</b>`)}`;
    case "recap":
      return `${head}\n${L(lang, "Sekali lagi: masa pajak, nominal, dan pihak di atas sudah benar? Ketik <b>ya</b>.", "Once more: are the tax period, amount and party above right? Type <b>yes</b>.")}`;
    case "code": {
      const mins = Math.round(CODE_TTL_MS / 60000);
      return `${head}\n${L(lang, `Ketik kode ini untuk melaksanakan: <code>${v.code ?? ""}</code>\nBerlaku ${mins} menit.`, `Type this code to carry it out: <code>${v.code ?? ""}</code>\nValid for ${mins} minutes.`)}`;
    }
  }
}

/** Whether the step is answered with typed text only (the buttons are then just Batal). */
export function needsTyping(v: Verification): boolean {
  const s = currentStep(v);
  return s === "amount" || s === "code";
}
