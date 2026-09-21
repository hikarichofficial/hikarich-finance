import { describe, expect, it } from "vitest";
import {
  confirmEquityEventInputSchema,
  createEquityEventInputSchema,
  createLoanInputSchema,
  createObligationInputSchema,
  loanRowSchema,
  obligationRowSchema,
  payDividendInputSchema,
  periodInputSchema,
  recordFinancingTaxReviewInputSchema,
  repayLoanInputSchema,
  restructureLoanInputSchema,
} from "./financing";

const ENTITY = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a01";
const OTHER = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a02";
const KEY = "key-financing-0001";

describe("loans", () => {
  const base = {
    entity_id: ENTITY,
    idempotency_key: KEY,
    direction: "borrowed" as const,
    counterparty: "Bank X",
    purpose: "Modal kerja",
    principal: "12000000",
    agreement_date: "2027-01-01",
    term_class: "short" as const,
    rate_percent: "12",
    method: "annuity" as const,
    installments: 12,
    step_months: 1 as const,
    first_due: "2027-01-31",
  };

  it("a generated schedule needs its installments and a first date, not before the agreement", () => {
    expect(createLoanInputSchema.safeParse(base).success).toBe(true);
    expect(createLoanInputSchema.safeParse({ ...base, installments: undefined }).success).toBe(
      false,
    );
    expect(createLoanInputSchema.safeParse({ ...base, first_due: "2026-12-31" }).success).toBe(
      false,
    );
  });

  it("a manual schedule lists its installments", () => {
    const manual = {
      ...base,
      method: "manual" as const,
      installments: undefined,
      first_due: undefined,
    };
    expect(createLoanInputSchema.safeParse(manual).success).toBe(false);
    expect(
      createLoanInputSchema.safeParse({
        ...manual,
        items: [
          { due_date: "2027-06-30", principal: "6000000" },
          { due_date: "2027-12-31", principal: "6000000" },
        ],
      }).success,
    ).toBe(true);
  });

  it("the rate is a percentage as text; the step is 1, 3, 6 or 12 months", () => {
    expect(createLoanInputSchema.safeParse({ ...base, rate_percent: "9.75" }).success).toBe(true);
    expect(createLoanInputSchema.safeParse({ ...base, rate_percent: "12%" }).success).toBe(false);
    expect(createLoanInputSchema.safeParse({ ...base, step_months: 2 }).success).toBe(false);
  });

  it("a related Entity needs its basis (the tag is analytical only)", () => {
    expect(createLoanInputSchema.safeParse({ ...base, related_entity_id: OTHER }).success).toBe(
      false,
    );
    expect(
      createLoanInputSchema.safeParse({
        ...base,
        related_entity_id: OTHER,
        relationship_basis: "Pemegang saham",
      }).success,
    ).toBe(true);
  });

  it("a repayment defaults interest and fee to zero and keeps amounts as text", () => {
    const parsed = repayLoanInputSchema.parse({
      loan_id: ENTITY,
      idempotency_key: KEY,
      date: "2027-02-28",
      account_id: OTHER,
      principal: "946185.46",
    });
    expect(parsed.interest).toBe("0");
    expect(parsed.fee).toBe("0");
    expect(
      repayLoanInputSchema.safeParse({
        loan_id: ENTITY,
        idempotency_key: KEY,
        date: "2027-02-28",
        account_id: OTHER,
        principal: 946185.46,
      }).success,
    ).toBe(false);
  });

  it("a restructure states why", () => {
    const input = {
      loan_id: ENTITY,
      idempotency_key: KEY,
      effective_date: "2027-06-01",
      method: "annuity" as const,
      installments: 24,
      step_months: 1 as const,
      first_due: "2027-07-31",
    };
    expect(restructureLoanInputSchema.safeParse({ ...input, reason: "ok" }).success).toBe(false);
    expect(
      restructureLoanInputSchema.safeParse({
        ...input,
        reason: "Perpanjangan tenor disetujui bank",
      }).success,
    ).toBe(true);
  });

  it("reads the loan list the database returns", () => {
    const row = {
      loan_id: ENTITY,
      loan_number: "LN-2026-0001",
      direction: "borrowed",
      status: "active",
      counterparty_name: "Bank X",
      purpose: "Modal kerja",
      principal: "12000000.0000",
      outstanding: "11500000.0000",
      rate: "12.000000",
      maturity_date: "2027-12-31",
      next_due_date: "2026-09-21",
      next_due_amount: "1066185.4600",
      overdue_amount: "0.0000",
      overdue: false,
      term_class: "short",
      asset_id: null,
      related_entity_id: null,
      source_type: "proceeds",
    };
    expect(loanRowSchema.safeParse(row).success).toBe(true);
    expect(loanRowSchema.safeParse({ ...row, status: "paid_off" }).success).toBe(false);
  });
});

