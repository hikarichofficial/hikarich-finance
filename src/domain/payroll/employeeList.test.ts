import { describe, expect, it } from "vitest";
import {
  EMPLOYEE_STATUS_FILTER_OPTIONS,
  EMPLOYMENT_TYPE_FILTER_OPTIONS,
  employeeStatusBadge,
  filterEmployeeRows,
  matchesEmployeeQuery,
  matchesEmployeeStatus,
  matchesEmploymentType,
  parseEmployeeStatusFilter,
  parseEmploymentTypeFilter,
} from "./employeeList";
import type { EmployeeRow } from "@/schemas/payroll";

function row(overrides: Partial<EmployeeRow> = {}): EmployeeRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    employee_code: "EMP-0001",
    full_name: "Siti Aminah",
    status: "active",
    join_date: "2024-01-15",
    exit_date: null,
    employment_type: "permanent",
    position_title: "Akuntan",
    department: "Keuangan",
    ...overrides,
  };
}

describe("employeeStatusBadge", () => {
  it("gives active a success tone and ended a neutral tone", () => {
    expect(employeeStatusBadge("active")).toEqual({ text: "Aktif", tone: "success" });
    expect(employeeStatusBadge("ended")).toEqual({ text: "Berhenti", tone: "neutral" });
  });
});

describe("EMPLOYEE_STATUS_FILTER_OPTIONS / parseEmployeeStatusFilter", () => {
  it("has an 'all' option followed by every status", () => {
    expect(EMPLOYEE_STATUS_FILTER_OPTIONS[0]).toEqual({ value: null, label: "Semua Status" });
    expect(EMPLOYEE_STATUS_FILTER_OPTIONS).toHaveLength(3);
  });

  it("parses a known value and rejects an unknown one", () => {
    expect(parseEmployeeStatusFilter("active")).toBe("active");
    expect(parseEmployeeStatusFilter("bogus")).toBeUndefined();
    expect(parseEmployeeStatusFilter(undefined)).toBeUndefined();
  });
});

describe("matchesEmployeeStatus", () => {
  it("matches everything when the filter is null, otherwise only the exact status", () => {
    const active = row({ status: "active" });
    const ended = row({ status: "ended" });
    expect(matchesEmployeeStatus(active, null)).toBe(true);
    expect(matchesEmployeeStatus(active, "active")).toBe(true);
    expect(matchesEmployeeStatus(ended, "active")).toBe(false);
  });
});

describe("EMPLOYMENT_TYPE_FILTER_OPTIONS / parseEmploymentTypeFilter", () => {
  it("has an 'all' option followed by every employment type", () => {
    expect(EMPLOYMENT_TYPE_FILTER_OPTIONS[0]).toEqual({ value: null, label: "Semua Jenis" });
    expect(EMPLOYMENT_TYPE_FILTER_OPTIONS).toHaveLength(5);
  });

  it("parses a known value and rejects an unknown one", () => {
    expect(parseEmploymentTypeFilter("contract")).toBe("contract");
    expect(parseEmploymentTypeFilter("bogus")).toBeUndefined();
  });
});

describe("matchesEmploymentType", () => {
  it("matches everything when the filter is null, otherwise only the exact type", () => {
    const permanent = row({ employment_type: "permanent" });
    expect(matchesEmploymentType(permanent, null)).toBe(true);
    expect(matchesEmploymentType(permanent, "permanent")).toBe(true);
    expect(matchesEmploymentType(permanent, "contract")).toBe(false);
  });
});

describe("matchesEmployeeQuery", () => {
  it("matches on code, name, position or department, case-insensitively", () => {
    const r = row({
      employee_code: "EMP-0042",
      full_name: "Budi Santoso",
      position_title: "Manajer Pajak",
      department: "Pajak",
    });
    expect(matchesEmployeeQuery(r, "")).toBe(true);
    expect(matchesEmployeeQuery(r, "emp-0042")).toBe(true);
    expect(matchesEmployeeQuery(r, "budi")).toBe(true);
    expect(matchesEmployeeQuery(r, "manajer")).toBe(true);
    expect(matchesEmployeeQuery(r, "pajak")).toBe(true);
    expect(matchesEmployeeQuery(r, "tidak ada")).toBe(false);
  });

  it("does not throw when department is null", () => {
    const r = row({ department: null });
    expect(matchesEmployeeQuery(r, "keuangan")).toBe(false);
  });
});

describe("filterEmployeeRows", () => {
  it("combines status, employment type and query filters", () => {
    const rows: EmployeeRow[] = [
      row({ id: "1", status: "active", employment_type: "permanent", full_name: "Siti" }),
      row({ id: "2", status: "ended", employment_type: "permanent", full_name: "Budi" }),
      row({ id: "3", status: "active", employment_type: "contract", full_name: "Ani" }),
    ];
    expect(filterEmployeeRows(rows, "active", null, "").map((r) => r.id)).toEqual(["1", "3"]);
    expect(filterEmployeeRows(rows, null, "permanent", "").map((r) => r.id)).toEqual(["1", "2"]);
    expect(filterEmployeeRows(rows, "active", "contract", "").map((r) => r.id)).toEqual(["3"]);
    expect(filterEmployeeRows(rows, null, null, "budi").map((r) => r.id)).toEqual(["2"]);
  });
});
