import { describe, expect, it } from "vitest";
import { addDays, addMonths, endOfMonth, isoWeekday, parseDateHint, startOfWeek } from "./dates";

const TODAY = "2026-10-21"; // Wednesday
const date = (text: string) => parseDateHint(text, TODAY)?.date ?? null;

describe("calendar helpers", () => {
  it("counts weeks from Monday", () => {
    expect(isoWeekday(TODAY)).toBe(3);
    expect(startOfWeek(TODAY)).toBe("2026-10-19");
    expect(startOfWeek("2026-10-25")).toBe("2026-10-19");
  });
  it("does month arithmetic", () => {
    expect(endOfMonth("2026-02-10")).toBe("2026-02-28");
    expect(addMonths("2026-01-15", -1)).toBe("2025-12-01");
    expect(addDays("2026-03-01", -1)).toBe("2026-02-28");
  });
});

describe("parseDateHint", () => {
  it("understands relative words", () => {
    expect(date("kemarin beli kopi")).toBe("2026-10-20");
    expect(date("kemarin lusa")).toBe("2026-10-19");
    expect(date("3 hari lalu")).toBe("2026-10-18");
    expect(date("tadi pagi")).toBe(TODAY);
  });
  it("understands day and month", () => {
    expect(date("tgl 20")).toBe("2026-10-20");
    expect(date("tgl 28")).toBe("2026-09-28");
    expect(date("20 okt")).toBe("2026-10-20");
    expect(date("20 okt 2025")).toBe("2025-10-20");
    expect(date("25/12")).toBe("2025-12-25");
  });
  it("understands weekdays and never returns the future", () => {
    expect(date("senin lalu")).toBe("2026-10-19");
    expect(date("rabu lalu")).toBe("2026-10-14");
    expect(date("bayar besok")).toBeNull();
    expect(date("30/02")).toBeNull();
  });
});
