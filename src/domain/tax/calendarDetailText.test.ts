import { describe, expect, it } from "vitest";
import { calendarDetailText } from "./calendarDetailText";

describe("calendarDetailText", () => {
  it("translates the fixed sentences", () => {
    expect(calendarDetailText("Compute the final tax once the month has ended", "IDR")).toMatch(
      /Hitung PPh Final/,
    );
    expect(calendarDetailText("Paid", "IDR")).toBe("Sudah dibayar.");
    expect(calendarDetailText("Nothing is recognised yet for this period", "IDR")).toMatch(
      /Belum ada/,
    );
  });

  it("puts the amount in the entity currency", () => {
    const text = calendarDetailText("150000 to pay by the deadline", "IDR");
    expect(text).toContain("150.000");
    expect(text).toContain("tenggat");
  });

  it("keeps the filing reference and formats the date", () => {
    expect(calendarDetailText("Filed 2026-10-01 (NTTE-1)", "IDR", (d) => `tgl ${d}`)).toBe(
      "Sudah dilaporkan pada tgl 2026-10-01 (NTTE-1).",
    );
  });

  it("explains the yearly return of the final tax", () => {
    expect(
      calendarDetailText(
        "To be reported in the annual income tax return (SPT Tahunan) of 2026",
        "IDR",
      ),
    ).toBe("Dilaporkan lewat SPT Tahunan PPh tahun 2026.");
    expect(calendarDetailText("Reported in the annual income tax return of 2026", "IDR")).toBe(
      "Sudah dilaporkan lewat SPT Tahunan PPh tahun 2026.",
    );
  });

  it("shows a dash for nothing and an unknown sentence as it came", () => {
    expect(calendarDetailText(null, "IDR")).toBe("—");
    expect(calendarDetailText("Something new", "IDR")).toBe("Something new");
  });
});
