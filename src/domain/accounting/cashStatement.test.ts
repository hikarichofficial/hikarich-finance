import { describe, expect, it } from "vitest";
import { monthLabel, pageWindow, parseStatementMonth, parseStatementPage } from "./cashStatement";

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
});
