import { describe, expect, it } from "vitest";
import { resolveTaxCalendarRange } from "./taxCalendarList";

describe("resolveTaxCalendarRange", () => {
  const reference = new Date("2026-09-23T12:00:00Z");

  it("uses a valid from/to pair as given", () => {
    expect(resolveTaxCalendarRange("2026-07-01", "2026-10-01", reference)).toEqual({
      from: "2026-07-01",
      to: "2026-10-01",
    });
  });

  it("falls back to one month back through two months ahead when from/to are absent", () => {
    expect(resolveTaxCalendarRange(undefined, undefined, reference)).toEqual({
      from: "2026-08-01",
      to: "2026-11-01",
    });
  });

  it("falls back when the pair is inverted (from after to)", () => {
    expect(resolveTaxCalendarRange("2026-10-01", "2026-07-01", reference)).toEqual({
      from: "2026-08-01",
      to: "2026-11-01",
    });
  });

  it("falls back when either date is malformed", () => {
    expect(resolveTaxCalendarRange("not-a-date", "2026-10-01", reference)).toEqual({
      from: "2026-08-01",
      to: "2026-11-01",
    });
  });

  it("crosses a year boundary correctly", () => {
    const dec = new Date("2026-12-10T00:00:00Z");
    expect(resolveTaxCalendarRange(undefined, undefined, dec)).toEqual({
      from: "2026-11-01",
      to: "2027-02-01",
    });
  });
});
