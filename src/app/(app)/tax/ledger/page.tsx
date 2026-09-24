import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, listTaxLedger } from "@/services/tax/tax";
import {
  filterTaxLedgerRows,
  parseTaxFamilyFilter,
  parseTaxSourceFilter,
  parseTaxStatusFilter,
  taxLedgerPeriodOptions,
} from "@/domain/tax/taxLedgerList";
import { TaxLedgerScreen } from "@/features/tax/TaxLedgerScreen";

const LEDGER_FETCH_LIMIT = 1000;

/** Tax Ledger (P13 Part 3e, Step 09 §15). `?type=` filters by `tax_type` (the spec's "tax family"), `?source=`
 * by `source_type`, `?status=` by `determination_status`, `?period=` by `tax_period` -- an absent or unknown
 * value shows every entry, matching every other List screen's own null-filter meaning. */
export default async function TaxLedgerPage({
  searchParams,
}: {
  searchParams: Promise<{
    entity?: string;
    type?: string;
    source?: string;
    status?: string;
    period?: string;
    q?: string;
  }>;
}) {
  const { entity, type, source, status, period, q } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });
  const taxType = parseTaxFamilyFilter(type) ?? null;
  const sourceType = parseTaxSourceFilter(source) ?? null;
  const determinationStatus = parseTaxStatusFilter(status) ?? null;
  const taxPeriod = period ?? null;
  const query = q ?? "";

  const [entries, currency] = await Promise.all([
    listTaxLedger({ entity_id: membership.entity_id, limit: LEDGER_FETCH_LIMIT }),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const rows = filterTaxLedgerRows(
    entries,
    taxType,
    sourceType,
    determinationStatus,
    taxPeriod,
    query,
  );
  const periodOptions = taxLedgerPeriodOptions(entries);

  return (
    <TaxLedgerScreen
      rows={rows}
      periodOptions={periodOptions}
      taxType={taxType}
      sourceType={sourceType}
      status={determinationStatus}
      period={taxPeriod}
      query={query}
      currency={currency}
      entity={entity}
    />
  );
}
