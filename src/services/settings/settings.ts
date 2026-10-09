import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { IdentityError, identityFailure } from "@/domain/settings/identityFailure";
import { type InvoiceLayout, parseInvoiceLayout } from "@/domain/sales/invoiceLayout";
import {
  approvalRuleListSchema,
  createEntityInputSchema,
  entityIdentityInputSchema,
  entityTimeSettingsInputSchema,
  type CreateEntityInput,
  type EntityIdentityInput,
  type EntityTimeSettingsInput,
  entityProfileRowSchema,
  entitySettingListSchema,
  entitySummaryRowSchema,
  negativeBalanceBlockInputSchema,
  numberingSequenceListSchema,
  roleNameListSchema,
  type ApprovalRuleRow,
  type EntityProfileRow,
  type EntitySettingRow,
  type EntitySummaryRow,
  type NegativeBalanceBlockInput,
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

/** Changes which account kinds (`bank`, `cash`, `ewallet`) may never go negative (decision 55, OWNER
 * answer 4 October 2026) through `set_negative_balance_block`, which checks `system.entity_config` and a
 * recent step-up. Returns the kinds actually saved. */
export async function setNegativeBalanceBlock(input: NegativeBalanceBlockInput): Promise<string[]> {
  const v = negativeBalanceBlockInputSchema.parse(input);
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("set_negative_balance_block", {
    p_entity: v.entity_id,
    p_kinds: v.kinds,
  });
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Pengaturan tidak dapat disimpan.");
  }
  if (!Array.isArray(data)) throw new Error("Respons pengaturan tidak dikenali.");
  return data as string[];
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
    throw new IdentityError(identityFailure(error.message), error.message);
  }
  if (typeof data !== "number") throw new Error("Respons pengaturan tidak dikenali.");
  return data;
}

/** Adds an Entity (decision 276) through `create_entity`: only an OWNER, with a recent step-up; the new
 * Entity gets the standard chart of accounts and the caller as its OWNER. Returns the new Entity id. */
export async function createEntity(input: CreateEntityInput): Promise<string> {
  const v = createEntityInputSchema.parse(input);
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("create_entity", {
    p_code: v.code,
    p_entity_type: v.entity_type,
    p_legal_name: v.legal_name,
    p_brand_name: v.brand_name,
  });
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Entity tidak dapat dibuat.");
  }
  if (typeof data !== "string") throw new Error("Respons pengaturan tidak dikenali.");
  return data;
}

/** The company logo as an embedded image (decision 307), or `null`. A direct RLS-governed read of the
 * Entity's profile row; shown beside the issuer's name on invoices and receipts. */
export async function getEntityLogo(entityId: string): Promise<string | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("entity_profiles")
    .select("logo_data_url")
    .eq("entity_id", entityId)
    .maybeSingle();
  if (error || !data) return null;
  const logo = (data as { logo_data_url: string | null }).logo_data_url;
  return typeof logo === "string" && logo.startsWith("data:image/") ? logo : null;
}

/** Who the company is, for the top of a document an employee or a customer reads: the brand name if there is
 * one, the postal address and one contact line, plus the logo. One RLS-governed read of the Entity and its
 * profile -- `getEntitySettingsOverview` would do five for a page that needs none of the rest (decision 382). */
export async function getEntityLetterhead(entityId: string): Promise<{
  name: string;
  addressLines: string[];
  contact: string | null;
  logo: string | null;
}> {
  const supabase = await createSupabaseServerClient();
  const [entityRes, profileRes] = await Promise.all([
    supabase.from("entities").select("legal_name, brand_name").eq("id", entityId).maybeSingle(),
    supabase
      .from("entity_profiles")
      .select("address_line, city, province, postal_code, contact_email, contact_phone, logo_data_url")
      .eq("entity_id", entityId)
      .maybeSingle(),
  ]);
  const entity = entityRes.data as { legal_name?: string; brand_name?: string | null } | null;
  const profile = profileRes.data as Record<string, string | null> | null;

  const text = (key: string): string | null => {
    const value = profile?.[key];
    return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
  };
  const place = [text("city"), text("province"), text("postal_code")].filter(Boolean).join(", ");
  const contact = [text("contact_email"), text("contact_phone")].filter(Boolean).join(" \u00b7 ");
  const logo = profile?.logo_data_url;

  return {
    name: entity?.brand_name?.trim() || entity?.legal_name?.trim() || "",
    addressLines: [text("address_line"), place || null].filter((line): line is string => Boolean(line)),
    contact: contact === "" ? null : contact,
    logo: typeof logo === "string" && logo.startsWith("data:image/") ? logo : null,
  };
}

/** The saved invoice arrangement (decision 310): always a usable layout, the standard one when none is saved. */
export async function getInvoiceLayout(entityId: string): Promise<InvoiceLayout> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("entity_profiles")
    .select("invoice_layout")
    .eq("entity_id", entityId)
    .maybeSingle();
  if (error || !data) return parseInvoiceLayout(null);
  return parseInvoiceLayout((data as { invoice_layout: unknown }).invoice_layout);
}

/** Saves the invoice arrangement (`null` restores the standard) through `set_invoice_layout`, which checks
 * `system.entity_config` and a recent step-up, validates the layout and audits that it changed. */
export async function setInvoiceLayout(
  entityId: string,
  layout: InvoiceLayout | null,
): Promise<void> {
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc("set_invoice_layout", {
    p_entity: entityId,
    p_layout: layout,
  });
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Tampilan invoice tidak dapat disimpan.");
  }
}

/** Sets or removes (`null`) the company logo through `set_entity_logo`, which checks
 * `system.entity_config` and a recent step-up, validates the image and audits that it changed. */
export async function setEntityLogo(entityId: string, logo: string | null): Promise<void> {
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc("set_entity_logo", {
    p_entity: entityId,
    p_logo: logo,
  });
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Logo tidak dapat disimpan.");
  }
}
