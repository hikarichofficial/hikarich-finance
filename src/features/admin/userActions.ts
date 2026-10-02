"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import {
  assignMembershipRole,
  setMembershipStatus,
  revokeTrustedDevice,
  setPermissionOverride,
} from "@/services/admin/users";

/**
 * Users & Roles actions (decision 246). Each is a P2 RPC that re-checks the permission, refuses a change to
 * the caller's own access, protects OWNER memberships and demands a recent step-up; a missing step-up comes
 * back as `STEP_UP_REQUIRED`'s own copy, and the page offers the step-up link.
 */

export interface UserActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function fail(error: unknown, fallback: string): UserActionState {
  if (error instanceof AuthzError) return { status: "error", message: describeAuthzError(error) };
  return { status: "error", message: fallback };
}

function done(membershipId: string, message: string): UserActionState {
  revalidatePath("/admin/users");
  revalidatePath(`/admin/users/${membershipId}`);
  return { status: "ok", message };
}

export async function changeRoleAction(
  _previous: UserActionState,
  formData: FormData,
): Promise<UserActionState> {
  const membershipId = text(formData, "membership_id");
  try {
    const { membership } = await requirePermission("users.assign_role", {
      entityCode: text(formData, "entity"),
    });
    await assignMembershipRole({
      entityId: membership.entity_id,
      userId: text(formData, "user_id"),
      roleKey: text(formData, "role_key"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return fail(error, "Peran tidak dapat diubah. Alasan minimal 5 karakter.");
  }
  return done(membershipId, "Peran diperbarui.");
}

export async function setStatusAction(
  _previous: UserActionState,
  formData: FormData,
): Promise<UserActionState> {
  const membershipId = text(formData, "membership_id");
  const active = text(formData, "active") === "true";
  try {
    await setMembershipStatus({ membershipId, active, reason: text(formData, "reason") });
  } catch (error) {
    return fail(error, "Status keanggotaan tidak dapat diubah. Alasan minimal 5 karakter.");
  }
  return done(membershipId, active ? "Keanggotaan diaktifkan." : "Keanggotaan dinonaktifkan.");
}

export async function setOverrideAction(
  _previous: UserActionState,
  formData: FormData,
): Promise<UserActionState> {
  const membershipId = text(formData, "membership_id");
  const effect = text(formData, "effect");
  if (effect !== "grant" && effect !== "deny" && effect !== "clear") {
    return { status: "error", message: "Pilih efek pengecualian." };
  }
  try {
    await setPermissionOverride({
      membershipId,
      permissionKey: text(formData, "permission_key"),
      effect,
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return fail(error, "Pengecualian izin tidak dapat disimpan. Alasan minimal 5 karakter.");
  }
  return done(membershipId, "Pengecualian izin disimpan.");
}

export async function revokeDeviceAction(
  _previous: UserActionState,
  formData: FormData,
): Promise<UserActionState> {
  try {
    await requirePermission("security.view", { entityCode: text(formData, "entity") });
    await revokeTrustedDevice({
      deviceId: text(formData, "device_id"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return fail(error, "Perangkat tidak dapat dicabut. Alasan minimal 5 karakter.");
  }
  revalidatePath("/admin/security");
  return { status: "ok", message: "Perangkat dicabut." };
}
