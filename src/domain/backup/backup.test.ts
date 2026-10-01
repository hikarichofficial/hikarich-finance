import { describe, expect, it } from "vitest";
import {
  backupReminderMessage,
  daysSinceLastBackup,
  formatByteSize,
  nonEmptyTables,
  restoreConfirmMatches,
  restoreReady,
  totalRows,
} from "./backup";

describe("formatByteSize", () => {
  it("shows plain bytes under 1024", () => {
    expect(formatByteSize(512)).toBe("512 B");
  });

  it("shows KB with one decimal under 10, none at or above", () => {
    expect(formatByteSize(2048)).toBe("2.0 KB");
    expect(formatByteSize(20480)).toBe("20 KB");
  });

  it("shows MB once past 1024 KB", () => {
    expect(formatByteSize(5 * 1024 * 1024)).toBe("5.0 MB");
  });

  it("shows GB once past 1024 MB", () => {
    expect(formatByteSize(2 * 1024 * 1024 * 1024)).toBe("2.0 GB");
  });

  it("returns a dash for negative or non-finite input, never throwing", () => {
    expect(formatByteSize(-1)).toBe("-");
    expect(formatByteSize(Number.NaN)).toBe("-");
    expect(formatByteSize(Number.POSITIVE_INFINITY)).toBe("-");
  });

  it("caps at TB rather than inventing a further unit", () => {
    expect(formatByteSize(5 * 1024 * 1024 * 1024 * 1024)).toBe("5.0 TB");
  });
});

describe("daysSinceLastBackup", () => {
  it("returns null when there is no last backup", () => {
    expect(daysSinceLastBackup(null, new Date("2026-10-01T00:00:00Z"))).toBeNull();
  });

  it("returns null for an unparseable timestamp rather than throwing", () => {
    expect(daysSinceLastBackup("not-a-date", new Date("2026-10-01T00:00:00Z"))).toBeNull();
  });

  it("counts whole days elapsed", () => {
    expect(daysSinceLastBackup("2026-09-01T00:00:00Z", new Date("2026-10-01T00:00:00Z"))).toBe(30);
  });

  it("never returns a negative count for a clock skew where 'now' precedes the backup", () => {
    expect(daysSinceLastBackup("2026-10-02T00:00:00Z", new Date("2026-10-01T00:00:00Z"))).toBe(0);
  });
});

describe("backupReminderMessage", () => {
  it("always reminds when there has never been a backup", () => {
    expect(backupReminderMessage(null)).toMatch(/Belum pernah/);
  });

  it("reminds at the 30-day threshold", () => {
    expect(backupReminderMessage(30)).toMatch(/30 hari/);
  });

  it("reminds well past the threshold", () => {
    expect(backupReminderMessage(90)).toMatch(/90 hari/);
  });

  it("stays quiet just under the threshold", () => {
    expect(backupReminderMessage(29)).toBeNull();
  });

  it("stays quiet for a fresh backup", () => {
    expect(backupReminderMessage(0)).toBeNull();
  });
});

describe("restoreConfirmMatches", () => {
  it("requires the exact Entity code", () => {
    expect(restoreConfirmMatches("HKR", "HKR")).toBe(true);
    expect(restoreConfirmMatches("  HKR ", "HKR")).toBe(true);
    expect(restoreConfirmMatches("hkr", "HKR")).toBe(false);
    expect(restoreConfirmMatches("", "HKR")).toBe(false);
  });
});

describe("totalRows / nonEmptyTables", () => {
  const counts = { contacts: 2, journal_lines: 10, products: 0, accounting_periods: 2 };

  it("sums every table", () => {
    expect(totalRows(counts)).toBe(14);
    expect(totalRows({})).toBe(0);
  });

  it("lists non-empty tables, largest first then by name", () => {
    expect(nonEmptyTables(counts)).toEqual([
      { table: "journal_lines", rows: 10 },
      { table: "accounting_periods", rows: 2 },
      { table: "contacts", rows: 2 },
    ]);
  });
});

describe("restoreReady", () => {
  it("blocks an invalid file before anything else", () => {
    expect(restoreReady({ ok: false, step_up_ok: false })).toBe("invalid");
  });

  it("asks for step-up when the file is valid but the window lapsed", () => {
    expect(restoreReady({ ok: true, step_up_ok: false })).toBe("step_up");
  });

  it("is ready when both hold", () => {
    expect(restoreReady({ ok: true, step_up_ok: true })).toBe("ready");
  });
});
