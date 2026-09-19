import "server-only";
import { redirect } from "next/navigation";
import { getAccessSnapshot } from "@/lib/auth/session";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import {
  assertCan,
  membershipsNeedingMfa,
  resolveActiveEntity,
  safeNextPath,
} from "@/domain/authz/access";
import { AuthzError } from "@/domain/authz/errors";
import type { AccessSnapshot, Membership } from "@/schemas/access";

export interface AccessContext {
  access: AccessSnapshot;
  membership: Membership;
}

function withNext(path: string, next?: string): string {
  return next ? `${path}?next=${encodeURIComponent(safeNextPath(next))}` : path;
}

/**
 * Server-side gate for every protected page and action. Order of checks:
 *  1. valid session,
 *  2. active user (a disabled user is signed out immediately),
 *  3. MFA satisfied for every membership that requires it,
 *  4. at least one usable Entity membership.
 * The database re-checks all of this on every statement through RLS; this gate only chooses where to send
 * the person and keeps the UI honest.
 */
export async function requireAccess(options: { next?: string; entityCode?: string | null } = {}) {
  const access = await getAccessSnapshot();
  if (!access) redirect(withNext("/login", options.next));

  if (!access.active) {
    const supabase = await createSupabaseServerClient();
    await supabase.auth.signOut();
    redirect("/login?error=disabled");
  }

  if (membershipsNeedingMfa(access).length > 0) {
    redirect(withNext("/auth/mfa", options.next));
  }

  const membership = resolveActiveEntity(access, options.entityCode);
  if (!membership) redirect("/login?error=no_access");
  return { access, membership } satisfies AccessContext;
}

/** Requires a permission in the active Entity; throws FORBIDDEN (never silently succeeds). */
export async function requirePermission(
  permission: string,
  options: { next?: string; entityCode?: string | null } = {},
): Promise<AccessContext> {
  const context = await requireAccess(options);
  assertCan(context.access, context.membership.entity_id, permission);
  return context;
}

/**
 * Requires a recent re-authentication (10 minutes) for sensitive actions. Redirects to the step-up
 * screen and returns only when the window is satisfied. The database enforces the same rule on the
 * privileged RPCs, so a forged request that skips this call is still refused.
 */
export async function requireStepUp(next: string): Promise<void> {
  const access = await getAccessSnapshot();
  if (!access) redirect(withNext("/login", next));
  if (!access.recent_step_up) redirect(withNext("/auth/step-up", next));
}

export function isAuthzError(error: unknown): error is AuthzError {
  return error instanceof AuthzError;
}
