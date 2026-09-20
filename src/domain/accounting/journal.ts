import { Decimal, DecimalError, sumDecimals } from "@/domain/money/decimal";
import { convertAmount, currencyScale } from "@/domain/money/currency";

/**
 * Pure pre-checks for a journal before it is sent to the database. The database re-validates everything
 * (balance, periods, accounts, immutability, idempotency) inside the posting transaction; these helpers
 * only give the person an early, readable answer and never replace that authority (Step 04 §2, §15).
 */

export interface JournalLineDraft {
  debit?: string;
  credit?: string;
  original_currency?: string;
  original_amount?: string;
  exchange_rate?: string;
}

export interface JournalTotals {
  debit: Decimal;
  credit: Decimal;
  balanced: boolean;
  difference: Decimal;
}

function amountOf(text: string | undefined): Decimal {
  return text === undefined || text === "" ? Decimal.zero() : Decimal.parse(text);
}

export function journalTotals(lines: readonly JournalLineDraft[]): JournalTotals {
  const debit = sumDecimals(lines.map((l) => amountOf(l.debit)));
  const credit = sumDecimals(lines.map((l) => amountOf(l.credit)));
  return { debit, credit, balanced: debit.eq(credit), difference: debit.sub(credit) };
}

export type JournalProblem =
  | "too_few_lines"
  | "line_needs_one_side"
  | "too_many_decimals"
  | "foreign_amount_incomplete"
  | "foreign_amount_mismatch"
  | "not_balanced";

export interface JournalIssue {
  problem: JournalProblem;
  /** 1-based line number, absent for whole-journal problems. */
  line?: number;
}

/** Lists everything wrong with a journal, in a stable order. An empty list means "safe to send". */
export function journalIssues(
  lines: readonly JournalLineDraft[],
  baseCurrency: string,
): JournalIssue[] {
  const issues: JournalIssue[] = [];
  const scale = currencyScale(baseCurrency);
  if (lines.length < 2) issues.push({ problem: "too_few_lines" });

  lines.forEach((line, index) => {
    const number = index + 1;
    let debit: Decimal;
    let credit: Decimal;
    try {
      debit = amountOf(line.debit);
      credit = amountOf(line.credit);
    } catch (error) {
      if (error instanceof DecimalError) {
        issues.push({ problem: "line_needs_one_side", line: number });
        return;
      }
      throw error;
    }
    if (debit.isNegative() || credit.isNegative() || debit.isPositive() === credit.isPositive()) {
      issues.push({ problem: "line_needs_one_side", line: number });
      return;
    }
    if (!debit.fitsScale(scale) || !credit.fitsScale(scale)) {
      issues.push({ problem: "too_many_decimals", line: number });
    }

    const fields = [line.original_currency, line.original_amount, line.exchange_rate];
    const present = fields.filter((f) => f !== undefined && f !== "").length;
    if (present === 0) return;
    if (present !== 3) {
      issues.push({ problem: "foreign_amount_incomplete", line: number });
      return;
    }
    try {
      const converted = convertAmount(
        Decimal.parse(line.original_amount as string),
        Decimal.parse(line.exchange_rate as string),
        baseCurrency,
      );
      if (!converted.eq(debit.add(credit))) {
        issues.push({ problem: "foreign_amount_mismatch", line: number });
      }
    } catch (error) {
      if (!(error instanceof DecimalError)) throw error;
      issues.push({ problem: "foreign_amount_incomplete", line: number });
    }
  });

  try {
    if (!journalTotals(lines).balanced) issues.push({ problem: "not_balanced" });
  } catch (error) {
    if (!(error instanceof DecimalError)) throw error;
  }
  return issues;
}

/** Indonesian copy for the person filling in the journal. */
export function journalIssueMessage(issue: JournalIssue): string {
  const where = issue.line ? `Baris ${issue.line}: ` : "";
  switch (issue.problem) {
    case "too_few_lines":
      return "Jurnal memerlukan minimal dua baris.";
    case "line_needs_one_side":
      return `${where}isi tepat satu sisi (debit atau kredit) dengan angka lebih dari nol.`;
    case "too_many_decimals":
      return `${where}jumlah desimal melebihi ketentuan mata uang dasar.`;
    case "foreign_amount_incomplete":
      return `${where}mata uang asal, jumlah asal, dan kurs harus diisi bersamaan.`;
    case "foreign_amount_mismatch":
      return `${where}jumlah dasar tidak sama dengan jumlah asal × kurs.`;
    case "not_balanced":
      return "Total debit dan kredit belum seimbang.";
  }
}
