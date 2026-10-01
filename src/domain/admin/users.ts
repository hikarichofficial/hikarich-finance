import type { OverrideRow } from "@/schemas/admin";

/**
 * Pure helpers for the Users & Roles screens (decision 246). The effective permission set shown here is a
 * read-out of the same rule the database applies (role permissions, plus `grant` overrides, minus `deny`
 * overrides); the database's own `app_authz.has_permission` remains the only authority.
 */

export const MEMBERSHIP_STATUS_LABELS = { active: "Aktif", disabled: "Nonaktif" } as const;

export interface EffectivePermission {
  key: string;
  source: "role" | "grant";
  denied: boolean;
}

/** Every permission the member ends up with or was denied, sorted by key. */
export function effectivePermissions(
  roleKeys: readonly string[],
  overrides: readonly OverrideRow[],
): EffectivePermission[] {
  const grants = new Set(
    overrides.filter((o) => o.effect === "grant").map((o) => o.permission_key),
  );
  const denies = new Set(overrides.filter((o) => o.effect === "deny").map((o) => o.permission_key));
  const fromRole = new Set(roleKeys);
  const keys = new Set([...fromRole, ...grants]);
  return [...keys].sort().map((key) => ({
    key,
    source: fromRole.has(key) ? "role" : "grant",
    denied: denies.has(key),
  }));
}

export interface UserAdminPermissions {
  canAssign: boolean; // users.assign_role and users.assign_entity
  canDisable: boolean; // users.disable
  canOverride: boolean; // users.change_permissions
}

/** Which access changes to offer on a membership. Nobody may change their own access (the RPCs refuse it),
 * so a person's own membership shows no actions at all. */
export function userAdminActions(isSelf: boolean, p: UserAdminPermissions): UserAdminPermissions {
  if (isSelf) return { canAssign: false, canDisable: false, canOverride: false };
  return p;
}

export const SECURITY_SEVERITY_LABELS = {
  info: "Info",
  warning: "Peringatan",
  critical: "Kritis",
} as const;

export const SECURITY_SEVERITY_TONE = {
  info: "neutral",
  warning: "attention",
  critical: "critical",
} as const;

/** `?offset=` as a non-negative multiple of `pageSize`; anything else is the first page. */
export function parsePageOffset(value: string | undefined, pageSize: number): number {
  if (value === undefined || !/^\d+$/.test(value)) return 0;
  const n = Number(value);
  return Number.isSafeInteger(n) && n % pageSize === 0 ? n : 0;
}
