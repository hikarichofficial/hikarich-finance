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
  }
}
