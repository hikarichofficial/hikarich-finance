import { describe, expect, it } from "vitest";
import { previewNextOccurrenceDate, recurringRuleActions } from "./planning";

describe("previewNextOccurrenceDate", () => {
  it("steps weekly by 7 * interval days", () => {
    expect(previewNextOccurrenceDate("2027-01-01", "weekly", 2)).toBe("2027-01-15");
  });

  it("steps by a custom number of days", () => {
    expect(previewNextOccurrenceDate("2027-01-01", "custom_days", 45)).toBe("2027-02-15");
  });

  it("steps monthly, preserving the day of month", () => {
    expect(previewNextOccurrenceDate("2027-01-15", "monthly", 1)).toBe("2027-02-15");
  });

  it("clamps 31 Jan + 1 month to 28 Feb in a non-leap year, never rolling into March", () => {
    expect(previewNextOccurrenceDate("2027-01-31", "monthly", 1)).toBe("2027-02-28");
  });

  it("clamps 31 Jan + 1 month to 29 Feb in a leap year", () => {
    expect(previewNextOccurrenceDate("2028-01-31", "monthly", 1)).toBe("2028-02-29");
  });

  it("steps monthly across a year boundary", () => {
    expect(previewNextOccurrenceDate("2027-12-15", "monthly", 1)).toBe("2028-01-15");
  });
});

describe("recurringRuleActions", () => {
  it("an active rule can be paused or ended but not resumed", () => {
    expect(recurringRuleActions("active")).toEqual({
      canEdit: true,
      canPause: true,
      canResume: false,
      canEnd: true,
    });
  });

  it("an ended rule can no longer be edited, paused, resumed or ended", () => {
    expect(recurringRuleActions("ended")).toEqual({
      canEdit: false,
      canPause: false,
      canResume: false,
      canEnd: false,
    });
  });
});
