import { authzErrorMessage } from "@/domain/authz/errors";

/**
 * True when an action's answer means "send me again after a fresh authenticator code": the action flagged it
 * (`stepUp`) or it carries the database's own re-verification copy (every action that maps an `AuthzError`
 * through `describeAuthzError` does, so a sensitive action opens the popup after Simpan/Submit even when its
 * author never added the flag).
 */
export function needsStepUp(state: unknown): boolean {
  if (typeof state !== "object" || state === null) return false;
  const { status, message, stepUp } = state as {
    status?: unknown;
    message?: unknown;
    stepUp?: unknown;
  };
  if (stepUp === true) return true;
  return status === "error" && message === authzErrorMessage("STEP_UP_REQUIRED");
}
