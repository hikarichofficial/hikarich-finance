import { describe, expect, it } from "vitest";
import { journalIssueMessage, journalIssues, journalTotals } from "./journal";
import {
  createJournalInputSchema,
  journalLineInputSchema,
  moneyTextSchema,
  trialBalanceSchema,
  periodChecksSchema,
} from "@/schemas/accounting";

const ENTITY = "11111111-1111-4111-8111-111111111111";
const ACCOUNT = "22222222-2222-4222-8222-222222222222";

describe("journal pre-checks", () => {
  it("totals are exact and detect imbalance to the last unit", () => {
    const ok = journalTotals([{ debit: "0.1" }, { debit: "0.2" }, { credit: "0.30" }]);
    expect(ok.balanced).toBe(true);
    expect(ok.difference.isZero()).toBe(true);
    const off = journalTotals([{ debit: "100.00" }, { credit: "99.99" }]);
    expect(off.balanced).toBe(false);
    expect(off.difference.toString()).toBe("0.01");
  });

  it("returns no issues for a clean IDR journal", () => {
    expect(journalIssues([{ debit: "1500000" }, { credit: "1500000.00" }], "IDR")).toEqual([]);
  });

  it("reports each problem with its line", () => {
    const issues = journalIssues(
      [{ debit: "10.001" }, { debit: "5", credit: "5" }, { credit: "1", original_currency: "USD" }],
      "IDR",
    );
    expect(issues).toContainEqual({ problem: "too_many_decimals", line: 1 });
    expect(issues).toContainEqual({ problem: "line_needs_one_side", line: 2 });
    expect(issues).toContainEqual({ problem: "foreign_amount_incomplete", line: 3 });
    expect(issues).toContainEqual({ problem: "not_balanced" });
    expect(journalIssues([{ debit: "1" }], "IDR")).toContainEqual({ problem: "too_few_lines" });
  });

  it("checks original amount x rate against the base amount", () => {
    const line = {
      debit: "160005.50",
      original_currency: "USD",
      original_amount: "10",
      exchange_rate: "16000.55",
    };
    expect(journalIssues([line, { credit: "160005.50" }], "IDR")).toEqual([]);
    expect(
      journalIssues([{ ...line, debit: "160005" }, { credit: "160005" }], "IDR"),
    ).toContainEqual({
      problem: "foreign_amount_mismatch",
      line: 1,
    });
  });

  it("treats malformed amounts as a line problem instead of throwing", () => {
    expect(journalIssues([{ debit: "abc" }, { credit: "1" }], "IDR")).toContainEqual({
      problem: "line_needs_one_side",
      line: 1,
    });
  });

  it("has user-facing copy for every problem", () => {
    for (const problem of [
      "too_few_lines",
      "line_needs_one_side",
      "too_many_decimals",
      "foreign_amount_incomplete",
      "foreign_amount_mismatch",
      "not_balanced",
    ] as const) {
      expect(journalIssueMessage({ problem, line: 2 }).length).toBeGreaterThan(10);
    }
  });
});

describe("accounting schemas", () => {
  const valid = {
    entity_id: ENTITY,
    idempotency_key: "key-0001-abcdef",
    entry_type: "manual" as const,
    entry_date: "2026-09-12",
    description: "Reklasifikasi biaya",
    lines: [
      { account_key: "OFFICE_GENERAL_EXPENSE", debit: "250000" },
      { account_id: ACCOUNT, credit: "250000.00" },
    ],
  };

  it("accepts a balanced manual journal", () => {
    expect(createJournalInputSchema.safeParse(valid).success).toBe(true);
  });

  it("rejects unbalanced, one-line, and both-sided journals", () => {
    expect(
      createJournalInputSchema.safeParse({
        ...valid,
        lines: [valid.lines[0], { ...valid.lines[1], credit: "1" }],
      }).success,
    ).toBe(false);
    expect(createJournalInputSchema.safeParse({ ...valid, lines: [valid.lines[0]] }).success).toBe(
      false,
    );
    expect(
      journalLineInputSchema.safeParse({ account_key: "CASH", debit: "1", credit: "1" }).success,
    ).toBe(false);
    expect(journalLineInputSchema.safeParse({ account_key: "CASH", debit: "0" }).success).toBe(
      false,
    );
  });

  it("requires exactly one account reference per line", () => {
    expect(journalLineInputSchema.safeParse({ debit: "1" }).success).toBe(false);
    expect(
      journalLineInputSchema.safeParse({ account_id: ACCOUNT, account_key: "CASH", debit: "1" })
        .success,
    ).toBe(false);
  });

  it("does not throw on malformed amounts; it reports them", () => {
    const result = createJournalInputSchema.safeParse({
      ...valid,
      lines: [
        { account_key: "CASH", debit: "1e3" },
        { account_key: "CASH", credit: "abc" },
      ],
    });
    expect(result.success).toBe(false);
  });

  it("holds adjusting journals to a real explanation and validates dates and keys", () => {
    expect(
      createJournalInputSchema.safeParse({
        ...valid,
        entry_type: "adjusting",
        description: "short",
      }).success,
    ).toBe(false);
    expect(createJournalInputSchema.safeParse({ ...valid, entry_date: "2026-02-30" }).success).toBe(
      false,
    );
    expect(createJournalInputSchema.safeParse({ ...valid, entry_date: "12/09/2026" }).success).toBe(
      false,
    );
    expect(createJournalInputSchema.safeParse({ ...valid, idempotency_key: "short" }).success).toBe(
      false,
    );
    expect(createJournalInputSchema.safeParse({ ...valid, entry_type: "system" }).success).toBe(
      false,
    );
  });

  it("requires foreign-currency fields to come together", () => {
    expect(
      journalLineInputSchema.safeParse({
        account_key: "CASH",
        debit: "10",
        original_currency: "USD",
      }).success,
    ).toBe(false);
    expect(
      journalLineInputSchema.safeParse({
        account_key: "CASH",
        debit: "160005.50",
        original_currency: "USD",
        original_amount: "10",
        exchange_rate: "16000.55",
      }).success,
    ).toBe(true);
  });

  it("money is text only: numbers and floats are rejected", () => {
    expect(moneyTextSchema.safeParse("1500000.0000").success).toBe(true);
    expect(moneyTextSchema.safeParse("1.23456").success).toBe(false);
    expect(moneyTextSchema.safeParse("-1").success).toBe(false);
    expect(moneyTextSchema.safeParse(1500000 as unknown as string).success).toBe(false);
  });

  it("parses RPC results and refuses numeric JSON amounts", () => {
    expect(
      trialBalanceSchema.safeParse([
        {
          account_id: ACCOUNT,
          code: "1120",
          name: "Bank",
          account_class: "asset",
          debit: "1000.0000",
          credit: "0",
        },
      ]).success,
    ).toBe(true);
    expect(
      trialBalanceSchema.safeParse([
        {
          account_id: ACCOUNT,
          code: "1120",
          name: "Bank",
          account_class: "asset",
          debit: 1000,
          credit: 0,
        },
      ]).success,
    ).toBe(false);
    expect(
      periodChecksSchema.safeParse([
        { code: "draft_journals", severity: "blocker", message: "x", item_count: 2 },
      ]).success,
    ).toBe(true);
  });
});
