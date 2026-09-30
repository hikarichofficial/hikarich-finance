import type { AccountingPeriodRow } from "@/schemas/accounting";

/**
 * Pure helpers for the Accounting Periods List/Detail screens (P13, Step 09 §14: "Period Close screen
 * presents a checklist of blockers/warnings before Close"). Nothing here calls the database.
 */

export type PeriodStatusTone = "neutral" | "progress" | "attention" | "success";

export interface PeriodStatusDisplay {
  text: string;
  tone: PeriodStatusTone;
}

const PERIOD_STATUS_DISPLAY: Readonly<Record<AccountingPeriodRow["status"], PeriodStatusDisplay>> =
  {
    open: { text: "Terbuka", tone: "neutral" },
    closing_review: { text: "Tinjauan Penutupan", tone: "attention" },
    closed: { text: "Ditutup", tone: "success" },
    reopened: { text: "Dibuka Kembali", tone: "progress" },
  };

export function periodStatusDisplay(status: AccountingPeriodRow["status"]): PeriodStatusDisplay {
  return PERIOD_STATUS_DISPLAY[status];
}

export function sortPeriodsByStart(rows: readonly AccountingPeriodRow[]): AccountingPeriodRow[] {
  return [...rows].sort((a, b) => (a.period_start < b.period_start ? 1 : -1));
}
