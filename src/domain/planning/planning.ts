/**
 * Recurring rules and budgets/revenue targets (P10, Step 01 #22/#23/#26, Step 15 Phase 10). The database is
 * the only authority for generation, idempotency and the computed Budget/Actual/Committed/Target/Actual/AR
 * figures; this module holds labels and a pure date preview so a screen can show "next occurrence" without
 * a round trip, using the exact same stepping as `app_private.recurring_next_date`. Nothing here is stored.
 */

export type RecurringKind = "invoice" | "bill" | "expense";
export type RecurringStatus = "active" | "paused" | "ended";
export type RecurringFrequency = "weekly" | "monthly" | "custom_days";
export type RecurringOccurrenceStatus = "generated" | "failed";
export type PlanPeriodType = "annual" | "monthly" | "custom";
export type PlanStatus = "draft" | "active" | "closed";

export const RECURRING_KIND_LABELS: Readonly<Record<RecurringKind, string>> = {
  invoice: "Faktur berulang (pendapatan)",
  bill: "Tagihan berulang (pembelian)",
  expense: "Pengeluaran berulang",
};

export const RECURRING_STATUS_LABELS: Readonly<Record<RecurringStatus, string>> = {
  active: "Aktif",
  paused: "Dijeda",
  ended: "Berakhir",
};

export const RECURRING_FREQUENCY_LABELS: Readonly<Record<RecurringFrequency, string>> = {
  weekly: "Mingguan",
  monthly: "Bulanan",
  custom_days: "Interval hari kustom",
};

export const RECURRING_OCCURRENCE_STATUS_LABELS: Readonly<Record<RecurringOccurrenceStatus, string>> = {
  generated: "Berhasil dibuat",
  failed: "Gagal",
};

export const PLAN_PERIOD_TYPE_LABELS: Readonly<Record<PlanPeriodType, string>> = {
  annual: "Tahunan",
  monthly: "Bulanan",
  custom: "Kustom",
};

export const PLAN_STATUS_LABELS: Readonly<Record<PlanStatus, string>> = {
  draft: "Draf",
  active: "Aktif",
  closed: "Ditutup",
};

/** Whether a rule may currently be edited, paused, resumed or ended, for disabling screen actions before a
 * command round-trip. The database re-checks every one of these itself; this is presentation only. */
export function recurringRuleActions(status: RecurringStatus): {
  canEdit: boolean;
  canPause: boolean;
  canResume: boolean;
  canEnd: boolean;
} {
  return {
    canEdit: status !== "ended",
    canPause: status === "active",
    canResume: status === "paused",
    canEnd: status !== "ended",
  };
}

/**
 * Preview of the next occurrence date after `from`, for a screen to show before the rule is saved or a
 * generation runs. Mirrors `app_private.recurring_next_date` exactly: monthly stepping preserves the
 * day-of-month and clamps to the target month's last day (31 Jan + 1 month lands on 28/29 Feb) rather than
 * letting `Date` arithmetic roll into the following month. The database's own computation is authoritative;
 * this exists only so a form can say "next: ..." without a round trip.
 */
export function previewNextOccurrenceDate(
  from: string,
  frequency: RecurringFrequency,
  intervalCount: number,
): string {
  const [y, m, d] = from.split("-").map(Number);
  if (frequency === "weekly") {
    return addDays(y, m, d, 7 * intervalCount);
  }
  if (frequency === "custom_days") {
    return addDays(y, m, d, intervalCount);
  }
  // monthly
  const totalMonths = (y * 12 + (m - 1)) + intervalCount;
  const targetYear = Math.floor(totalMonths / 12);
  const targetMonth = (totalMonths % 12) + 1;
  const lastDay = daysInMonth(targetYear, targetMonth);
  const day = Math.min(d, lastDay);
  return formatDate(targetYear, targetMonth, day);
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

function addDays(year: number, month: number, day: number, days: number): string {
  const base = new Date(Date.UTC(year, month - 1, day));
  base.setUTCDate(base.getUTCDate() + days);
  return formatDate(base.getUTCFullYear(), base.getUTCMonth() + 1, base.getUTCDate());
}

function formatDate(year: number, month: number, day: number): string {
  return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}
