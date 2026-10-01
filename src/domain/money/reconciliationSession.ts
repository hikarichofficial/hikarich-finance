import type { ReconciliationSessionStatus, ReconciliationStatusRow } from "@/schemas/money";

/**
 * Reconciliation session workspace (Step 09 §13, decision 251). The P4 RPCs own every rule (matching must
 * add up exactly, a difference needs an accepted reason, a completed session is reopened before it changes);
 * these helpers only label, decide which actions to offer, and turn pasted statement text into lines.
 */

export const RECON_SESSION_STATUS_LABELS: Readonly<Record<ReconciliationSessionStatus, string>> = {
  open: "Sedang dikerjakan",
  reconciled: "Selesai",
  reopened: "Dibuka kembali",
};

export const RECON_SESSION_STATUS_TONES: Readonly<
  Record<ReconciliationSessionStatus, "progress" | "success" | "attention">
> = {
  open: "progress",
  reconciled: "success",
  reopened: "attention",
};

export const WORKSPACE_STATUS_LABELS = {
  matched: "Cocok",
  possible_match: "Ada kandidat",
  unmatched: "Belum cocok",
  excluded: "Dikecualikan",
} as const;

export const WORKSPACE_STATUS_TONES = {
  matched: "success",
  possible_match: "progress",
  unmatched: "attention",
  excluded: "neutral",
} as const;

export interface SessionActions {
  work: boolean;
  complete: boolean;
  discard: boolean;
  reopen: boolean;
}

/** Work (add lines, match, exclude) and complete/discard while open or reopened; reopen once completed. */
export function reconciliationSessionActions(
  status: ReconciliationSessionStatus,
  canReconcile: boolean,
): SessionActions {
  if (!canReconcile) return { work: false, complete: false, discard: false, reopen: false };
  const working = status === "open" || status === "reopened";
  return { work: working, complete: working, discard: working, reopen: status === "reconciled" };
}

function addDays(isoDate: string, days: number): string {
  const d = new Date(`${isoDate}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Defaults for a new session: it starts the day after the last reconciled period and opens with the last
 * statement's closing balance (the database requires that continuity); otherwise the first of `today`'s
 * month and an empty opening balance. */
export function newSessionDefaults(
  status: Pick<ReconciliationStatusRow, "last_reconciled_until" | "last_statement_closing"> | null,
  today: string,
): { periodStart: string; periodEnd: string; opening: string } {
  const periodStart = status?.last_reconciled_until
    ? addDays(status.last_reconciled_until, 1)
    : `${today.slice(0, 7)}-01`;
  return {
    periodStart,
    periodEnd: today >= periodStart ? today : periodStart,
    opening: status?.last_statement_closing ?? "",
  };
}

export interface ParsedStatementLine {
  date: string;
  amount: string;
  description?: string;
  reference?: string;
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const AMOUNT_RE = /^-?\d+(\.\d{1,4})?$/;

/** Parses pasted statement rows, one per line: `YYYY-MM-DD;amount;description;reference` (semicolon or tab
 * separated; description and reference optional). Amounts are signed (money in positive, money out
 * negative) with a dot as the decimal separator. Blank lines are ignored; every bad row is reported with
 * its line number and nothing is accepted until all rows are valid. */
export function parseStatementText(
  text: string,
): { ok: true; lines: ParsedStatementLine[] } | { ok: false; errors: string[] } {
  const lines: ParsedStatementLine[] = [];
  const errors: string[] = [];
  text.split(/\r?\n/).forEach((raw, index) => {
    const row = raw.trim();
    if (!row) return;
    const parts = row.split(/\t|;/).map((p) => p.trim());
    const [date, amountRaw, description, reference] = parts;
    const amount = (amountRaw ?? "").replace(/\s/g, "");
    if (!date || !DATE_RE.test(date) || Number.isNaN(Date.parse(`${date}T00:00:00Z`))) {
      errors.push(`Baris ${index + 1}: tanggal harus berformat YYYY-MM-DD.`);
      return;
    }
    if (!AMOUNT_RE.test(amount) || /^-?0+(\.0+)?$/.test(amount)) {
      errors.push(
        `Baris ${index + 1}: jumlah harus angka bukan nol dengan titik desimal (contoh -25000.50).`,
      );
      return;
    }
    lines.push({
      date,
      amount,
      ...(description ? { description } : {}),
      ...(reference ? { reference } : {}),
    });
  });
  if (errors.length > 0) return { ok: false, errors };
  if (lines.length === 0) return { ok: false, errors: ["Tidak ada baris mutasi yang diisi."] };
  if (lines.length > 1000) return { ok: false, errors: ["Maksimal 1000 baris sekali tambah."] };
  return { ok: true, lines };
}
