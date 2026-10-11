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

/**
 * Short label for the Entity switch (decision 273, OWNER: "ubah menjadi Pribadi & PT"; corrected by
 * decision 402). A ledger whose legal name carries a legal-form prefix shows that form ("PT", "CV");
 * anything else is a person's own book and shows "Pribadi". The brand is not used here: it is only the
 * name the business trades as.
 *
 * A `personal` Entity used to show "Rumah Tangga", to keep the household ledger of Step 03 from being
 * mistaken for a personal business. That distinction stopped holding when decision 365 put Pajak Pribadi
 * -- the personal business's own PPh Final and progressive-services calculation -- behind
 * `entity_type = 'personal'`: a person's business must now BE a personal Entity, so the type no longer
 * tells the two apart and the label called the OWNER's own business a household book.
 */
export function entityLabel(membership: Pick<Membership, "entity_type" | "entity_name">): string {
  if (membership.entity_type === "company") {
    const form = /^(PT|CV)\b/i.exec(membership.entity_name.trim());
    return form?.[1] ? form[1].toUpperCase() : "Pribadi";
  }
  if (membership.entity_type === "personal") return "Pribadi";
  return membership.entity_name;
}
