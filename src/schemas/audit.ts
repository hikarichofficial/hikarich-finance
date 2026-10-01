import { z } from "zod";

/**
 * Audit Log screen rows (decision 242), read directly from `public.audit_events` under its own
 * `audit_events_select` RLS policy (`audit.view` on the row's Entity). `before_state`/`after_state` are
 * fetched only so the server can list which fields changed; their values are never rendered. Sensitive keys
 * are already stripped by the audit trigger itself (`app_private.tg_audit`'s per-table exclusion list).
 */
export const auditActorTypeSchema = z.enum(["user", "system", "public_token"]);
export type AuditActorType = z.infer<typeof auditActorTypeSchema>;

export const auditEventRowSchema = z.object({
  id: z.uuid(),
  occurred_at: z.string(),
  actor_type: auditActorTypeSchema,
  actor_id: z.uuid().nullable(),
  action: z.string(),
  target_table: z.string(),
  target_id: z.uuid().nullable(),
  before_state: z.record(z.string(), z.unknown()).nullable(),
  after_state: z.record(z.string(), z.unknown()).nullable(),
  reason: z.string().nullable(),
});
export const auditEventListSchema = z.array(auditEventRowSchema);
export type AuditEventRow = z.infer<typeof auditEventRowSchema>;

export const profileNameRowSchema = z.object({
  id: z.uuid(),
  display_name: z.string(),
});
export const profileNameListSchema = z.array(profileNameRowSchema);
