import { describe, expect, it } from "vitest";
import {
  filterTransferRows,
  matchesTransferFilter,
  matchesTransferQuery,
  mergeTransferRows,
  parseTransferFilter,
  transferActivityTimeline,
  transferListStatus,
  type TransferListRow,
} from "./transferList";
import type { MoneyControlRow, TransferRow } from "@/schemas/money";

function account(overrides: Partial<MoneyControlRow> = {}): MoneyControlRow {
  return {
    financial_account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    name: "Bank BCA",
    kind: "bank",
    currency: "IDR",
    is_active: true,
    movement_balance: "1000000",
    movement_base_balance: "1000000",
    ledger_balance: "1000000",
    difference: "0",
    is_negative: false,
    ...overrides,
  };
}

function transfer(overrides: Partial<TransferRow> = {}): TransferRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    entity_id: "22222222-2222-2222-2222-222222222222",
    transfer_number: "TRF-2026-0001",
    status: "draft",
    transfer_date: "2026-09-01",
    from_account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    to_account_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    amount_out: "500000",
    amount_in: "500000",
    fee_amount: "0",
    rate_out: null,
    rate_in: null,
    base_out: "500000",
    base_in: "500000",
    base_fee: "0",
    fx_difference: "0",
    description: null,
    reference: null,
    journal_id: null,
    reversal_journal_id: null,
    confirmed_at: null,
    cancelled_at: null,
    reversed_at: null,
    reverse_reason: null,
    created_at: "2026-09-01T00:00:00Z",
    ...overrides,
  };
}

function row(overrides: Partial<TransferListRow> = {}): TransferListRow {
  return {
    ...transfer(),
    from_account_name: "Bank BCA",
    from_account_currency: "IDR",
    to_account_name: "Kas Kecil",
    to_account_currency: "IDR",
    ...overrides,
  };
}

describe("mergeTransferRows", () => {
  it("resolves account names purely by joining against the given money_control rows", () => {
    const merged = mergeTransferRows(
      [transfer({ from_account_id: "a", to_account_id: "b" })],
      [
        account({ financial_account_id: "a", name: "Bank Mandiri" }),
        account({ financial_account_id: "b", name: "Kas Kecil" }),
      ],
    );
    expect(merged[0].from_account_name).toBe("Bank Mandiri");
    expect(merged[0].to_account_name).toBe("Kas Kecil");
  });

  it("falls back to a generic label and default currency for an account not in the given list", () => {
    const merged = mergeTransferRows(
      [transfer({ from_account_id: "missing" })],
      [],
    );
    expect(merged[0].from_account_name).toBe("Akun tidak dikenal");
    expect(merged[0].from_account_currency).toBe("IDR");
  });

  it("resolves each side's own currency, not just its name", () => {
    const merged = mergeTransferRows(
      [transfer({ from_account_id: "a", to_account_id: "b" })],
      [
        account({ financial_account_id: "a", currency: "USD" }),
        account({ financial_account_id: "b", currency: "IDR" }),
      ],
    );
    expect(merged[0].from_account_currency).toBe("USD");
    expect(merged[0].to_account_currency).toBe("IDR");
  });
});

describe("transferListStatus", () => {
  it("labels draft as attention (menunggu konfirmasi)", () => {
    expect(transferListStatus(transfer({ status: "draft" }))).toEqual({
      text: "Menunggu Konfirmasi",
      tone: "attention",
    });
  });

  it("labels confirmed as success", () => {
    expect(transferListStatus(transfer({ status: "confirmed" }))).toEqual({
      text: "Terkonfirmasi",
      tone: "success",
    });
  });

  it("labels cancelled and reversed as neutral", () => {
    expect(transferListStatus(transfer({ status: "cancelled" })).tone).toBe(
      "neutral",
    );
    expect(transferListStatus(transfer({ status: "reversed" })).tone).toBe(
      "neutral",
    );
  });
});

