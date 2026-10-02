import translations from "./reasonTranslations.json";

/**
 * Indonesian text for the reasons the database gives when it refuses a request (decision 271).
 *
 * The database raises `INVALID: <reason>` / `CONFLICT: <reason>` in English, written with PostgreSQL's
 * `format` placeholders (`%`). `reasonTranslations.json` holds each English template (extracted from the
 * migrations) with its Indonesian text, where `{1}`, `{2}`... stand for the placeholders in order. A
 * reason is matched against the templates and the captured values are put into the Indonesian text; a
 * reason no template matches is returned as `null` and the caller shows the English original.
 *
 * Display only: nothing here decides anything, and the database's own message is unchanged.
 */
interface Template {
  pattern: RegExp;
  text: string;
  /** Literal characters in the template: the most specific template is tried first. */
  weight: number;
}

let compiled: Template[] | null = null;

function escapeRegExp(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function compile(): Template[] {
  const list: Template[] = [];
  for (const [english, indonesian] of translations as [string, string][]) {
    // `%%` is a literal percent sign in `format`; every other `%` is a value.
    const parts = english
      .split("%%")
      .map((piece) => piece.split("%").map(escapeRegExp).join("(.+?)"));
    list.push({
      pattern: new RegExp(`^${parts.join("%")}$`, "s"),
      text: indonesian,
      weight: english.replace(/%/g, "").length,
    });
  }
  return list.sort((a, b) => b.weight - a.weight);
}

function sentence(text: string): string {
  const trimmed = text.trim();
  if (trimmed === "") return trimmed;
  const capitalised = trimmed.charAt(0).toUpperCase() + trimmed.slice(1);
  return /[.!?]$/.test(capitalised) ? capitalised : `${capitalised}.`;
}

export function translateReason(reason: string): string | null {
  compiled ??= compile();
  const input = reason.trim();
  for (const template of compiled) {
    const match = template.pattern.exec(input);
    if (!match) continue;
    return sentence(
      template.text.replace(/\{(\d+)\}/g, (_, index: string) => match[Number(index)] ?? ""),
    );
  }
  return null;
}
