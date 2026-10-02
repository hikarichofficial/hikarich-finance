/**
 * Authorization error contract shared by the database and the application (Step 06 §5, §8).
 *
 * The database raises exceptions whose message starts with one of these prefixes. The application maps
 * them to a typed error so callers never parse free text and never leak internals to the browser.
 */
export const AUTHZ_ERROR_CODES = [
  "UNAUTHENTICATED",
  "FORBIDDEN",
  "STEP_UP_REQUIRED",
  "INVALID",
  "LAST_OWNER",
  "CONFLICT",
] as const;

export type AuthzErrorCode = (typeof AUTHZ_ERROR_CODES)[number];

export class AuthzError extends Error {
  readonly code: AuthzErrorCode;
  constructor(code: AuthzErrorCode, message?: string) {
    super(message ?? code);
    this.name = "AuthzError";
    this.code = code;
  }
}

/** Extracts the authorization code from a database error message, or null when it is unrelated. */
export function parseAuthzCode(message: string | null | undefined): AuthzErrorCode | null {
  if (!message) return null;
  for (const code of AUTHZ_ERROR_CODES) {
    if (message === code || message.startsWith(`${code}:`) || message.startsWith(`${code} `)) {
      return code;
    }
  }
  return null;
}

/** Generic, user-safe copy (Indonesian). Never includes database detail. */
export function authzErrorMessage(code: AuthzErrorCode): string {
  switch (code) {
    case "UNAUTHENTICATED":
      return "Sesi tidak valid. Silakan masuk kembali.";
    case "FORBIDDEN":
      return "Anda tidak memiliki izin untuk tindakan ini.";
    case "STEP_UP_REQUIRED":
      return "Tindakan ini memerlukan verifikasi ulang. Masukkan kode autentikator Anda.";
    case "INVALID":
      return "Permintaan tidak valid.";
    case "LAST_OWNER":
      return "Tindakan ditolak: setidaknya satu OWNER aktif harus tetap ada.";
    case "CONFLICT":
      return "Data sudah berubah atau tidak dapat diproses dalam keadaan saat ini. Muat ulang lalu coba lagi.";
  }
}

/**
 * The copy a form shows for a failed command. For a refused request (`INVALID`) or a state conflict
 * (`CONFLICT`) the database's own reason is added: those messages are written as business explanations
 * ("a bill dated in the future stays a draft until its date") and without them the person cannot tell what
 * to change. Every other code stays generic, and nothing but the text after the prefix is ever shown.
 */
export function describeAuthzError(error: AuthzError): string {
  const base = authzErrorMessage(error.code);
  if (error.code !== "INVALID" && error.code !== "CONFLICT") return base;
  const match = /^(?:INVALID|CONFLICT):\s*([\s\S]+)$/.exec(error.message);
  const reason = match?.[1]?.trim();
  return reason ? `${base} (${reason})` : base;
}
