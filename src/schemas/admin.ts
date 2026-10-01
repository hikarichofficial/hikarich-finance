import { z } from "zod";

/**
 * Users & Roles and Security screens (decision 246). Every row is read directly under its table's own P2
 * RLS policy (`users.view` for memberships/profiles/overrides, any active user for roles/permissions,
 * `security.view` for security events and trusted devices); every write is a P2 RPC that itself demands
 * the right permission and a recent step-up.
 */
export const membershipRowSchema = z.object({
  id: z.uuid(),
  user_id: z.uuid(),
  role_id: z.uuid(),
  status: z.enum(["active", "disabled"]),
  disabled_at: z.string().nullable(),
  created_at: z.string(),
});
export const membershipListSchema = z.array(membershipRowSchema);
export type MembershipRow = z.infer<typeof membershipRowSchema>;

export const profileRowSchema = z.object({
  id: z.uuid(),
  display_name: z.string(),
  is_active: z.boolean(),
});
export const profileListSchema = z.array(profileRowSchema);
export type ProfileRow = z.infer<typeof profileRowSchema>;

export const roleRowSchema = z.object({
  id: z.uuid(),
  role_key: z.string(),
  name: z.string(),
  description: z.string().nullable(),
});
export const roleListSchema = z.array(roleRowSchema);
export type RoleRow = z.infer<typeof roleRowSchema>;

export const permissionRowSchema = z.object({
  key: z.string(),
  module: z.string(),
  action: z.string(),
  description: z.string().nullable(),
});
export const permissionListSchema = z.array(permissionRowSchema);
export type PermissionRow = z.infer<typeof permissionRowSchema>;

export const rolePermissionListSchema = z.array(z.object({ permission_key: z.string() }));

export const overrideRowSchema = z.object({
  permission_key: z.string(),
  effect: z.enum(["grant", "deny"]),
  reason: z.string().nullable(),
});
export const overrideListSchema = z.array(overrideRowSchema);
export type OverrideRow = z.infer<typeof overrideRowSchema>;

export const securityEventRowSchema = z.object({
  id: z.uuid(),
  occurred_at: z.string(),
  user_id: z.uuid().nullable(),
  event_type: z.string(),
  severity: z.enum(["info", "warning", "critical"]),
});
export const securityEventListSchema = z.array(securityEventRowSchema);
export type SecurityEventRow = z.infer<typeof securityEventRowSchema>;

export const trustedDeviceRowSchema = z.object({
  id: z.uuid(),
  user_id: z.uuid(),
  label: z.string().nullable(),
  first_seen_at: z.string(),
  last_seen_at: z.string(),
  trusted_until: z.string().nullable(),
  revoked_at: z.string().nullable(),
});
export const trustedDeviceListSchema = z.array(trustedDeviceRowSchema);
export type TrustedDeviceRow = z.infer<typeof trustedDeviceRowSchema>;
