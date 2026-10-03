import { describe, expect, it } from "vitest";
import {
  importTemplate,
  mapImportTable,
  normaliseAmount,
  normaliseDate,
  parseDelimited,
} from "./csv";

describe("parseDelimited", () => {
  it("reads commas, quotes and embedded delimiters", () => {
    expect(parseDelimited('Nama,Catatan\n"Toko A, Cabang 2","bilang ""halo"""\n')).toEqual([
      ["Nama", "Catatan"],
      ["Toko A, Cabang 2", 'bilang "halo"'],
    ]);
  });

  it("detects semicolons and tabs, skips blank lines and the BOM", () => {
    expect(parseDelimited("﻿Nama;Jumlah\r\n\r\nA;1\r\n")).toEqual([
      ["Nama", "Jumlah"],
      ["A", "1"],
    ]);
    expect(parseDelimited("Nama\tJumlah\nA\t1")).toEqual([
      ["Nama", "Jumlah"],
      ["A", "1"],
    ]);
  });
});

describe("normalising cells", () => {
  it("reads Indonesian and English amounts", () => {
    expect(normaliseAmount("Rp 1.500.000,50")).toBe("1500000.50");
    expect(normaliseAmount("1,500,000.50")).toBe("1500000.50");
    expect(normaliseAmount("1500000,5")).toBe("1500000.5");
    expect(normaliseAmount("1500000")).toBe("1500000");
    expect(normaliseAmount("abc")).toBe("abc");
  });

  it("reads day-first dates and keeps ISO dates", () => {
    expect(normaliseDate("5/8/2026")).toBe("2026-08-05");
    expect(normaliseDate("15-08-2026")).toBe("2026-08-15");
    expect(normaliseDate("2026-08-15")).toBe("2026-08-15");
  });
});

describe("mapImportTable", () => {
  it("maps Indonesian headers and contact kinds", () => {
    const mapped = mapImportTable("contacts", [
      ["Jenis", "Nama", "No. HP", "Warna"],
      ["Pelanggan", "Toko A", "0812", "merah"],
      ["pemasok", "CV B", "", ""],
    ]);
    expect(mapped.rows).toEqual([
      { kind: "customer", display_name: "Toko A", phone: "0812" },
      { kind: "vendor", display_name: "CV B", phone: "" },
    ]);
    expect(mapped.unknownHeaders).toEqual(["Warna"]);
    expect(mapped.missingFields).toEqual([]);
  });

  it("reports required fields without a column", () => {
    const mapped = mapImportTable("legacy_open_receivables", [
      ["Kontak", "Jumlah", "Tanggal"],
      ["Toko A", "1.500.000", "15/08/2026"],
    ]);
    expect(mapped.rows[0]).toEqual({
      contact_name: "Toko A",
      amount: "1500000",
      txn_date: "2026-08-15",
    });
    expect(mapped.missingFields.map((f) => f.key)).toEqual(["currency"]);
  });

  it("the template maps back onto every field", () => {
    for (const domain of ["contacts", "legacy_open_receivables"] as const) {
      const mapped = mapImportTable(domain, parseDelimited(importTemplate(domain)));
      expect(mapped.unknownHeaders).toEqual([]);
      expect(mapped.missingFields).toEqual([]);
    }
  });
});
