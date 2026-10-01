import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import {
  membershipListSchema,
  overrideListSchema,
  permissionListSchema,
  profileListSchema,
  roleListSchema,
  rolePermissionListSchema,
  securityEventListSchema,
  trustedDeviceListSchema,
  type MembershipRow,
  type OverrideRow,
  type PermissionRow,
  type ProfileRow,
  type RoleRow,
  type SecurityEventRow,
  type TrustedDeviceRow,
} from "@/schemas/admin";

/**
 * Users & Roles and Security reads and commands (decision 246). Reads are direct, RLS-scoped table reads;
 * commands are the P2 RPCs `assign_membership`, `set_membership_status` and `set_permission_override`,
 * each of which checks its own permission, refuses a change to the caller's own access, protects OWNER
 * memberships and demands a recent step-up (`STEP_UP_REQUIRED`).
 */

async function read<T>(
  query: PromiseLike<{ data: unknown; error: unknown }>,
  schema: ZodType<T>,
  what: string,
): Promise<T> {
  const { data, error } = await query;
  if (error) throw new Error(`Gagal memuat ${what}.`);
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error(`Respons ${what} tidak dikenali.`);
  return parsed.data;
}

export async function listMemberships(entityId: string): Promise<MembershipRow[]> {
  const supabase = await createSupabaseServerClient();
  return read(
    supabase
      .from("entity_memberships")
      .select("id, user_id, role_id, status, disabled_at, created_at")
      .eq("entity_id", entityId)
      .order("created_at", { ascending: true }),
    membershipListSchema,
    "anggota",
  );
}

export async function listProfiles(userIds: readonly string[]): Promise<ProfileRow[]> {
  if (userIds.length === 0) return [];
  const supabase = await createSupabaseServerClient();
  return read(
    supabase
      .from("profiles")
      .select("id, display_name, is_active")
      .in("id", [...new Set(userIds)]),
    profileListSchema,
    "profil pengguna",
  );
}

export async function listRoles(): Promise<RoleRow[]> {
  const supabase = await createSupabaseServerClient();
  return read(
    supabase.from("roles").select("id, role_key, name, description").order("name"),
    roleListSchema,
    "peran",
  );
}

export async function listPermissions(): Promise<PermissionRow[]> {
  const supabase = await createSupabaseServerClient();
  return read(
    supabase.from("permissions").select("key, module, action, description").order("key"),
    permissionListSchema,
    "izin",
  );
}

export async function listRolePermissionKeys(roleId: string): Promise<string[]> {
  const supabase = await createSupabaseServerClient();
  const rows = await read(
    supabase.from("role_permissions").select("permission_key").eq("role_id", roleId),
    rolePermissionListSchema,
    "izin peran",
  );
  return rows.map((r) => r.permission_key);
}

export async function listOverrides(membershipId: string): Promise<OverrideRow[]> {
  const supabase = await createSupabaseServerClient();
  return read(
    supabase
      .from("membership_permission_overrides")
      .select("permission_key, effect, reason")
      .eq("membership_id", membershipId)
      .order("permission_key"),
    overrideListSchema,
    "pengecualian izin",
  );
}

export const SECURITY_PAGE_SIZE = 50;

export async function listSecurityEvents(
  entityId: string,
  offset: number,
): Promise<{ rows: SecurityEventRow[]; hasMore: boolean }> {
  const supabase = await createSupabaseServerClient();
  const rows = await read(
    supabase
      .from("security_events")
      .select("id, occurred_at, user_id, event_type, severity")
      .eq("entity_id", entityId)
      .order("occurred_at", { ascending: false })
      .order("id", { ascending: false })
      .range(offset, offset + SECURITY_PAGE_SIZE),
    securityEventListSchema,
    "kejadian keamanan",
  );
  return { rows: rows.slice(0, SECURITY_PAGE_SIZE), hasMore: rows.length > SECURITY_PAGE_SIZE };
}

/** Trusted devices of the given users. `fingerprint_hash` is never selected: the column grant excludes it. */
export async function listTrustedDevices(userIds: readonly string[]): Promise<TrustedDeviceRow[]> {
  if (userIds.length === 0) return [];
  const supabase = await createSupabaseServerClient();
  return read(
    supabase
      .from("trusted_devices")
      .select("id, user_id, label, first_seen_at, last_seen_at, trusted_until, revoked_at")
      .in("user_id", [...new Set(userIds)])
      .order("last_seen_at", { ascending: false }),
    trustedDeviceListSchema,
    "perangkat tepercaya",
  );
}

// ---------------------------------------------------------------- commands

async function rpc(name: string, args: Record<string, unknown>): Promise<void> {
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc(name, args);
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code);
    throw new Error("Perubahan akses tidak dapat diproses.");
  }
}

const reasonSchema = z.string().trim().min(5).max(500);

export async function assignMembershipRole(input: {
  entityId: string;
  userId: string;
  roleKey: string;
  reason: string;
}): Promise<void> {
  await rpc("assign_membership", {
    p_entity: z.uuid().parse(input.entityId),
    p_user: z.uuid().parse(input.userId),
    p_role_key: z
      .string()
      .regex(/^[a-z][a-z0-9_]*$/)
      .parse(input.roleKey),
    p_reason: reasonSchema.parse(input.reason),
  });
}

export async function setMembershipStatus(input: {
  membershipId: string;
  active: boolean;
  reason: string;
}): Promise<void> {
  await rpc("set_membership_status", {
    p_membership: z.uuid().parse(input.membershipId),
    p_active: input.active,
    p_reason: reasonSchema.parse(input.reason),
  });
}

export async function setPermissionOverride(input: {
  membershipId: string;
  permissionKey: string;
  effect: "grant" | "deny" | "clear";
  reason: string;
}): Promise<void> {
  await rpc("set_permission_override", {
    p_membership: z.uuid().parse(input.membershipId),
    p_key: z.string().min(1).max(100).parse(input.permissionKey),
    p_effect: z.enum(["grant", "deny", "clear"]).parse(input.effect),
    p_reason: reasonSchema.parse(input.reason),
  });
}
