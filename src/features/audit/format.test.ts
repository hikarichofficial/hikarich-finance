import { describe, expect, it } from "vitest";
import { formatAuditTimestamp } from "./format";

describe("formatAuditTimestamp", () => {
  it("shows the business time zone (WITA, UTC+8) and says so", () => {
    const text = formatAuditTimestamp("2026-10-05T17:30:15Z");
    expect(text).toMatch(/WITA$/);
    expect(text).toMatch(/6/); // 1 Oct 6 at 01:30, already the next day in WITA
    expect(text).toMatch(/01[.:]30[.:]15/);
  });
});
