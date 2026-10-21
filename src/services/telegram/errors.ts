/** The database's own refusal, with its code prefix (FORBIDDEN, INVALID, CONFLICT). No server-only imports, so tests can use it. */
export class StoreError extends Error {
  readonly code: "FORBIDDEN" | "INVALID" | "CONFLICT" | "ERROR";
  constructor(message: string) {
    super(message);
    this.name = "StoreError";
    const m = /^(FORBIDDEN|INVALID|CONFLICT)/.exec(message);
    this.code = (m?.[1] as "FORBIDDEN" | "INVALID" | "CONFLICT" | undefined) ?? "ERROR";
  }
}

/** The human part of a database refusal ("INVALID: choose a period..." -> "choose a period..."). */
export function refusalText(message: string): string {
  return message.replace(/^(?:FORBIDDEN|INVALID|CONFLICT|ERROR)\s*:\s*/, "").trim();
}

/** What the owner is told when a database call fails: the refusal's own words, never a stack trace. */
export function errorLine(error: unknown, lang: "id" | "en" = "id"): string {
  const en = lang === "en";
  if (error instanceof StoreError) {
    if (error.code === "FORBIDDEN")
      return en ? "Your account may not do that." : "Akunmu tidak punya hak untuk itu.";
    return refusalText(error.message).slice(0, 200) || (en ? "Something went wrong." : "Terjadi kesalahan.");
  }
  return en
    ? "A server error occurred. Please try again in a moment."
    : "Terjadi kesalahan di server. Coba lagi sebentar lagi.";
}
