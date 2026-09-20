import { describe, expect, it } from "vitest";
import {
  balanceAdjustmentInputSchema,
  createReconciliationInputSchema,
  createTransferInputSchema,
  matchStatementLineInputSchema,
  moneyControlSchema,
  statementLineInputSchema,
} from "./money";

const ID = "11111111-1111-4111-8111-111111111111";
const ID2 = "22222222-2222-4222-8222-222222222222";

describe("money contracts", () => {
  it("a transfer keeps money as text and rejects numbers", () => {
    const ok = createTransferInputSchema.safeParse({
      entity_id: ID,
      idempotency_key: "key-transfer-1",
      from_account_id: ID,
      to_account_id: ID2,
      transfer_date: "2026-09-10",
      amount_out: "1000000",
      fee: "6500.00",
    });
    expect(ok.success).toBe(true);
    const bad = createTransferInputSchema.safeParse({
      entity_id: ID,
      idempotency_key: "key-transfer-1",
      from_account_id: ID,
      to_account_id: ID2,
      transfer_date: "2026-09-10",
      amount_out: 1000000,
    });
    expect(bad.success).toBe(false);
  });

  it("refuses impossible dates and short keys", () => {
    const base = {
      entity_id: ID,
      from_account_id: ID,
      to_account_id: ID2,
      amount_out: "10",
    };
    expect(
      createTransferInputSchema.safeParse({
        ...base,
        idempotency_key: "short",
        transfer_date: "2026-09-10",
      }).success,
    ).toBe(false);
    expect(
      createTransferInputSchema.safeParse({
        ...base,
        idempotency_key: "key-transfer-2",
        transfer_date: "2026-02-30",
      }).success,
    ).toBe(false);
  });

  it("an adjustment needs a real reason", () => {
    const input = {
      entity_id: ID,
      idempotency_key: "key-adjust-001",
      account_id: ID,
      direction: "in",
      amount: "100",
      movement_date: "2026-09-30",
      counter_account_id: ID2,
    };
    expect(balanceAdjustmentInputSchema.safeParse({ ...input, reason: "too short" }).success).toBe(
      false,
    );
    expect(
      balanceAdjustmentInputSchema.safeParse({ ...input, reason: "Interest credited by the bank" })
        .success,
    ).toBe(true);
  });

  it("statement lines are signed decimal text; a session cannot end before it starts", () => {
    expect(
      statementLineInputSchema.safeParse({ date: "2026-09-03", amount: "-2500" }).success,
    ).toBe(true);
    expect(statementLineInputSchema.safeParse({ date: "2026-09-03", amount: "1e6" }).success).toBe(
      false,
    );
    const session = {
      entity_id: ID,
      idempotency_key: "key-recon-0001",
      account_id: ID2,
      statement_opening: "0",
      statement_closing: "3397500",
    };
    expect(
      createReconciliationInputSchema.safeParse({
        ...session,
        period_start: "2026-09-30",
        period_end: "2026-09-01",
      }).success,
    ).toBe(false);
    expect(
      createReconciliationInputSchema.safeParse({
        ...session,
        period_start: "2026-09-01",
        period_end: "2026-09-30",
      }).success,
    ).toBe(true);
  });

  it("a match needs distinct-looking movement ids, and a manual reason must be meaningful", () => {
    expect(matchStatementLineInputSchema.safeParse({ line_id: ID, movement_ids: [] }).success).toBe(
      false,
    );
    expect(
      matchStatementLineInputSchema.safeParse({
        line_id: ID,
        movement_ids: [ID2],
        manual_reason: "x",
      }).success,
    ).toBe(false);
    expect(
      matchStatementLineInputSchema.safeParse({ line_id: ID, movement_ids: [ID2] }).success,
    ).toBe(true);
  });

  it("the money control reader accepts the database shape", () => {
    const row = {
      financial_account_id: ID,
      name: "BCA Main",
      kind: "bank",
      currency: "IDR",
      is_active: true,
      movement_balance: "1000000.0000",
      movement_base_balance: "1000000.0000",
      ledger_balance: "1000000.0000",
      difference: "0.0000",
      is_negative: false,
    };
    expect(moneyControlSchema.safeParse([row]).success).toBe(true);
    expect(moneyControlSchema.safeParse([{ ...row, movement_balance: 1000000 }]).success).toBe(
      false,
    );
  });
});
