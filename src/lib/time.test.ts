import { describe, expect, it } from "vitest";
import { dateInTimeZone, todayInBusinessZone } from "./time";

describe("business-zone dates", () => {
  it("is already the next day in WITA when UTC is still the previous evening", () => {
    const at = new Date("2026-10-05T17:30:00Z"); // 01:30 WITA on 6 Oct
    expect(todayInBusinessZone(at)).toBe("2026-10-06");
    expect(at.toISOString().slice(0, 10)).toBe("2026-10-05");
  });
  it("matches UTC during the WITA daytime", () => {
    expect(todayInBusinessZone(new Date("2026-10-05T04:00:00Z"))).toBe("2026-10-05");
  });
  it("honours another zone", () => {
    expect(dateInTimeZone(new Date("2026-10-05T17:30:00Z"), "UTC")).toBe("2026-10-05");
  });
});
