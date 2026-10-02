import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import {
  approvalRuleListSchema,
  entityIdentityInputSchema,
  entityTimeSettingsInputSchema,
  type EntityIdentityInput,
  type EntityTimeSettingsInput,
  entityProfileRowSchema,
  entitySettingListSchema,
  entitySummaryRowSchema,
  numberingSequenceListSchema,
  roleNameListSchema,
  type ApprovalRuleRow,
  type EntityProfileRow,
  type EntitySettingRow,
  type EntitySummaryRow,
  type NumberingSequenceRow,
} from "@/schemas/settings";

/**
 * Settings screen reads (decision 243). No RPC returns an Entity's configuration, so each section reads
 * its own table directly under that table's existing RLS policy -- the direct-table-read precedent of
 * decisions 161/167/170-173/239/242. Read-only: nothing here writes.
 */

const ENTITY_COLUMNS =
  "id, code, entity_type, legal_name, brand_name, base_currency, timezone, fiscal_year_start_month, status, version";
const PROFILE_COLUMNS =
  "address_line, city, province, postal_code, country_code, contact_email, contact_phone, website";
const NUMBERING_COLUMNS =
  "id, scope, prefix, separator, include_year, padding, reset_policy, is_active";
const APPROVAL_RULE_COLUMNS =
  "id, module, action, min_amount::text, requires_approval, approver_role_id, allow_self_approval, effective_from, effective_to";

export interface EntitySettingsOverview {
  entity: EntitySummaryRow;
  profile: EntityProfileRow | null;
  numbering: NumberingSequenceRow[];
  approvalRules: ApprovalRuleRow[];
  roleNames: Map<string, string>;
  settings: EntitySettingRow[];
}

function fail(what: string): never {
  throw new Error(`Gagal memuat ${what}.`);
}

export async function getEntitySettingsOverview(entityId: string): Promise<EntitySettingsOverview> {
  const supabase = await createSupabaseServerClient();
  const [entityRes, profileRes, numberingRes, rulesRes, settingsRes] = await Promise.all([
    supabase.from("entities").select(ENTITY_COLUMNS).eq("id", entityId).maybeSingle(),
    supabase
      .from("entity_profiles")
      .select(PROFILE_COLUMNS)
      .eq("entity_id", entityId)
      .maybeSingle(),
    supabase
      .from("numbering_sequences")
      .select(NUMBERING_COLUMNS)
      .eq("entity_id", entityId)
      .order("scope", { ascending: true }),
    supabase
      .from("approval_rules")
      .select(APPROVAL_RULE_COLUMNS)
      .eq("entity_id", entityId)
      .order("module", { ascending: true })
      .order("action", { ascending: true })
      .order("effective_from", { ascending: false }),
    supabase
      .from("entity_settings")
      .select("setting_key, setting_value")
      .eq("entity_id", entityId)
      .order("setting_key", { ascending: true }),
  ]);

  if (entityRes.error || !entityRes.data) fail("profil entitas");
  const entity = entitySummaryRowSchema.safeParse(entityRes.data);
  if (!entity.success) fail("profil entitas");

  if (profileRes.error) fail("profil entitas");
  let profile: EntityProfileRow | null = null;
  if (profileRes.data) {
    const parsedProfile = entityProfileRowSchema.safeParse(profileRes.data);
    if (!parsedProfile.success) fail("profil entitas");
    profile = parsedProfile.data;
  }

  if (numberingRes.error) fail("penomoran dokumen");
  const numbering = numberingSequenceListSchema.safeParse(numberingRes.data);
  if (!numbering.success) fail("penomoran dokumen");

  if (rulesRes.error) fail("aturan persetujuan");
  const approvalRules = approvalRuleListSchema.safeParse(rulesRes.data);
  if (!approvalRules.success) fail("aturan persetujuan");

  if (settingsRes.error) fail("pengaturan entitas");
  const settings = entitySettingListSchema.safeParse(settingsRes.data);
  if (!settings.success) fail("pengaturan entitas");

  const roleIds = [
    ...new Set(approvalRules.data.flatMap((r) => (r.approver_role_id ? [r.approver_role_id] : []))),
  ];
  let roleNames = new Map<string, string>();
  if (roleIds.length > 0) {
    const rolesRes = await supabase.from("roles").select("id, name").in("id", roleIds);
    if (rolesRes.error) fail("nama peran");
    const roles = roleNameListSchema.safeParse(rolesRes.data);
    if (!roles.success) fail("nama peran");
    roleNames = new Map(roles.data.map((r) => [r.id, r.name]));
  }

  return {
    entity: entity.data,
    profile,
    numbering: numbering.data,
    approvalRules: approvalRules.data,
    roleNames,
    settings: settings.data,
  };
}

/** Whether the Entity already has an accounting period (the fiscal-year start is then locked, decision
 * 248). `null` when the caller cannot read periods (`accounting.view`); the database still enforces it. */
export async function entityHasAccountingPeriods(entityId: string): Promise<boolean | null> {
  const supabase = await createSupabaseServerClient();
  const { count, error } = await supabase
    .from("accounting_periods")
    .select("id", { count: "exact", head: true })
    .eq("entity_id", entityId);
  if (error) return null;
  return (count ?? 0) > 0;
}

/** Changes the Entity's timezone and fiscal-year start (decision 248) through
 * `update_entity_time_settings`, which checks `system.entity_config`, a recent step-up, the reason and
 * the version, and audits the change. Returns the new version. */
export async function updateEntityTimeSettings(input: EntityTimeSettingsInput): Promise<number> {
  const v = entityTimeSettingsInputSchema.parse(input);
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("update_entity_time_settings", {
    p_entity: v.entity_id,
    p_timezone: v.timezone,
    p_fiscal_year_start_month: v.fiscal_year_start_month,
    p_expected_version: v.expected_version,
    p_reason: v.reason,
  });
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Pengaturan tidak dapat disimpan.");
  }
  if (typeof data !== "number") throw new Error("Respons pengaturan tidak dikenali.");
  return data;
}

/** Changes the Entity's names, address and contact details (decision 272) through
 * `update_entity_identity`, which checks `system.entity_config`, a recent step-up and the version, and
 * audits the change. Returns the Entity version afterwards. */
export async function updateEntityIdentity(input: EntityIdentityInput): Promise<number> {
  const v = entityIdentityInputSchema.parse(input);
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("update_entity_identity", {
    p_entity: v.entity_id,
    p_legal_name: v.legal_name,
    p_brand_name: v.brand_name,
    p_address_line: v.address_line,
    p_city: v.city,
    p_province: v.province,
    p_postal_code: v.postal_code,
    p_contact_email: v.contact_email,
    p_contact_phone: v.contact_phone,
    p_website: v.website,
    p_expected_version: v.expected_version,
  });
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Profil tidak dapat disimpan.");
  }
  if (typeof data !== "number") throw new Error("Respons pengaturan tidak dikenali.");
  return data;
}
