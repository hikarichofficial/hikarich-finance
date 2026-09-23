import { BILL_STATUS_LABELS, SETTLEMENT_LABELS } from "@/domain/purchases/settlement";

/**
 * Pure helpers for the Bills List and Bill Detail screens (P13 Part 3b, Step 09 §9-§10, §12). Nothing here
 * calls the database. Unlike Sales, no single RPC lists every bill regardless of status (`list_bill_positions`
 * only ever returns `approved`/`void` rows), so `src/services/purchases/purchases.ts`'s `listBillsOverview`
 * merges that RPC with a direct, RLS-governed read of draft/submitted/cancelled bills (DECISIONS, P13 Part
 * 3b) into one `BillListRow` shape; filtering and the status badge are computed here, client-side, over the
 * merged list rather than by a server-side filter parameter that does not exist for this merged shape.
 */

export type BillListTone = "neutral" | "progress" | "attention" | "success" | "critical";

export interface BillListStatus {
  text: string;
  tone: BillListTone;
}

export interface BillListRow {
  bill_id: string;
  bill_number: string | null;
  vendor_id: string;
  vendor_name: string;
  currency: string;
  status: "draft" | "submitted" | "approved" | "cancelled" | "void";
  bill_date: string;
  due_date: string;
  total: string;
  outstanding: string | null;
  settlement_status: "unpaid" | "partial" | "paid" | null;
  is_overdue: boolean;
  days_overdue: number;
}

/** The list/detail status badge (Step 09 §12: vendor, due date, outstanding, approval and payment state). */
export function billListStatus(row: BillListRow): BillListStatus {
  if (row.status === "draft") return { text: BILL_STATUS_LABELS.draft, tone: "neutral" };
  if (row.status === "submitted") return { text: BILL_STATUS_LABELS.submitted, tone: "attention" };
  if (row.status === "cancelled" || row.status === "void") {
    return { text: BILL_STATUS_LABELS[row.status], tone: "neutral" };
  }
  if (row.settlement_status === "paid") return { text: SETTLEMENT_LABELS.paid, tone: "success" };
  if (row.is_overdue) return { text: `Jatuh tempo ${row.days_overdue} hari`, tone: "critical" };
  if (row.settlement_status === "partial") {
    return { text: SETTLEMENT_LABELS.partial, tone: "progress" };
  }
  return {
    text: SETTLEMENT_LABELS[row.settlement_status ?? "unpaid"],
    tone: "neutral",
  };
}

export type BillListFilter = "pending_approval" | "open" | "overdue" | "paid" | "closed";

export interface BillFilterOption {
  value: BillListFilter | null;
  label: string;
}

/** Toolbar filter tabs, computed client-side over the merged list (see file header). */
export const BILL_FILTER_OPTIONS: readonly BillFilterOption[] = [
  { value: null, label: "Semua" },
  { value: "pending_approval", label: "Menunggu Persetujuan" },
  { value: "open", label: "Terbuka" },
  { value: "overdue", label: "Jatuh Tempo" },
  { value: "paid", label: "Lunas" },
  { value: "closed", label: "Dibatalkan" },
];

export function matchesBillFilter(row: BillListRow, filter: BillListFilter | null): boolean {
  switch (filter) {
    case null:
      return true;
    case "pending_approval":
      return row.status === "draft" || row.status === "submitted";
    case "open":
      return row.status === "approved" && row.settlement_status !== "paid";
    case "overdue":
      return row.is_overdue;
    case "paid":
      return row.settlement_status === "paid";
    case "closed":
      return row.status === "cancelled" || row.status === "void";
  }
}

export function parseBillFilter(value: string | undefined): BillListFilter | undefined {
  const option = BILL_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

export function matchesBillQuery(row: BillListRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    normalize(row.vendor_name).includes(needle) ||
    (row.bill_number !== null && normalize(row.bill_number).includes(needle))
  );
}

export function filterBillRows(
  rows: readonly BillListRow[],
  filter: BillListFilter | null,
  query: string,
): BillListRow[] {
  return rows.filter((row) => matchesBillFilter(row, filter) && matchesBillQuery(row, query));
}

export interface BillActivityEntry {
  label: string;
  date: string | null;
  tone: BillListTone;
}

/**
 * Bill Detail's Activity area (Step 09 §10), built from the bill row's own workflow timestamps
 * (`submitted_at`, `rejected_at`/`reject_reason`, `approved_at`, `closed_at`/`closed_reason`) -- the direct
 * read already carries these (see `billRowSchema`), so nothing is fabricated. Vendor payments, when any,
 * are appended by the caller (`src/services/purchases/purchases.ts`'s `getBillDetail`) since they come from
 * a separate RPC (`list_vendor_payments`); this function only orders what it is given.
 */
export function billActivityTimeline(bill: {
  status: BillListRow["status"];
  submitted_at: string | null;
  rejected_at: string | null;
  reject_reason: string | null;
  approved_at: string | null;
  closed_at: string | null;
  closed_reason: string | null;
}): BillActivityEntry[] {
  const entries: BillActivityEntry[] = [{ label: "Draf dibuat", date: null, tone: "neutral" }];
  if (bill.submitted_at) {
    entries.push({
      label: "Diajukan untuk persetujuan",
      date: bill.submitted_at,
      tone: "attention",
    });
  }
  if (bill.rejected_at) {
    entries.push({
      label: bill.reject_reason ? `Ditolak: ${bill.reject_reason}` : "Ditolak",
      date: bill.rejected_at,
      tone: "critical",
    });
  }
  if (bill.approved_at) {
    entries.push({
      label: "Disetujui",
      date: bill.approved_at,
      tone: "success",
    });
  }
  if (bill.closed_at) {
    const label =
      bill.status === "void"
        ? "Dibatalkan (void)"
        : bill.status === "cancelled"
          ? "Dibatalkan"
          : "Ditutup";
    entries.push({
      label: bill.closed_reason ? `${label}: ${bill.closed_reason}` : label,
      date: bill.closed_at,
      tone: "neutral",
    });
  }
  return entries;
}
