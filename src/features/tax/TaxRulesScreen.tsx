import Link from "next/link";
import { RULE_STATUS_LABELS, RULE_STATUS_TONE } from "@/domain/tax/tax";
import {
  RULE_FAMILY_FILTER_OPTIONS,
  RULE_STATUS_FILTER_OPTIONS,
  ruleFamilyLabel,
} from "@/domain/tax/taxRulesList";
import type { RuleFamily, RuleStatus } from "@/domain/tax/tax";
import type { TaxRuleVersionRow } from "@/schemas/tax";
import { formatShortDate } from "./format";

/**
 * Tax Rules / Configuration List (decision 239, Step 05 §13, P13 unbuilt-screens backlog): every version of
 * every rule in the global statutory rule master, read-only. Follows the Standard List Screen Pattern
 * (`TaxLedgerScreen`'s own toolbar shape) with family/status filters and a code/source search in one GET form.
 *
 * Not Entity-scoped -- the rule master applies to every Entity alike (`public.tax_rule_versions` carries no
 * `entity_id`) -- so unlike every other List screen in this app there is no per-row Entity to show; `entity`
 * is threaded through only to keep the nav's own Entity switcher and the `?entity=` query param intact across
 * navigation, exactly as `TaxLedgerScreen` already does for a screen a caller reaches through the Tax section.
 *
 * With `tax.manage_rules`, "Aturan baru" starts a new rule; existing rules are adjusted from their Detail
 * screen by a new version (decision 249, OWNER answer to decision 239).
 */
export function TaxRulesScreen({
  rows,
  family,
  status,
  query,
  entity,
  canManage = false,
}: {
  rows: readonly TaxRuleVersionRow[];
  family: RuleFamily | null;
  status: RuleStatus | null;
  query: string;
  entity: string | undefined;
  canManage?: boolean;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Aturan Pajak / Konfigurasi</h1>
          <p className="list-screen-summary">{rows.length} versi aturan ditampilkan.</p>
        </div>
        {canManage ? (
          <Link
            href={entity ? `/tax/rules/new?entity=${encodeURIComponent(entity)}` : "/tax/rules/new"}
            className="btn-primary"
          >
            Aturan baru
          </Link>
        ) : null}
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Kelompok
            <select name="family" defaultValue={family ?? ""}>
              {RULE_FAMILY_FILTER_OPTIONS.map((option) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {RULE_STATUS_FILTER_OPTIONS.map((option) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari kode atau sumber…"
            aria-label="Cari aturan pajak"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada aturan pajak pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Kode</th>
              <th scope="col">Kelompok</th>
              <th scope="col">Versi</th>
              <th scope="col">Berlaku Sejak</th>
              <th scope="col">Status</th>
              <th scope="col">Sumber</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const href = entity
                ? `/tax/rules/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/tax/rules/${row.id}`;
              return (
                <tr key={row.id}>
                  <td>
                    <Link href={href}>
                      {row.code}
                      {row.is_repeal ? " (pencabutan)" : ""}
                    </Link>
                  </td>
                  <td data-label="Kelompok">{ruleFamilyLabel(row.family)}</td>
                  <td data-label="Versi">{row.rule_version}</td>
                  <td data-label="Berlaku Sejak">{formatShortDate(row.effective_from)}</td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${RULE_STATUS_TONE[row.status]}`}>
                      {RULE_STATUS_LABELS[row.status]}
                    </span>
                  </td>
                  <td data-label="Sumber">{row.source_title}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
