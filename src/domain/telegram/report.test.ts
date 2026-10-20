import { describe, expect, it } from "vitest";
import { formatSummary, parsePeriod, periodForReport, TELEGRAM_LIMIT } from "./report";

const TODAY = "2026-10-21"; // Wednesday

describe("periodForReport", () => {
  it("covers the previous full week and month", () => {
    expect(periodForReport("weekly", TODAY)).toMatchObject({
      from: "2026-10-12",
      to: "2026-10-18",
    });
    expect(periodForReport("monthly", "2026-11-01")).toMatchObject({
      from: "2026-10-01",
      to: "2026-10-31",
    });
    expect(periodForReport("daily", TODAY)).toMatchObject({ from: TODAY, to: TODAY });
  });
});

describe("parsePeriod", () => {
  it("understands what people ask", () => {
    expect(parsePeriod("hari ini", TODAY)).toMatchObject({ from: TODAY, to: TODAY });
    expect(parsePeriod("minggu ini", TODAY)).toMatchObject({ from: "2026-10-19", to: TODAY });
    expect(parsePeriod("minggu lalu", TODAY)).toMatchObject({
      from: "2026-10-12",
      to: "2026-10-18",
    });
    expect(parsePeriod("bulan lalu", TODAY)).toMatchObject({
      from: "2026-09-01",
      to: "2026-09-30",
    });
    expect(parsePeriod("7 hari terakhir", TODAY)).toMatchObject({ from: "2026-10-15", to: TODAY });
    expect(parsePeriod("september", TODAY)).toMatchObject({ from: "2026-09-01", to: "2026-09-30" });
    expect(parsePeriod("rekap", TODAY)).toMatchObject({ from: "2026-10-01", to: TODAY });
  });
});

describe("formatSummary", () => {
  const data = {
    entityName: "PT Hikarich",
    entityType: "company",
    from: TODAY,
    to: TODAY,
    total: 85_000,
    count: 2,
    byCategory: [
      { name: "Makan", total: 60_000, count: 1 },
      { name: "Transport", total: 25_000, count: 1 },
    ],
    top: [],
    entries: [{ date: TODAY, description: "Kopi <x>", amount: 60_000, account: "GoPay" }],
    drafts: 1,
    assetsToRegister: 2,
  };
  it("shows totals, comparison, categories and warnings, and escapes HTML", () => {
    const text = formatSummary("daily", periodForReport("daily", TODAY), data, 40_000);
    expect(text).toContain("Rp 85.000");
    expect(text).toContain("naik Rp 45.000");
    expect(text).toContain("Makan");
    expect(text).toContain("Kopi &lt;x&gt;");
    expect(text).toContain("1 draf");
    expect(text).toContain("2 pembelian menunggu");
  });
  it("says so when there is nothing", () => {
    const text = formatSummary(
      "ask",
      parsePeriod("hari ini", TODAY),
      { ...data, count: 0, total: 0, byCategory: [], entries: [] },
      null,
    );
    expect(text).toContain("Tidak ada pengeluaran");
  });
  it("stays under Telegram's limit", () => {
    const many = Array.from({ length: 200 }, (_, i) => ({
      name: `Kategori ${"x".repeat(60)} ${i}`,
      total: 1000,
      count: 1,
    }));
    const entries = Array.from({ length: 40 }, (_, i) => ({
      date: TODAY,
      description: "y".repeat(190) + i,
      amount: 1000,
      account: "z".repeat(50),
    }));
    expect(
      formatSummary(
        "daily",
        periodForReport("daily", TODAY),
        { ...data, byCategory: many, entries, count: 40 },
        0,
      ).length,
    ).toBeLessThanOrEqual(TELEGRAM_LIMIT);
  });
});
