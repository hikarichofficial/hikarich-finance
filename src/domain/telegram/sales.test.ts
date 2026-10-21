import { describe, expect, it } from "vitest";
import {
  beginVerification,
  newOp,
  parseOpArg,
  parseSalesIntent,
  readChoice,
  readDupAnswer,
  renderOp,
  summaryOf,
} from "./sales";

describe("reading a sales sentence", () => {
  it("reads an invoice: customer, amount, item, entity and due days", () => {
    const i = parseSalesIntent("invoice Budi Santoso 2,5jt jasa konsultasi PT tempo 14 hari");
    expect(i).toEqual({
      kind: "invoice",
      customer: "Budi Santoso",
      amount: 2_500_000,
      description: "jasa konsultasi",
      dueDays: 14,
      entityWord: "company",
    });
  });
  it("accepts the polite and English openings and 'untuk'", () => {
    const a = parseSalesIntent("tolong buatkan invoice untuk CV Maju 10jt cetak brosur");
    expect(a?.kind === "invoice" && a.customer).toBe("CV Maju");
    const b = parseSalesIntent("create invoice for Acme 1jt design");
    expect(b?.kind === "invoice" && b.amount).toBe(1_000_000);
  });
  it("an invoice without an amount is still understood (the bot asks)", () => {
    const i = parseSalesIntent("invoice Budi jasa desain");
    expect(i?.kind === "invoice" && i.amount).toBeNull();
  });
  it("reads a payment by invoice number, with or without an amount and account", () => {
    const p = parseSalesIntent("terima HKD-2026-0001 1jt bca");
    expect(p).toMatchObject({ kind: "payment", number: "HKD-2026-0001", amount: 1_000_000 });
    expect(p?.kind === "payment" && p.accountWords).toContain("bca");
    const q = parseSalesIntent("lunas HKD-2026-0001");
    expect(q).toMatchObject({ kind: "payment", number: "HKD-2026-0001", amount: null });
  });
  it("reads a status question before a payment", () => {
    expect(parseSalesIntent("status HKD-2026-0001")).toEqual({
      kind: "status",
      number: "HKD-2026-0001",
    });
    expect(parseSalesIntent("link pembayaran HKD-2026-0001")).toEqual({
      kind: "status",
      number: "HKD-2026-0001",
    });
  });
  it("reads a new customer with email and phone", () => {
    const c = parseSalesIntent("pelanggan baru budi santoso budi@example.com 0812 3456 7890 pt");
    expect(c).toEqual({
      kind: "customer",
      name: "Budi Santoso",
      email: "budi@example.com",
      phone: "0812 3456 7890",
      entityWord: "company",
    });
  });
  it("leaves ordinary expenses and chatter alone", () => {
    expect(parseSalesIntent("makan siang 35rb pakai gopay")).toBeNull();
    expect(parseSalesIntent("terima kasih ya")).toBeNull();
    expect(parseSalesIntent("traktir pelanggan 200rb")).toBeNull();
    expect(parseSalesIntent("tagihan listrik 500rb")).toBeNull();
    expect(parseSalesIntent("/invoice")).toBeNull();
  });
});

describe("typed answers", () => {
  it("reads the duplicate question", () => {
    expect(readDupAnswer("buat baru", 1)).toEqual({ kind: "new" });
    expect(readDupAnswer("pakai yang lama", 1)).toEqual({ kind: "use", index: 0 });
    expect(readDupAnswer("pakai yang lama", 2)).toEqual({ kind: "unclear" });
    expect(readDupAnswer("2", 2)).toEqual({ kind: "use", index: 1 });
    expect(readDupAnswer("5", 2)).toEqual({ kind: "unclear" });
    expect(readDupAnswer("hmm", 1)).toEqual({ kind: "unclear" });
  });
  it("reads a single choice by number or label", () => {
    expect(readChoice("2", ["PT Hikarich", "Pribadi"])).toBe(1);
    expect(readChoice("pribadi", ["PT Hikarich", "Pribadi"])).toBe(1);
    expect(readChoice("bca", ["BCA Operasional", "Kas Kecil"])).toBe(0);
    expect(readChoice("apa", ["BCA", "BNI"])).toBeNull();
  });
  it("splits a button argument", () => {
    expect(parseOpArg("abc123:2")).toEqual({ nonce: "abc123", value: "2" });
    expect(parseOpArg("abc123")).toEqual({ nonce: "abc123", value: "" });
  });
});

describe("what the bot shows", () => {
  const base = () => {
    const op = newOp({
      kind: "invoice",
      nonce: "abc123",
      key: "tg-key",
      lang: "id",
      today: "2026-10-21",
      entities: [{ id: "pt", name: "PT Hikarich", type: "company" }],
    });
    return {
      ...op,
      entityId: "pt",
      entityName: "PT Hikarich",
      customerName: "Budi Santoso",
      description: "Jasa konsultasi",
      amount: 2_500_000,
      dueDays: 14,
    };
  };
  it("summarises an invoice with the due date and says a customer is new", () => {
    const text = summaryOf(base());
    expect(text).toContain("Invoice baru");
    expect(text).toContain("Rp 2.500.000");
    expect(text).toContain("pelanggan baru");
    expect(text).toContain("4 Nov 2026");
  });
  it("starts the verification with the summary and the first step", () => {
    const op = beginVerification(base());
    const view = renderOp(op);
    expect(view.text).toContain("Verifikasi 1/3");
    expect(view.keyboard.rows[0]?.map((b) => b.data)).toContain("o|go|abc123");
  });
  it("keeps every button within Telegram's 64-byte limit", () => {
    const op = {
      ...base(),
      phase: "dup" as const,
      candidates: Array.from({ length: 8 }, (_, i) => ({
        id: `c${i}`,
        name: "Nama Pelanggan yang Sangat Panjang Sekali Untuk Diuji",
        email: null,
        severity: "same_name" as const,
      })),
    };
    for (const row of renderOp(op).keyboard.rows)
      for (const b of row) expect(new TextEncoder().encode(b.data).length).toBeLessThanOrEqual(64);
  });
});
