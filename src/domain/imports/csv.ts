import type { ImportDomain } from "@/schemas/imports";

/**
 * Reading a pasted or uploaded table for the Import Wizard (Step 15 §15: staging -> mapping -> validation
 * -> preview -> commit). Parsing and column mapping belong to the application (decision 143); the database
 * receives already-mapped rows and applies every business rule itself. Nothing here decides whether a row
 * is acceptable: an unreadable amount or date is passed through as typed so the database reports it on the
 * row.
 */

export interface ImportField {
  key: string;
  label: string;
  required: boolean;
  /** Header texts (lower case, without punctuation) that map to this field. */
  aliases: readonly string[];
  kind?: "amount" | "date" | "contact_kind" | "currency";
  example: string;
}

const CONTACT_FIELDS: readonly ImportField[] = [
  {
    key: "kind",
    label: "Jenis",
    required: true,
    aliases: ["jenis", "kind", "tipe", "type"],
    kind: "contact_kind",
    example: "pelanggan",
  },
  {
    key: "display_name",
    label: "Nama",
    required: true,
    aliases: ["nama", "name", "display name", "nama kontak"],
    example: "Toko Sumber Rejeki",
  },
  {
    key: "legal_name",
    label: "Nama Resmi",
    required: false,
    aliases: ["nama resmi", "legal name", "nama badan"],
    example: "CV Sumber Rejeki",
  },
  { key: "email", label: "Email", required: false, aliases: ["email", "e mail"], example: "" },
  {
    key: "phone",
    label: "Telepon",
    required: false,
    aliases: ["telepon", "phone", "hp", "no hp", "telp", "no telepon", "whatsapp", "wa"],
    example: "081234567890",
  },
  {
    key: "tax_identifier",
    label: "NPWP/NIK",
    required: false,
    aliases: ["npwp", "nik", "npwp nik", "tax identifier", "tax id"],
    example: "",
  },
  {
    key: "notes",
    label: "Catatan",
    required: false,
    aliases: ["catatan", "notes", "note", "keterangan"],
    example: "",
  },
];

const OPEN_ITEM_FIELDS: readonly ImportField[] = [
  {
    key: "contact_name",
    label: "Nama Kontak",
    required: true,
    aliases: ["nama kontak", "kontak", "nama", "contact name", "contact", "pelanggan", "vendor"],
    example: "Toko Sumber Rejeki",
  },
  {
    key: "amount",
    label: "Jumlah",
    required: true,
    aliases: ["jumlah", "amount", "nilai", "nominal", "sisa", "saldo"],
    kind: "amount",
    example: "1500000",
  },
  {
    key: "currency",
    label: "Mata Uang",
    required: true,
    aliases: ["mata uang", "currency", "kurs", "valuta"],
    kind: "currency",
    example: "IDR",
  },
  {
    key: "txn_date",
    label: "Tanggal",
    required: true,
    aliases: ["tanggal", "tanggal transaksi", "txn date", "date", "tgl"],
    kind: "date",
    example: "2026-08-15",
  },
  {
    key: "due_date",
    label: "Jatuh Tempo",
    required: false,
    aliases: ["jatuh tempo", "due date", "tgl jatuh tempo", "tanggal jatuh tempo"],
    kind: "date",
    example: "2026-09-15",
  },
  {
    key: "reference",
    label: "Nomor Referensi",
    required: false,
    aliases: ["nomor referensi", "referensi", "reference", "no invoice", "nomor invoice", "nomor"],
    example: "INV-0012",
  },
  {
    key: "note",
    label: "Catatan",
    required: false,
    aliases: ["catatan", "note", "notes", "keterangan"],
    example: "",
  },
];

export const IMPORT_FIELDS: Readonly<Record<ImportDomain, readonly ImportField[]>> = {
  contacts: CONTACT_FIELDS,
  legacy_open_receivables: OPEN_ITEM_FIELDS,
  legacy_open_payables: OPEN_ITEM_FIELDS,
};

/** A header line and one example line for the chosen kind of import, to copy into a spreadsheet. */
export function importTemplate(domain: ImportDomain): string {
  const fields = IMPORT_FIELDS[domain];
  return `${fields.map((f) => f.label).join(",")}\n${fields.map((f) => f.example).join(",")}\n`;
}

function detectDelimiter(firstLine: string): string {
  let best = ",";
  let bestCount = -1;
  for (const candidate of ["\t", ";", ","]) {
    const count = firstLine.split(candidate).length - 1;
    if (count > bestCount) {
      best = candidate;
      bestCount = count;
    }
  }
  return best;
}

