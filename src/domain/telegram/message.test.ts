import { describe, expect, it } from "vitest";
import { classifyIntent, looksLikeLoanPayment, matchAccount, parseExpenseText } from "./message";

const TODAY = "2026-10-21";
const parse = (t: string) => parseExpenseText(t, TODAY);

describe("parseExpenseText", () => {
  it("reads one line with payee and account", () => {
    expect(parse("makan siang di warteg 35rb pakai gopay")).toMatchObject({
      total: 35_000,
      payee: "Warteg",
      accountWords: ["gopay"],
      lines: [{ description: "Makan siang di warteg", amount: 35_000 }],
    });
  });
  it("splits several items and reads the date", () => {
    const r = parse("kemarin beli kopi 25rb dan roti 15rb");
    expect(r?.date).toBe("2026-10-20");
    expect(r?.lines.map((l) => [l.description, l.amount])).toEqual([
      ["Kopi", 25_000],
      ["Roti", 15_000],
    ]);
  });
  it("applies quantity and keeps a leading lower-case brand", () => {
    expect(parse("2x25rb parkir")?.lines[0]).toMatchObject({ amount: 50_000, quantity: 2 });
    expect(parse("beli iPhone 15 untuk usaha 15jt")?.lines[0]?.description).toBe(
      "iPhone 15 untuk usaha",
    );
  });
  it("reads which Entity was named", () => {
    expect(parse("beli iPhone untuk usaha 15jt")?.entityWord).toBe("company");
    expect(parse("bayar hosting 350.000 pribadi")?.entityWord).toBe("personal");
    expect(parse("kopi 20rb")?.entityWord).toBeNull();
  });
  it("splits on new lines", () => {
    expect(parse("bensin 50k\nparkir 5k")?.total).toBe(55_000);
  });
  it("returns null without an amount", () => {
    expect(parse("halo bot")).toBeNull();
  });
});

describe("classifyIntent", () => {
  it("separates commands, undo, reports, help and records", () => {
    expect(classifyIntent("/start ABC")).toEqual({ kind: "command", name: "start", arg: "ABC" });
    expect(classifyIntent("/hariini@bot")).toMatchObject({ kind: "command", name: "hariini" });
    expect(classifyIntent("batalkan yang tadi").kind).toBe("undo");
    expect(classifyIntent("pengeluaran hari ini berapa?").kind).toBe("report");
    expect(classifyIntent("rekap minggu ini").kind).toBe("report");
    expect(classifyIntent("bantuan").kind).toBe("help");
    expect(classifyIntent("kopi 20rb").kind).toBe("record");
    expect(classifyIntent("halo").kind).toBe("chat");
  });
});

describe("matchAccount", () => {
  const accounts = [
    { id: "1", name: "Kas Tunai" },
    { id: "2", name: "GoPay" },
    { id: "3", name: "BCA Operasional" },
  ];
  it("matches by the words used", () => {
    expect(matchAccount(["gopay"], accounts)?.id).toBe("2");
    expect(matchAccount(["tunai"], accounts)?.id).toBe("1");
    expect(matchAccount(["bca"], accounts)?.id).toBe("3");
  });
  it("does not guess when nothing or two fit", () => {
    expect(matchAccount([], accounts)).toBeNull();
    expect(matchAccount(["dana"], accounts)).toBeNull();
  });
});

describe("looksLikeLoanPayment", () => {
  it("spots instalments but not ordinary spending", () => {
    expect(looksLikeLoanPayment("bayar cicilan motor 1,2jt")).toBe(true);
    expect(looksLikeLoanPayment("angsuran KPR 3jt")).toBe(true);
    expect(looksLikeLoanPayment("makan siang 35rb")).toBe(false);
  });
});
