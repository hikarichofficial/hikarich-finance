import { Decimal, sumDecimals } from "@/domain/money/decimal";
import type { LedgerAccountRow } from "@/schemas/accounting";

/**
 * Pure helpers for the Opening Balances screen (Step 15 §24, decision 245). `post_opening_balances` (P3)
 * accepts only balance-sheet accounts, books any debit/credit difference to the OPENING_BALANCE_CLEARING
 * account itself, and rejects that clearing account as a user line. These helpers only preview the same
 * rules for the form; the database decides.
 */

export const OPENING_ACCOUNT_CLASSES: ReadonlySet<string> = new Set([
  "asset",
  "contra_asset",
  "liability",
  "equity",
]);

/** Accounts a person may put an opening balance on: active, postable (not a group), balance-sheet, and not
 * the clearing account the workflow maintains itself. */
export function openingEligibleAccounts(accounts: readonly LedgerAccountRow[]): LedgerAccountRow[] {
  return accounts.filter(
    (a) =>
      a.status === "active" &&
      !a.is_group &&
      OPENING_ACCOUNT_CLASSES.has(a.account_class) &&
      a.system_key !== "OPENING_BALANCE_CLEARING",
  );
}

export interface OpeningAccountOption {
  account: LedgerAccountRow;
  /** Short note shown after the account name. */
  hint: string | null;
  /** Cannot be chosen here (foreign-currency cash/bank accounts need an original amount and a rate). */
  disabled: boolean;
}

/**
 * The opening-balance account choices with the traps removed (finding #91): the default cash/bank accounts
 * that no real cash/bank account is linked to are left out (posting there changes the books without creating
 * a cash movement), real cash/bank accounts are labelled, and foreign-currency ones are shown but disabled
 * because this grid has no original-amount and rate columns.
 */
export function openingAccountOptions(
  accounts: readonly LedgerAccountRow[],
  links: readonly { ledger_account_id: string; name: string; currency: string }[],
  baseCurrency: string,
): OpeningAccountOption[] {
  const eligible = openingEligibleAccounts(accounts);
  const linkByLedger = new Map(links.map((l) => [l.ledger_account_id, l]));
  const cashGroupIds = new Set(accounts.filter((a) => a.code === "1100").map((a) => a.id));
  const options: OpeningAccountOption[] = [];
  for (const account of eligible) {
    const link = linkByLedger.get(account.id);
    if (link) {
      const foreign = link.currency !== baseCurrency;
      options.push({
        account,
        hint: foreign
          ? `rekening ${link.currency}, isi lewat Penyesuaian Lanjutan`
          : "rekening kas/bank",
        disabled: foreign,
      });
      continue;
    }
    if (account.parent_id !== null && cashGroupIds.has(account.parent_id)) continue;
    options.push({ account, hint: null, disabled: false });
  }
  return options;
}

export interface OpeningLineDraft {
  key: string;
  account_id: string;
  debit: string;
  credit: string;
  description: string;
}

const AMOUNT = /^\d{1,16}(\.\d{1,4})?$/;

export interface OpeningLinesCheck {
  lines: { account_id: string; debit?: string; credit?: string; description?: string }[];
  problems: string[];
  totalDebit: string;
  totalCredit: string;
  /** Debit minus credit: what the database will post to the clearing account (as the opposite side). */
  difference: string;
}

/** Turns the form rows into RPC lines. A row with no account and no amounts is ignored; every other row
 * must name an account and carry exactly one positive amount. */
export function checkOpeningLines(rows: readonly OpeningLineDraft[]): OpeningLinesCheck {
  const problems: string[] = [];
  const lines: OpeningLinesCheck["lines"] = [];
  rows.forEach((row, index) => {
    const debit = row.debit.trim();
    const credit = row.credit.trim();
    if (!row.account_id && !debit && !credit) return;
    const n = index + 1;
    if (!row.account_id) problems.push(`Baris ${n}: pilih akun.`);
    for (const [label, value] of [
      ["Debit", debit],
      ["Kredit", credit],
    ] as const) {
      if (value && !AMOUNT.test(value))
        problems.push(`Baris ${n}: ${label} harus angka (maks. 4 desimal).`);
    }
    const hasDebit = AMOUNT.test(debit) && !Decimal.parse(debit).isZero();
    const hasCredit = AMOUNT.test(credit) && !Decimal.parse(credit).isZero();
    if (hasDebit === hasCredit) problems.push(`Baris ${n}: isi tepat satu dari Debit atau Kredit.`);
    lines.push({
      account_id: row.account_id,
      ...(hasDebit ? { debit } : {}),
      ...(hasCredit ? { credit } : {}),
      ...(row.description.trim() ? { description: row.description.trim() } : {}),
    });
  });
  if (lines.length === 0) problems.push("Isi minimal satu baris saldo awal.");
  const totalDebit = sumDecimals(lines.map((l) => Decimal.parse(l.debit ?? "0")));
  const totalCredit = sumDecimals(lines.map((l) => Decimal.parse(l.credit ?? "0")));
  return {
    lines,
    problems,
    totalDebit: totalDebit.toFixed(4),
    totalCredit: totalCredit.toFixed(4),
    difference: totalDebit.sub(totalCredit).toFixed(4),
  };
}