describe("other receivables and payables", () => {
  const base = {
    entity_id: ENTITY,
    idempotency_key: KEY,
    kind: "receivable" as const,
    counterparty: "Friendly Co",
    date: "2027-01-10",
    amount: "5000000",
    purpose: "Pinjaman singkat ke pelanggan",
  };

  it("cash needs the account that moved; an offset needs its counter account", () => {
    expect(createObligationInputSchema.safeParse({ ...base, method: "cash" }).success).toBe(false);
    expect(
      createObligationInputSchema.safeParse({ ...base, method: "cash", account_id: OTHER }).success,
    ).toBe(true);
    expect(createObligationInputSchema.safeParse({ ...base, method: "offset" }).success).toBe(
      false,
    );
    expect(
      createObligationInputSchema.safeParse({
        ...base,
        method: "offset",
        counter_account_id: OTHER,
      }).success,
    ).toBe(true);
  });

  it("the due date is not before the date", () => {
    expect(
      createObligationInputSchema.safeParse({
        ...base,
        method: "cash",
        account_id: OTHER,
        due_date: "2027-01-09",
      }).success,
    ).toBe(false);
  });

  it("an open, settled or void obligation is what the database reports", () => {
    const row = {
      obligation_id: ENTITY,
      obligation_number: "ORC-2026-0001",
      kind: "receivable",
      status: "open",
      counterparty_name: "Friendly Co",
      purpose: "x",
      obligation_date: "2027-01-10",
      due_date: null,
      principal: "5000000.0000",
      outstanding: "4000000.0000",
      overdue: false,
      source_type: "manual",
      related_entity_id: null,
      journal_id: null,
    };
    expect(obligationRowSchema.safeParse(row).success).toBe(true);
    expect(obligationRowSchema.safeParse({ ...row, status: "active" }).success).toBe(false);
  });
});

describe("equity", () => {
  const base = {
    entity_id: ENTITY,
    idempotency_key: KEY,
    kind: "dividend" as const,
    date: "2027-03-01",
    amount: "2000000",
    counterparty: "Pemegang saham",
    purpose: "Dividen interim",
  };

  it("a known kind, an exact amount", () => {
    expect(createEquityEventInputSchema.safeParse(base).success).toBe(true);
    expect(createEquityEventInputSchema.safeParse({ ...base, kind: "bonus" }).success).toBe(false);
    expect(createEquityEventInputSchema.safeParse({ ...base, amount: "2.000.000" }).success).toBe(
      false,
    );
  });

  it("confirming names an account only for cash events", () => {
    expect(
      confirmEquityEventInputSchema.safeParse({ event_id: ENTITY, idempotency_key: KEY }).success,
    ).toBe(true);
    expect(
      confirmEquityEventInputSchema.safeParse({
        event_id: ENTITY,
        idempotency_key: KEY,
        account_id: OTHER,
      }).success,
    ).toBe(true);
  });

  it("a dividend payment names the account, the date and the amount", () => {
    expect(
      payDividendInputSchema.safeParse({
        event_id: ENTITY,
        idempotency_key: KEY,
        date: "2027-03-05",
        account_id: OTHER,
        amount: "800000",
      }).success,
    ).toBe(true);
    expect(
      payDividendInputSchema.safeParse({
        event_id: ENTITY,
        idempotency_key: KEY,
        date: "2027-03-05",
        amount: "800000",
      }).success,
    ).toBe(false);
  });
});

describe("periods and tax review", () => {
  it("a period does not end before it starts", () => {
    expect(
      periodInputSchema.safeParse({ entity_id: ENTITY, from: "2027-01-01", to: "2027-01-31" })
        .success,
    ).toBe(true);
    expect(
      periodInputSchema.safeParse({ entity_id: ENTITY, from: "2027-02-01", to: "2027-01-31" })
        .success,
    ).toBe(false);
  });

  it("a tax review records what was concluded", () => {
    const input = { entity_id: ENTITY, source: "loan_payment" as const, source_id: OTHER };
    expect(recordFinancingTaxReviewInputSchema.safeParse({ ...input, note: "ok" }).success).toBe(
      false,
    );
    expect(
      recordFinancingTaxReviewInputSchema.safeParse({
        ...input,
        note: "Bunga dari bank, tidak ada pemotongan",
      }).success,
    ).toBe(true);
    expect(
      recordFinancingTaxReviewInputSchema.safeParse({
        ...input,
        source: "invoice",
        note: "Bunga dari bank, tidak ada pemotongan",
      }).success,
    ).toBe(false);
  });
});
