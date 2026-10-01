import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listTaxRuleVersions } from "@/services/tax/tax";
import {
  filterTaxRuleRows,
  parseRuleFamilyFilter,
  parseRuleStatusFilter,
} from "@/domain/tax/taxRulesList";
import { TaxRulesScreen } from "@/features/tax/TaxRulesScreen";

/** Tax Rules / Configuration List (decision 239, Step 05 §13). `?family=` filters by `family`, `?status=` by
 * `status`, `?q=` matches the code or source title/reference -- an absent or unknown value shows every row,
 * matching every other List screen's own null-filter meaning. Gated `tax.view` for the current Entity, the
 * same gate `/tax/ledger` and `/tax/calendar` already use, even though the rule master itself is global
 * (no `entity_id`): every Tax nav item stays reachable behind the same permission so the section is
 * consistent, and `listTaxRuleVersions` returns identical rows for every caller who passes the gate. */
export default async function TaxRulesPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; family?: string; status?: string; q?: string }>;
}) {
  const { entity, family, status, q } = await searchParams;
  const { access, membership } = await requirePermission("tax.view", { entityCode: entity });

  const ruleFamily = parseRuleFamilyFilter(family) ?? null;
  const ruleStatus = parseRuleStatusFilter(status) ?? null;
  const query = q ?? "";

  const allRows = await listTaxRuleVersions();
  const rows = filterTaxRuleRows(allRows, ruleFamily, ruleStatus, query);

  return (
    <TaxRulesScreen
      rows={rows}
      family={ruleFamily}
      status={ruleStatus}
      query={query}
      entity={entity}
      canManage={can(access, membership.entity_id, "tax.manage_rules")}
    />
  );
}
