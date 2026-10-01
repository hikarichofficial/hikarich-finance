import { describe, expect, it } from "vitest";
import {
  newSessionDefaults,
  parseStatementText,
  reconciliationSessionActions,
} from "./reconciliationSession";

describe("reconciliationSessionActions", () => {
  it("works, completes and discards while open or reopened", () => {
    for (const status of ["open", "reopened"] as const) {
      expect(reconciliationSessionActions(status, true)).toEqual({
        work: true,
        complete: true,
        discard: true,
        reopen: false,
      });
    }
  });

  it("only reopens a completed session", () => {
    expect(reconciliationSessionActions("reconciled", true)).toEqual({
      work: false,
      complete: false,
      discard: false,
      reopen: true,
    });
  });

  it("offers nothing without money.reconcile", () => {
    expect(Object.values(reconciliationSessionActions("open", false))).not.toContain(true);
  });
});

describe("newSessionDefaults", () => {
  it("continues from the last reconciled period and closing balance", () => {
    expect(
      newSessionDefaults(
        { last_reconciled_until: "2026-08-31", last_statement_closing: "1500000.00" },
        "2026-10-01",
      ),
    ).toEqual({ periodStart: "2026-09-01", periodEnd: "2026-10-01", opening: "1500000.00" });
  });

  it("starts at the first of the month when nothing was reconciled", () => {
    expect(newSessionDefaults(null, "2026-10-15")).toEqual({
      periodStart: "2026-10-01",
      periodEnd: "2026-10-15",
      opening: "",
    });
  });
});

describe("parseStatementText", () => {
  it("parses semicolon and tab rows, signed amounts and optional fields", () => {
    const result = parseStatementText(
      "2026-09-05;-25000;Biaya admin;ADM1\n\n2026-09-06\t1500000.50\tTransfer masuk\n",
    );
    expect(result).toEqual({
      ok: true,
      lines: [
        { date: "2026-09-05", amount: "-25000", description: "Biaya admin", reference: "ADM1" },
        { date: "2026-09-06", amount: "1500000.50", description: "Transfer masuk" },
      ],
    });
  });

  it("reports every bad row with its line number", () => {
    const result = parseStatementText("05/09/2026;100\n2026-09-05;1.234,50\n2026-09-05;0");
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors).toHaveLength(3);
      expect(result.errors[0]).toMatch(/^Baris 1/);
      expect(result.errors[1]).toMatch(/^Baris 2/);
      expect(result.errors[2]).toMatch(/^Baris 3/);
    }
  });

  it("refuses empty input", () => {
    expect(parseStatementText("  \n ").ok).toBe(false);
  });
});