/** Splits delimited text into rows of cells. Quoted cells may hold the delimiter, line breaks and `""`. The
 * delimiter (comma, semicolon or tab -- what spreadsheets produce on copy or CSV export) is detected from
 * the first line. Blank lines are skipped. */
export function parseDelimited(text: string): string[][] {
  const source = text.replace(/^﻿/, "").replace(/\r\n?/g, "\n");
  const delimiter = detectDelimiter(source.split("\n", 1)[0] ?? "");
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < source.length; i += 1) {
    const ch = source[i];
    if (quoted) {
      if (ch === '"') {
        if (source[i + 1] === '"') {
          cell += '"';
          i += 1;
        } else {
          quoted = false;
        }
      } else {
        cell += ch;
      }
    } else if (ch === '"' && cell === "") {
      quoted = true;
    } else if (ch === delimiter) {
      row.push(cell);
      cell = "";
    } else if (ch === "\n") {
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else {
      cell += ch;
    }
  }
  row.push(cell);
  rows.push(row);
  return rows
    .map((cells) => cells.map((value) => value.trim()))
    .filter((cells) => cells.some((value) => value !== ""));
}

function normaliseHeader(header: string): string {
  return header
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** "Rp 1.500.000,50", "1,500,000.50" and "1500000,5" all become "1500000.50"-style text; anything else is
 * returned as typed for the database to refuse on the row. */
export function normaliseAmount(value: string): string {
  const text = value.replace(/rp\.?/i, "").replace(/\s+/g, "");
  if (/^-?\d{1,3}(\.\d{3})+(,\d+)?$/.test(text)) return text.replace(/\./g, "").replace(",", ".");
  if (/^-?\d{1,3}(,\d{3})+(\.\d+)?$/.test(text)) return text.replace(/,/g, "");
  if (/^-?\d+,\d+$/.test(text)) return text.replace(",", ".");
  return text;
}

/** `15/08/2026`, `15-08-2026` and `15.08.2026` (day first, as written in Indonesia) become `2026-08-15`. */
export function normaliseDate(value: string): string {
  const match = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$/.exec(value.trim());
  if (!match) return value.trim();
  return `${match[3]}-${match[2].padStart(2, "0")}-${match[1].padStart(2, "0")}`;
}

const CONTACT_KINDS: Readonly<Record<string, string>> = {
  pelanggan: "customer",
  customer: "customer",
  pembeli: "customer",
  vendor: "vendor",
  pemasok: "vendor",
  supplier: "vendor",
  keduanya: "both",
  both: "both",
};

function normaliseCell(field: ImportField, value: string): string {
  if (value === "") return value;
  switch (field.kind) {
    case "amount":
      return normaliseAmount(value);
    case "date":
      return normaliseDate(value);
    case "currency":
      return value.toUpperCase();
    case "contact_kind":
      return CONTACT_KINDS[value.toLowerCase()] ?? value;
    default:
      return value;
  }
}

export interface MappedImport {
  /** Source header -> target field key, for the columns that were recognised. */
  mapping: Record<string, string>;
  /** Headers that match no field; their values are not imported. */
  unknownHeaders: string[];
  /** Required fields with no column. */
  missingFields: ImportField[];
  rows: Record<string, string>[];
}

/** Maps a parsed table (first row = headers) to the fields of the chosen import. */
export function mapImportTable(domain: ImportDomain, table: readonly string[][]): MappedImport {
  const fields = IMPORT_FIELDS[domain];
  const headers = table[0] ?? [];
  const columns: (ImportField | null)[] = [];
  const mapping: Record<string, string> = {};
  const unknownHeaders: string[] = [];
  const used = new Set<string>();
  for (const header of headers) {
    const wanted = normaliseHeader(header);
    const field =
      fields.find(
        (f) =>
          !used.has(f.key) &&
          (f.key.replace(/_/g, " ") === wanted ||
            normaliseHeader(f.label) === wanted ||
            f.aliases.includes(wanted)),
      ) ?? null;
    columns.push(field);
    if (field) {
      used.add(field.key);
      mapping[header] = field.key;
    } else if (header !== "") {
      unknownHeaders.push(header);
    }
  }
  const rows = table.slice(1).map((cells) => {
    const row: Record<string, string> = {};
    columns.forEach((field, index) => {
      if (field) row[field.key] = normaliseCell(field, cells[index] ?? "");
    });
    return row;
  });
  return {
    mapping,
    unknownHeaders,
    missingFields: fields.filter((f) => f.required && !used.has(f.key)),
    rows,
  };
}
