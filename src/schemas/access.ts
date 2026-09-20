import { z } from "zod";

/**
 * Shape of the `public.my_access()` RPC result. The application never trusts client-supplied Entity or
 * permission claims: this snapshot is produced by the database from the verified session (DECISIONS #27).
 */
export const membershipSchema = z.object({
  membership_id: z.uuid(),
  entity_id: z.uuid(),
  entity_code: z.string().min(1),
  entity_type: z.enum(["company", "personal", "other"]),
  entity_name: z.string(),
  role_key: z.string().min(1),
  mfa_required: z.boolean(),
  mfa_satisfied: z.boolean(),
  permissions: z.array(z.string()),
});

export const accessSnapshotSchema = z.object({
  user_id: z.uuid(),
  active: z.boolean(),
  display_name: z.string().nullable(),
  aal: z.string(),
  recent_step_up: z.boolean(),
  memberships: z.array(membershipSchema),
});

export type Membership = z.infer<typeof membershipSchema>;
export type AccessSnapshot = z.infer<typeof accessSnapshotSchema>;

/** Only same-site relative paths are accepted as post-login destinations (open-redirect defence). */
export const safeNextPathSchema = z
  .string()
  .max(512)
  .regex(/^\/(?!\/)(?!.*\\)[^\s]*$/, "must be a same-site relative path");

export const loginInputSchema = z.object({
  email: z.string().trim().toLowerCase().max(254).pipe(z.email()),
  password: z.string().min(1).max(1024),
});

export const otpCodeSchema = z
  .string()
  .trim()
  .regex(/^\d{6}$/, "Kode harus 6 digit angka");
