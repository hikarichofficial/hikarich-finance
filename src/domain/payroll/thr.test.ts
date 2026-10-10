import { describe, expect, it } from "vitest";
import { completedMonths, thrFor } from "./thr";

describe("completedMonths", () => {
  it("counts whole months and does not round up the remaining days", () => {
    expect(completedMonths("2026-03-10", "2026-08-10")).toBe(5);
    expect(completedMonths("2026-03-10", "2026-08-09")).toBe(4);
    expect(completedMonths("2026-03-10", "2026-08-31")).toBe(5);
  });

  it("spans a year boundary", () => {
    expect(completedMonths("2025-12-01", "2026-11-30")).toBe(11);
    expect(completedMonths("2025-12-01", "2026-12-01")).toBe(12);
  });

  it("is negative before the join date", () => {
    expect(completedMonths("2026-08-10", "2026-03-10")).toBe(-5);
  });
});

describe("thrFor", () => {
  it("pays one month's wage from twelve months of service", () => {
    const result = thrFor(
      { joinDate: "2024-01-01", payDate: "2026-03-20", wageBase: "7000000.0000" },
      "IDR",
    );
    expect(result?.proportional).toBe(false);
    expect(result?.amount).toBe("7000000.00");
    expect(result?.label).toBe("THR Keagamaan (1 bulan upah)");
  });

  it("pays the proportional part below twelve months", () => {
    const result = thrFor(
      { joinDate: "2025-10-01", payDate: "2026-03-20", wageBase: "7000000.0000" },
      "IDR",
    );
    // 1 October to 20 March is five completed months: 5/12 of 7,000,000.
    expect(result?.monthsOfService).toBe(5);
    expect(result?.proportional).toBe(true);
    expect(result?.amount).toBe("2916666.66");
    expect(result?.fullAmount).toBe("7000000.00");
    expect(result?.label).toBe("THR Keagamaan proporsional (5 dari 12 bulan)");
  });

  it("offers nothing below one month of service (Permenaker 6/2016 article 2)", () => {
    expect(
      thrFor({ joinDate: "2026-03-01", payDate: "2026-03-20", wageBase: "7000000" }, "IDR"),
    ).toBeNull();
  });

  it("offers nothing without a wage base", () => {
    expect(
      thrFor({ joinDate: "2024-01-01", payDate: "2026-03-20", wageBase: "0" }, "IDR"),
    ).toBeNull();
  });
});
