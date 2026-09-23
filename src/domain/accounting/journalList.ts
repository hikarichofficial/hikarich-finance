import type {
  AccountingPeriodRow,
  JournalEntryRow,
  JournalLineRow,
  LedgerAccountRow,
} from "@/schemas/accounting";

/**
 * Pure helpers for the Journal List and Journal Detail screens (P13 Part 3d, Step 09 §9-§10, §14). Nothing
 * here calls the database: `listJournals`/`getJournalEntry`/`getJournalLines`/`getReversingJournal`
 * (`src/services/accounting/ledger.ts`) already carry everything these functions need.
 */

const PERIOD_LABEL_FORMAT = new Intl.DateTimeFormat("id-ID", {
  month: "long",
  year: "numeric",
  timeZone: "UTC",
});

/** Accounting periods are calendar months (decision 22), so the month/year of `period_start` alone identifies
 * one -- used for the Journal List's period filter and for the Period Close screen's period picker. */
export function periodLabel(period: Pick<AccountingPeriodRow, "period_start">): string {
  return PERIOD_LABEL_FORMAT.format(new Date(`${period.period_start}T00:00:00Z`));
}

export type JournalListTone = "neutral" | "attention" | "success";

export interface JournalListStatus {
  text: string;
  tone: JournalListTone;
}

/** `journal_entries.status` only ever holds `draft`/`posted` (Step 04 §11's posting engine has no separate
 * approval state yet -- decision 41 records that `accounting.journal_approve` is not wired into any RPC). */
export function journalListStatus(row: JournalEntryRow): JournalListStatus {
  return row.status === "posted"
    ? { text: "Terposting", tone: "success" }
    : { text: "Draf", tone: "attention" };
}

export const ENTRY_TYPE_LABELS: Record<JournalEntryRow["entry_type"], string> = {
  system: "Sistem",
  manual: "Manual",
  adjusting: "Penyesuaian",
  reversal: "Pembalik",
  opening: "Saldo Awal",
  closing: "Penutupan",
};

export function entryTypeLabel(entryType: JournalEntryRow["entry_type"]): string {
  return ENTRY_TYPE_LABELS[entryType];
}

/** Step 09 §14's "source filtering" -- `entry_type` is the bounded, meaningful category to filter a journal
 * feed by (system/manual/adjusting/reversal/opening/closing); `source_type`/`source_id` is a much wider,
 * open-ended vocabulary (see `journalSourceHref` below) better suited to drill-back than to a filter tab. */
export type JournalListFilter = JournalEntryRow["entry_type"];

export interface JournalFilterOption {
  value: JournalListFilter | null;
  label: string;
}

export const JOURNAL_FILTER_OPTIONS: readonly JournalFilterOption[] = [
  { value: null, label: "Semua Sumber" },
  { value: "system", label: "Sistem" },
  { value: "manual", label: "Manual" },
  { value: "adjusting", label: "Penyesuaian" },
  { value: "reversal", label: "Pembalik" },
  { value: "opening", label: "Saldo Awal" },
  { value: "closing", label: "Penutupan" },
];

export function matchesEntryType(row: JournalEntryRow, filter: JournalListFilter | null): boolean {
  return filter === null || row.entry_type === filter;
}

export function parseJournalFilter(value: string | undefined): JournalListFilter | undefined {
  const option = JOURNAL_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

export type JournalStatusFilter = "draft" | "posted";

export interface JournalStatusFilterOption {
  value: JournalStatusFilter | null;
  label: string;
}

export const JOURNAL_STATUS_FILTER_OPTIONS: readonly JournalStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  { value: "draft", label: "Draf" },
  { value: "posted", label: "Terposting" },
];

export function matchesJournalStatus(
  row: JournalEntryRow,
  status: JournalStatusFilter | null,
): boolean {
  return status === null || row.status === status;
}

export function parseJournalStatusFilter(
  value: string | undefined,
): JournalStatusFilter | undefined {
  return value === "draft" || value === "posted" ? value : undefined;
}

export function matchesPeriod(row: JournalEntryRow, periodId: string | null): boolean {
  return periodId === null || row.period_id === periodId;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

export function matchesJournalQuery(row: JournalEntryRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    (row.journal_number !== null && normalize(row.journal_number).includes(needle)) ||
    normalize(row.description).includes(needle) ||
    (row.posting_key !== null && normalize(row.posting_key).includes(needle))
  );
}

