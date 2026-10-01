import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import {
  approvalRuleListSchema,
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
  "id, code, entity_type, legal_name, brand_name, base_currency, timezone, fiscal_year_start_month, status";
const PROFILE_COLUMNS =
  "address_line, city, province, postal_code, country_code, contact_email, contact_phone, website";
const NUMBERING_COLUMNS =
  "id, scope, prefix, separator, include_year, padding, reset_policy, is_active";
const APPROVAL_RULE_COLUMNS =
  "id, module, action, min_amount, requires_approval, approver_role_id, allow_self_approval, effective_from, effective_to";

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