describe("matchesTransferFilter / filterTransferRows", () => {
  const rows = [
    row({ id: "a", status: "draft" }),
    row({ id: "b", status: "confirmed" }),
    row({ id: "c", status: "cancelled" }),
    row({ id: "d", status: "reversed" }),
  ];

  it("null filter matches everything", () => {
    expect(rows.filter((r) => matchesTransferFilter(r, null))).toHaveLength(
      rows.length,
    );
  });

  it("a specific filter matches only that status", () => {
    expect(
      rows
        .filter((r) => matchesTransferFilter(r, "confirmed"))
        .map((r) => r.id),
    ).toEqual(["b"]);
  });

  it("filterTransferRows combines filter and query", () => {
    const withNames = [
      row({
        id: "x",
        from_account_name: "Bank Mandiri",
        to_account_name: "Bank BNI",
        status: "draft",
      }),
      row({
        id: "y",
        from_account_name: "Bank BCA",
        to_account_name: "Kas Kecil",
        status: "confirmed",
      }),
    ];
    expect(filterTransferRows(withNames, "draft", "")).toEqual([withNames[0]]);
    expect(filterTransferRows(withNames, null, "kas kecil")).toEqual([
      withNames[1],
    ]);
  });
});

describe("parseTransferFilter", () => {
  it("accepts a known value and rejects unknown/absent ones", () => {
    expect(parseTransferFilter("confirmed")).toBe("confirmed");
    expect(parseTransferFilter("bogus")).toBeUndefined();
    expect(parseTransferFilter(undefined)).toBeUndefined();
  });
});

describe("matchesTransferQuery", () => {
  it("matches the transfer number, either account name, description or reference", () => {
    expect(
      matchesTransferQuery(row({ transfer_number: "TRF-2026-0099" }), "0099"),
    ).toBe(true);
    expect(
      matchesTransferQuery(
        row({ from_account_name: "Bank Mandiri" }),
        "mandiri",
      ),
    ).toBe(true);
    expect(
      matchesTransferQuery(row({ to_account_name: "Kas Kecil" }), "kecil"),
    ).toBe(true);
    expect(
      matchesTransferQuery(row({ description: "Setor tunai" }), "setor"),
    ).toBe(true);
    expect(matchesTransferQuery(row({ reference: "REF-001" }), "ref-001")).toBe(
      true,
    );
    expect(matchesTransferQuery(row(), "tidak-ada")).toBe(false);
  });

  it("a null transfer_number never matches (draft transfers have none yet)", () => {
    expect(matchesTransferQuery(row({ transfer_number: null }), "trf")).toBe(
      false,
    );
  });
});

describe("transferActivityTimeline", () => {
  it("always starts with a draft-created entry using created_at", () => {
    expect(transferActivityTimeline(transfer())).toEqual([
      { label: "Draf dibuat", date: "2026-09-01T00:00:00Z", tone: "neutral" },
    ]);
  });

  it("appends confirmed, cancelled and reversed entries in that order when present", () => {
    const timeline = transferActivityTimeline(
      transfer({
        status: "reversed",
        confirmed_at: "2026-09-02T00:00:00Z",
        reversed_at: "2026-09-10T00:00:00Z",
        reverse_reason: "Salah akun tujuan",
      }),
    );
    expect(timeline.map((e) => e.label)).toEqual([
      "Draf dibuat",
      "Dikonfirmasi",
      "Dibalik: Salah akun tujuan",
    ]);
  });

  it("labels a cancelled draft distinctly, with no reversal entry", () => {
    const timeline = transferActivityTimeline(
      transfer({ status: "cancelled", cancelled_at: "2026-09-03T00:00:00Z" }),
    );
    expect(timeline.at(-1)).toEqual({
      label: "Dibatalkan",
      date: "2026-09-03T00:00:00Z",
      tone: "neutral",
    });
  });
});
