import { createHmac } from "node:crypto";

/**
 * Salted hash of the requester of a public payment claim (DECISIONS 70). The database stores only this value
 * and uses it for the per-requester abuse limit; it is never shown, never part of an audit entry, and cannot be
 * reversed to an address without the server-side salt. The hash is 64 hex characters (the database accepts
 * 16-128).
 */
export function hashRequester(salt: string, address: string, userAgent: string): string {
  const who = `${address.trim().toLowerCase() || "unknown"}|${userAgent.trim().slice(0, 200)}`;
  return createHmac("sha256", salt).update(who).digest("hex");
}

/** The first address of a forwarded-for list (the platform proxy puts the real client first). */
export function firstForwardedAddress(header: string | null | undefined): string {
  if (!header) return "";
  return header.split(",")[0]?.trim() ?? "";
}
