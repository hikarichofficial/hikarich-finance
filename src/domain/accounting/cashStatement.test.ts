import { describe, expect, it } from "vitest";
import {
  monthLabel,
  pageWindow,
  parseStatementMonth,
  parseStatementPage,
  parseStatementYear,
  shiftMonth,
  yearOptions,
  yearTotals,
} from "./cashStatement";

describe("cash statement helpers", () => {
  it("reads a month from the address", () => {
    expect(parseStatementMonth("2026-10")).toBe("2026-10-01");
    expect(parseStatementMonth("2026-13")).toBeNull();
    expect(parseStatementMonth("oct")).toBeNull();
    expect(parseStatementMonth(undefined)).toBeNull();
  });
  it("reads a page number, defaulting to 1", () => {
    expect(parseStatementPage("3")).toBe(3);
    expect(parseStatementPage("0")).toBe(1);
    expect(parseStatementPage("abc")).toBe(1);
    expect(parseStatementPage(undefined)).toBe(1);
  });
  it("shows every page when there are few and a window with gaps when there are many", () => {
    expect(pageWindow(1, 3)).toEqual([1, 2, 3]);
    expect(pageWindow(1, 20)).toEqual([1, 2, null, 20]);
    expect(pageWindow(10, 20)).toEqual([1, null, 9, 10, 11, null, 20]);
    expect(pageWindow(20, 20)).toEqual([1, null, 19, 20]);
  });
  it("names the month in Indonesian", () => {
    expect(monthLabel("2026-10-01")).toBe("Oktober 2026");
  });
  it("reads a year from the address, falling back to the current year", () => {
    expect(parseStatementYear("2025", 2026)).toBe(2025);
    expect(parseStatementYear("25", 2026)).toBe(2026);
    expect(parseStatementYear("1999", 2026)).toBe(2026);
    expect(parseStatementYear(undefined, 2026)).toBe(2026);
  });
  it("moves a month across year ends", () => {
    expect(shiftMonth("2026-12", 1)).toBe("2027-01");
    expect(shiftMonth("2026-01", -1)).toBe("2025-12");
    expect(shiftMonth("2026-05", 0)).toBe("2026-05");
  });
  it("offers years around the current one and always the chosen one", () => {
    expect(yearOptions(2026, 2026)[0]).toBe(2027);
    expect(yearOptions(2026, 2026).at(-1)).toBe(2021);
    expect(yearOptions(2010, 2026).at(-1)).toBe(2010);
  });
  it("totals a year from its twelve months", () => {
    const months = [
      { masuk: "1000", keluar: "0", saldo_akhir: "1000" },
      { masuk: "500", keluar: "200", saldo_akhir: "1300" },
    ];
    expect(yearTotals(months)).toEqual({ opening: 0, totalIn: 1500, totalOut: 200, closing: 1300 });
    expect(yearTotals([])).toEqual({ opening: 0, totalIn: 0, totalOut: 0, closing: 0 });
  });
});
