/**
 * Step-up authentication primitives (Step 06 §5; DECISIONS #27).
 *
 * A session counts as "recently verified" when the newest authentication event recorded in the JWT `amr`
 * claim is at most STEP_UP_WINDOW_MINUTES old. The same rule is enforced in the database
 * (`app_authz.recent_step_up()`); this module mirrors it so the application can decide whether to send
 * the person to the step-up screen BEFORE attempting a sensitive action. The database remains the
 * authority: if this check is bypassed the database still refuses with STEP_UP_REQUIRED.
 */
export const STEP_UP_WINDOW_MINUTES = 10;

export interface AmrEntry {
  method?: string;
  timestamp?: number;
}

export interface SessionClaims {
  sub?: string;
  aal?: string;
  amr?: AmrEntry[] | unknown;
  exp?: number;
}

/** Newest authentication timestamp (unix seconds) in the amr claim, or null. */
export function latestAuthTimestamp(amr: unknown): number | null {
  if (!Array.isArray(amr)) return null;
  let latest: number | null = null;
  for (const entry of amr) {
    const ts = (entry as AmrEntry | null)?.timestamp;
    if (typeof ts === "number" && Number.isFinite(ts) && (latest === null || ts > latest)) {
      latest = ts;
    }
  }
  return latest;
}

/** True when the session was (re)authenticated within the step-up window. `nowMs` is injectable for tests. */
export function isRecentStepUp(claims: SessionClaims, nowMs: number = Date.now()): boolean {
  const ts = latestAuthTimestamp(claims.amr);
  if (ts === null) return false;
  const ageSeconds = nowMs / 1000 - ts;
  // A timestamp in the future beyond small clock skew is not trusted.
  return ageSeconds >= -60 && ageSeconds <= STEP_UP_WINDOW_MINUTES * 60;
}

export function isAal2(claims: SessionClaims): boolean {
  return claims.aal === "aal2";
}
