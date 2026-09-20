import { safeNextPathSchema, type AccessSnapshot, type Membership } from "@/schemas/access";
import { AuthzError } from "./errors";

/**
 * Pure helpers over the database-produced access snapshot. They only ever narrow what the database
 * already decided; the database still enforces every read and write through RLS (Step 06, DECISIONS #27).
 */

export function activeMemberships(access: AccessSnapshot): Membership[] {
  return access.active ? access.memberships : [];
}

export function findMembership(access: AccessSnapshot, entityId: string): Membership | undefined {
  return activeMemberships(access).find((m) => m.entity_id === entityId);
}

export function can(access: AccessSnapshot, entityId: string, permission: string): boolean {
  const membership = findMembership(access, entityId);
  return membership !== undefined && membership.permissions.includes(permission);
}

/** Throws FORBIDDEN unless the actor holds the permission in that Entity. */
export function assertCan(access: AccessSnapshot, entityId: string, permission: string): void {
  if (!can(access, entityId, permission)) throw new AuthzError("FORBIDDEN");
}

/** Throws STEP_UP_REQUIRED when the session has not been re-verified within the step-up window. */
export function assertRecentStepUp(access: AccessSnapshot): void {
  if (!access.recent_step_up) throw new AuthzError("STEP_UP_REQUIRED");
}

/** A membership whose MFA requirement is unmet must complete MFA before anything else in that Entity. */
export function membershipsNeedingMfa(access: AccessSnapshot): Membership[] {
  return activeMemberships(access).filter((m) => m.mfa_required && !m.mfa_satisfied);
}

/**
 * Picks the Entity to show. An explicit, valid selection wins; otherwise the first usable membership
 * (memberships arrive ordered by Entity code). PT and Personal are never merged (Step 01 #4).
 */
export function resolveActiveEntity(
  access: AccessSnapshot,
  requestedEntityCode?: string | null,
): Membership | null {
  const usable = activeMemberships(access).filter((m) => !m.mfa_required || m.mfa_satisfied);
  if (requestedEntityCode) {
    const match = usable.find((m) => m.entity_code === requestedEntityCode);
    if (match) return match;
  }
  return usable[0] ?? null;
}

/** Returns a safe in-app destination, or the fallback when the candidate is absent or unsafe. */
export function safeNextPath(candidate: unknown, fallback = "/"): string {
  const parsed = safeNextPathSchema.safeParse(candidate);
  return parsed.success ? parsed.data : fallback;
}

/** Short label for the Entity switch: PT and Personal are always shown as distinct ledgers. */
export function entityLabel(membership: Pick<Membership, "entity_type" | "entity_name">): string {
  if (membership.entity_type === "company") return "PT";
  if (membership.entity_type === "personal") return "Personal";
  return membership.entity_name;
}
