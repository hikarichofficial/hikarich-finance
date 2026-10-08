import { trimDecimalText } from "@/domain/money/format";
import { plainMoneyText } from "@/domain/money/typing";
import { splitVatInclusive } from "@/domain/tax/vatInclusive";
import type { RecurringKind } from "./planning";

/** The line rows of the bill / expense / recurring-template editors and how they become the `lines` JSON sent to the
 * database (pure; the editor component in `features/planning/RecurringLinesEditor.tsx` renders them). */

export interface RecurringLineRow {
  key: string;
  description: string;
  quantity: string;
  unit_price: string;
  category_id: string;
  treatment: "expense" | "asset" | "prepaid";
  /** Invoice lines only (a purchase has no discount, decision 78): "none", a percentage, or a fixed amount. */
  discount_type: "none" | "percent" | "fixed";
  discount_value: string;
  /** Bill/expense line: the amount typed is the receipt total INCLUDING VAT; it is split into the price before VAT
   * and the VAT when the lines are serialized (OWNER, 8 October 2026). Only for a quantity of 1. */
  price_includes_vat?: boolean;
  /** Fields of the original template line this editor does not render, kept verbatim so they survive a
   * re-save untouched. Empty for a row the person added in this session. */
  extra: Record<string, unknown>;
}

function makeRow(key: string, initial?: Partial<RecurringLineRow>): RecurringLineRow {
  return {
    key,
    description: "",
    quantity: "",
    unit_price: "",
    category_id: "",
    treatment: "expense",
    discount_type: "none",
    discount_value: "",
    extra: {},
    ...initial,
  };
}

export function newRecurringLineRow(seq: number): RecurringLineRow {
  return makeRow(`new-${seq}`);
}

const RENDERED_LINE_FIELDS = [
  "description",
  "quantity",
  "unit_price",
  "category_id",
  "treatment",
  "discount_type",
  "discount_value",
];

function extraFieldsOf(line: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(line).filter(([key]) => !RENDERED_LINE_FIELDS.includes(key)),
  );
}

/** Reads back whatever a rule's own `template.lines` (arbitrary jsonb) already carries. */
export function buildInitialRecurringLines(
  existingLines: readonly Record<string, unknown>[],
): RecurringLineRow[] {
  return existingLines.map((line, index) => {
    const extra = extraFieldsOf(line);
    return makeRow(`existing-${index}`, {
      description: typeof line.description === "string" ? line.description : "",
      quantity: line.quantity != null ? trimDecimalText(String(line.quantity)) : "",
      unit_price: line.unit_price != null ? trimDecimalText(String(line.unit_price)) : "",
      category_id: typeof line.category_id === "string" ? line.category_id : "",
      treatment:
        line.treatment === "asset" || line.treatment === "prepaid" ? line.treatment : "expense",
      discount_type:
        line.discount_type === "percent" || line.discount_type === "fixed"
          ? line.discount_type
          : "none",
      discount_value:
        line.discount_value != null && Number(line.discount_value) > 0
          ? trimDecimalText(String(line.discount_value))
          : "",
      extra,
    });
  });
}

/** A row with a blank description or amount is not saved; this is the single place that says which. */
function isSerialized(row: RecurringLineRow): boolean {
  return row.description.trim() !== "" && plainMoneyText(row.unit_price.trim()) !== "";
}

/** The keys of the rows that are sent, in order: the database's "line N" is the Nth of these. */
export function serializedRowKeys(rows: readonly RecurringLineRow[]): string[] {
  return rows.filter(isSerialized).map((row) => row.key);
}

/** Whether the "includes VAT" box applies to this row: a bill/expense line of quantity 1. */
export function canIncludeVat(row: RecurringLineRow, kind: RecurringKind): boolean {
  const quantity = row.quantity.trim().replace(",", ".");
  return kind !== "invoice" && (quantity === "" || Number(quantity) === 1);
}

export function buildRecurringLinesJson(
  rows: readonly RecurringLineRow[],
  kind: RecurringKind,
): string {
  return JSON.stringify(
    rows.flatMap((row) => {
      if (!isSerialized(row)) return [];
      const description = row.description.trim();
      let unitPrice = plainMoneyText(row.unit_price.trim());
      const extra = { ...row.extra };
      // Buying equipment / an asset (OWNER, 8 October 2026: "pembelian peralatan dan perlengkapan, tidak kena PPh"):
      // goods are not a withholding object, so the line is classified without asking.
      if (kind !== "invoice" && row.treatment === "asset" && extra.wht_object === undefined) {
        extra.wht_object = "wht_none";
      }
      if (row.price_includes_vat && canIncludeVat(row, kind)) {
        const split = splitVatInclusive(unitPrice);
        if (split) {
          unitPrice = split.net;
          extra.tax_amount = split.vat;
        }
      }
      const line: Record<string, unknown> = {
        ...extra,
        description,
        unit_price: unitPrice,
        // A decimal comma ("1,5") is accepted the way it is in the money fields.
        quantity: row.quantity.trim() === "" ? undefined : row.quantity.trim().replace(",", "."),
        category_id: row.category_id === "" ? undefined : row.category_id,
      };
      if (kind !== "invoice") {
        line.treatment = row.treatment;
      } else if (row.discount_type !== "none" && row.discount_value.trim() !== "") {
        line.discount_type = row.discount_type;
        line.discount_value = plainMoneyText(row.discount_value.trim());
      }
      return [line];
    }),
  );
}