export function filterJournalRows(
  rows: readonly JournalEntryRow[],
  entryType: JournalListFilter | null,
  status: JournalStatusFilter | null,
  periodId: string | null,
  query: string,
): JournalEntryRow[] {
  return rows.filter(
    (row) =>
      matchesEntryType(row, entryType) &&
      matchesJournalStatus(row, status) &&
      matchesPeriod(row, periodId) &&
      matchesJournalQuery(row, query),
  );
}

/** "Drill-back to originating business event" (Step 09 §14): only the source types this codebase already has
 * a Detail screen for get a link -- everything else (payment, vendor_payment, expense, tax_payment,
 * asset_depreciation, loan, equity_event, payroll_run and the rest of `post_system_journal`'s wide vocabulary)
 * shows its label with no link. This is the same "only link what has somewhere to go" choice decision 169
 * made for Account Activity, now able to cover more ground because Sales/Purchases/Money Detail screens
 * exist (decisions 165/167/170). */
export function journalSourceHref(
  sourceType: string | null,
  sourceId: string | null,
  entity: string | undefined,
): string | null {
  if (sourceType === null || sourceId === null) return null;
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  switch (sourceType) {
    case "invoice":
      return `/sales/invoices/${sourceId}${qs}`;
    case "bill":
      return `/purchases/bills/${sourceId}${qs}`;
    case "transfer":
      return `/money/transfers/${sourceId}${qs}`;
    default:
      return null;
  }
}

export interface JournalActivityEntry {
  label: string;
  date: string | null;
  tone: JournalListTone;
  href: string | null;
}

/** Journal Detail's Activity area (Step 09 §10, §14): the row's own workflow timestamps, plus a two-way
 * reversal cross-link -- `reverses_journal_id` (this journal reversing an earlier one) points forward by
 * construction, and `reversingJournal` (from `getReversingJournal`, the reverse lookup) points backward. */
export function journalActivityTimeline(
  row: JournalEntryRow,
  reversingJournal: { id: string; journal_number: string | null } | null,
  entity: string | undefined,
): JournalActivityEntry[] {
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const entries: JournalActivityEntry[] = [
    { label: "Draf dibuat", date: row.created_at, tone: "neutral", href: null },
  ];
  if (row.posted_at) {
    entries.push({ label: "Diposting", date: row.posted_at, tone: "success", href: null });
  }
  if (row.reverses_journal_id) {
    entries.push({
      label: "Membalik jurnal lain",
      date: null,
      tone: "neutral",
      href: `/accounting/journal/${row.reverses_journal_id}${qs}`,
    });
  }
  if (reversingJournal) {
    entries.push({
      label: reversingJournal.journal_number
        ? `Dibalik oleh ${reversingJournal.journal_number}`
        : "Dibalik oleh jurnal lain",
      date: null,
      tone: "attention",
      href: `/accounting/journal/${reversingJournal.id}${qs}`,
    });
  }
  return entries;
}

export interface JournalLineDisplay {
  line: JournalLineRow;
  accountCode: string;
  accountName: string;
}

/** Journal Detail's debit/credit grid needs each line's account code/name, but `journal_lines` itself only
 * carries `ledger_account_id` (Step 04 §11's normalised storage) -- merges in the Entity's Chart of Accounts
 * (`listLedgerAccounts`) the same way `mergeTransferRows`/`mergeAccountRows` merge in their own lookups. A
 * line whose account cannot be found (should not happen under RLS, kept only for display safety) shows a
 * plain placeholder rather than throwing. */
export function mergeJournalLines(
  lines: readonly JournalLineRow[],
  accounts: readonly LedgerAccountRow[],
): JournalLineDisplay[] {
  const byId = new Map(accounts.map((account) => [account.id, account]));
  return lines.map((line) => {
    const account = byId.get(line.ledger_account_id);
    return {
      line,
      accountCode: account?.code ?? "—",
      accountName: account?.name ?? "Akun tidak dikenal",
    };
  });
}

export interface JournalLineTotals {
  debit: number;
  credit: number;
}

/** The grid's own footer totals (debit always equals credit for a posted journal -- Step 04 §11's balance
 * invariant -- but a discarded-mid-edit draft could momentarily not, which is exactly when showing the totals
 * is most useful). */
export function journalLineTotals(lines: readonly JournalLineRow[]): JournalLineTotals {
  return lines.reduce(
    (totals, line) => ({
      debit: totals.debit + Number(line.debit),
      credit: totals.credit + Number(line.credit),
    }),
    { debit: 0, credit: 0 },
  );
}
