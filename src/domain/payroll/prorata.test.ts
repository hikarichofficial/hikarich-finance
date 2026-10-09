import { describe, expect, it } from "vitest";
import { prorataFor } from "./prorata";

const OCTOBER = { periodStart: "2026-10-01", periodEnd: "2026-10-31" };

describe("prorataFor", () => {
  it("splits the month by calendar days, counting the first day worked", () => {
    const result = prorataFor(
      { ...OCTOBER, joinDate: "2026-10-15", exitDate: null, grossPay: "8000000.0000" },
      "IDR",
    );
    // 15 to 31 October inclusive is 17 days of 31.
    expect(result?.daysWorked).toBe(17);
    expect(result?.daysInPeriod).toBe(31);
    expect(result?.proratedGross).toBe("4387096.77");
    expect(result?.label).toBe("Prorata masa kerja (17 dari 31 hari)");
  });

  it("leaves the two parts adding back up to the gross", () => {
    const result = prorataFor(
      { ...OCTOBER, joinDate: "2026-10-15", exitDate: null, grossPay: "8000000.0000" },
      "IDR",
    );
    const sum = Number(result?.proratedGross) + Number(result?.deduction);
    expect(sum).toBe(8000000);
  });

  it("counts the last day for someone who leaves mid-month", () => {
    const result = prorataFor(
      { ...OCTOBER, joinDate: "2024-01-01", exitDate: "2026-10-10", grossPay: "6200000" },
      "IDR",
    );
    expect(result?.daysWorked).toBe(10);
    expect(result?.deduction).toBe("4200000.00");
  });

  it("counts only the days inside the period when someone joins and leaves within it", () => {
    const result = prorataFor(
      { ...OCTOBER, joinDate: "2026-10-05", exitDate: "2026-10-14", grossPay: "3100000" },
      "IDR",
    );
    expect(result?.daysWorked).toBe(10);
  });

  it("gives nothing to pro-rate for a full month", () => {
    expect(
      prorataFor(
        { ...OCTOBER, joinDate: "2026-10-01", exitDate: null, grossPay: "8000000" },
        "IDR",
      ),
    ).toBeNull();
    expect(
      prorataFor(
        { ...OCTOBER, joinDate: "2020-03-01", exitDate: "2026-10-31", grossPay: "8000000" },
        "IDR",
      ),
    ).toBeNull();
  });

  it("gives nothing when there is no pay to divide or no overlap at all", () => {
    expect(
      prorataFor({ ...OCTOBER, joinDate: "2026-10-15", exitDate: null, grossPay: "0" }, "IDR"),
    ).toBeNull();
    expect(
      prorataFor(
        { ...OCTOBER, joinDate: "2026-11-02", exitDate: null, grossPay: "8000000" },
        "IDR",
      ),
    ).toBeNull();
  });

  it("follows the currency's own scale", () => {
    const result = prorataFor(
      { ...OCTOBER, joinDate: "2026-10-17", exitDate: null, grossPay: "3100.0000" },
      "USD",
    );
    expect(result?.daysWorked).toBe(15);
    expect(result?.proratedGross).toBe("1500.00");
    expect(result?.deduction).toBe("1600.00");
  });
});
