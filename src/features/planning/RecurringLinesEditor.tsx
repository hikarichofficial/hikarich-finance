"use client";

import { trimDecimalText } from "@/domain/money/format";
import { Fragment } from "react";
import type { CategoryRow } from "@/schemas/categories";
import type { RecurringKind } from "@/domain/planning/planning";
import { VAT_TREATMENT_LABELS, WHT_OBJECT_LABELS } from "@/domain/tax/tax";
import { plainMoneyText } from "@/domain/money/typing";
import { exactSuggestion, type LineSuggestion } from "@/domain/sales/lineSuggestions";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { LineDescriptionInput } from "./LineDescriptionInput";

/**
 * The recurring template's own line items (P13 Part 3h, sixth increment, Step 09 §13, §18) -- the one piece
 * decisions 186/187 explicitly deferred ("no editable multi-row grid precedent exists anywhere in this
 * codebase" until `BudgetLinesEditor` shipped in the fifth increment). Unlike Budget's category x month
 * grid, a template's lines are a plain repeating row list (no fixed columns, no per-row uniqueness) -- the
 * same shape `invoice_prepare_lines`/`purchase_prepare_lines` (P7) themselves expect, minus every optional
 * tax/discount/product-linkage field neither RPC requires (`vat_treatment`, `discount_type`, `wht_object`,
 * `tax_amount`, `product_id`, `account_id`): those stay valid, defaulted inputs at generation time -- the
 * same "no locked spec forces every field" reasoning already used to leave `forecast_amount` off the
 * Budget/Revenue Target report tables (decisions 184/185/139). `treatment` (expense vs. asset vs. prepaid)
 * is shown only for `bill`/`expense`, since only `purchase_prepare_lines` reads it; the category picker is
 * filtered by both the rule's own `kind` (invoice needs a `revenue` category) and, for bill/expense, each
 * row's own `treatment` (`expense` needs an `expense` category, `asset`/`prepaid` need an `asset` one) --
 * exactly the pairing `purchase_prepare_lines` itself validates. An existing line's own fields this editor
 * does not render (e.g. `vat_treatment`) travel with the row as `extra` rather than being dropped or
 * re-matched by array position (which would misattribute them the moment a row is added, removed or
 * reordered), so re-saving the grid never silently discards a value a future increment's own editor might
 * still need. State is owned by the parent form (`RecurringRuleForm`) and serialized into one hidden `lines`
 * JSON field on every submit, the same controlled-rows pattern `BudgetLinesEditor` established; a row with a
 * blank description or unit price is silently dropped at serialization time rather than blocking the
 * submit -- "a blank cell simply omits that line", the same choice `BudgetLinesEditor` made for an empty
 * amount cell.
 *
 * Invoice lines also show a Diskon column (OWNER, 5 October 2026: it was in the brief and was missing): none, a
 * percentage or a fixed amount, sent as the RPC's own `discount_type` / `discount_value`. The description
 * field offers names used before with their last price (`LineDescriptionInput`, `suggestions`), and every
 * amount field puts its thousands separators in by itself (`MoneyInput`).
 *
 * `taxFields` (decision 257) adds a second row under each line with the tax facts the P7 engine reads from
 * the line: for a bill/expense the VAT the vendor charged, the tax-invoice number and the withholding
 * object; for an invoice the VAT treatment. They live in `extra` under the RPC's own field names, so the
 * serializer needs no second code path; a blank value removes the key ("the engine decides, or asks").
 *
 * On a narrow screen the table becomes stacked cards (`record-table-stacked`, `globals.css`; P13 Part 5;
 * Step 09 §23), reachable and safe to stack now that decision 204's own reachability question is answered:
 * this editor is live inside `RecurringRuleForm`, reached from Recurring Rule Detail/Create. Unlike
 * `BudgetLinesEditor`/`RevenueTargetLinesEditor` -- a genuine category x month matrix whose columns grow with
 * the plan's own date range, the same period-comparison shape decision 202/207 excludes -- this editor has a
 * fixed, small column set (Deskripsi/Kuantitas/Harga Satuan/Perlakuan/Kategori/Hapus), the same plain
 * repeating-row shape as `BillDetailScreen`'s own line items (decision 207), just editable; Deskripsi stays
 * the unlabelled heading input.
 */

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

export function buildRecurringLinesJson(
  rows: readonly RecurringLineRow[],
  kind: RecurringKind,
): string {
  return JSON.stringify(
    rows.flatMap((row) => {
      const description = row.description.trim();
      const unitPrice = plainMoneyText(row.unit_price.trim());
      if (description === "" || unitPrice === "") return [];
      const line: Record<string, unknown> = {
        ...row.extra,
        description,
        unit_price: unitPrice,
        quantity: row.quantity.trim() === "" ? undefined : row.quantity.trim(),
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

function categoryKindFor(kind: RecurringKind, treatment: RecurringLineRow["treatment"]): string {
  if (kind === "invoice") return "revenue";
  return treatment === "expense" ? "expense" : "asset";
}

function extraText(row: RecurringLineRow, field: string): string {
  const value = row.extra[field];
  return typeof value === "string" ? value : "";
}

export function RecurringLinesEditor({
  kind,
  categories,
  rows,
  onChange,
  taxFields = false,
  suggestions = [],
}: {
  kind: RecurringKind;
  categories: readonly CategoryRow[];
  rows: readonly RecurringLineRow[];
  onChange: (rows: RecurringLineRow[]) => void;
  /** Show the per-line tax facts (VAT charged, tax-invoice number, withholding object / VAT treatment). */
  taxFields?: boolean;
  /** Descriptions already used before (with their last price), for the popup above the description field. */
  suggestions?: readonly LineSuggestion[];
}) {
  function addRow() {
    onChange([...rows, newRecurringLineRow(rows.length + 1)]);
  }

  function removeRow(key: string) {
    onChange(rows.filter((row) => row.key !== key));
  }

  function updateRow(key: string, patch: Partial<RecurringLineRow>) {
    onChange(rows.map((row) => (row.key === key ? { ...row, ...patch } : row)));
  }

  function updateExtra(row: RecurringLineRow, field: string, value: string) {
    const extra = { ...row.extra };
    if (value.trim() === "") delete extra[field];
    else extra[field] = value.trim();
    updateRow(row.key, { extra });
  }

  const showTreatment = kind !== "invoice";
  const showDiscount = kind === "invoice";
  const columnCount = 6;

  /** Typing a description that is exactly one used before fills in its price (and category) when those are
   * still empty; the person can change both straight away. */
  function changeDescription(row: RecurringLineRow, description: string, rowCategoryIds: string[]) {
    const patch: Partial<RecurringLineRow> = { description };
    const known = exactSuggestion(description, suggestions);
    if (known) {
      if (row.unit_price.trim() === "" && known.unit_price !== "") {
        patch.unit_price = trimDecimalText(known.unit_price);
      }
      if (
        row.category_id === "" &&
        known.category_id &&
        rowCategoryIds.includes(known.category_id)
      ) {
        patch.category_id = known.category_id;
      }
    }
    updateRow(row.key, patch);
  }

  /** Choosing a suggestion is an explicit act: the description and its last price are taken, the category
   * only if the line has none yet. */
  function pickSuggestion(
    row: RecurringLineRow,
    suggestion: LineSuggestion,
    rowCategoryIds: string[],
  ) {
    updateRow(row.key, {
      description: suggestion.description,
      unit_price:
        suggestion.unit_price !== "" ? trimDecimalText(suggestion.unit_price) : row.unit_price,
      category_id:
        row.category_id === "" &&
        suggestion.category_id &&
        rowCategoryIds.includes(suggestion.category_id)
          ? suggestion.category_id
          : row.category_id,
    });
  }

  return (
    <div className="plan-lines-editor">
      <p className="hint">Baris dengan deskripsi atau harga satuan kosong tidak akan disimpan.</p>
      {rows.length === 0 ? (
        <p className="dashboard-empty">Belum ada baris. Tambahkan baris untuk mulai mengisi.</p>
      ) : (
        <div className="plan-lines-table-wrap">
          <table className="record-table plan-lines-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Deskripsi</th>
                <th scope="col" className="num">
                  Kuantitas
                </th>
                <th scope="col" className="num">
                  Harga Satuan
                </th>
                {showTreatment ? <th scope="col">Perlakuan</th> : null}
                {showDiscount ? <th scope="col">Diskon</th> : null}
                <th scope="col">Kategori</th>
                <th scope="col" aria-label="Hapus baris" />
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => {
                const kindFilter = categoryKindFor(kind, row.treatment);
                const rowCategories = categories.filter((category) => category.kind === kindFilter);
                return (
                  <Fragment key={row.key}>
                    <tr>
                      <td>
                        <LineDescriptionInput
                          value={row.description}
                          suggestions={suggestions}
                          onChange={(text) =>
                            changeDescription(
                              row,
                              text,
                              rowCategories.map((category) => category.id),
                            )
                          }
                          onPick={(suggestion) =>
                            pickSuggestion(
                              row,
                              suggestion,
                              rowCategories.map((category) => category.id),
                            )
                          }
                        />
                      </td>
                      <td className="num" data-label="Kuantitas">
                        <input
                          type="text"
                          inputMode="decimal"
                          value={row.quantity}
                          onChange={(event) => updateRow(row.key, { quantity: event.target.value })}
                          placeholder="1"
                        />
                      </td>
                      <td className="num" data-label="Harga Satuan">
                        <MoneyInput
                          value={row.unit_price}
                          onValueChange={(unit_price) => updateRow(row.key, { unit_price })}
                          placeholder="0"
                        />
                      </td>
                      {showTreatment ? (
                        <td data-label="Perlakuan">
                          <select
                            value={row.treatment}
                            onChange={(event) =>
                              updateRow(row.key, {
                                treatment: event.target.value as RecurringLineRow["treatment"],
                              })
                            }
                          >
                            <option value="expense">Beban</option>
                            <option value="asset">Aset</option>
                            <option value="prepaid">Dibayar di Muka</option>
                          </select>
                        </td>
                      ) : null}
                      {showDiscount ? (
                        <td data-label="Diskon">
                          <div className="plan-lines-discount">
                            <select
                              aria-label="Jenis diskon"
                              value={row.discount_type}
                              onChange={(event) =>
                                updateRow(row.key, {
                                  discount_type: event.target
                                    .value as RecurringLineRow["discount_type"],
                                  discount_value:
                                    event.target.value === "none" ? "" : row.discount_value,
                                })
                              }
                            >
                              <option value="none">Tanpa diskon</option>
                              <option value="percent">Persen (%)</option>
                              <option value="fixed">Nominal (Rp)</option>
                            </select>
                            {row.discount_type !== "none" ? (
                              <MoneyInput
                                aria-label={
                                  row.discount_type === "percent"
                                    ? "Diskon persen"
                                    : "Diskon nominal"
                                }
                                value={row.discount_value}
                                onValueChange={(discount_value) =>
                                  updateRow(row.key, { discount_value })
                                }
                                placeholder={row.discount_type === "percent" ? "mis. 10" : "0"}
                              />
                            ) : null}
                          </div>
                        </td>
                      ) : null}
                      <td data-label="Kategori">
                        <select
                          value={row.category_id}
                          onChange={(event) =>
                            updateRow(row.key, { category_id: event.target.value })
                          }
                        >
                          <option value="">Tanpa kategori</option>
                          {rowCategories.map((category) => (
                            <option key={category.id} value={category.id}>
                              {category.name}
                            </option>
                          ))}
                        </select>
                      </td>
                      <td>
                        <button
                          type="button"
                          className="btn-ghost"
                          onClick={() => removeRow(row.key)}
                        >
                          Hapus
                        </button>
                      </td>
                    </tr>
                    {taxFields ? (
                      <tr className="plan-lines-tax-row">
                        <td colSpan={columnCount}>
                          <div className="plan-lines-tax-fields">
                            {kind === "invoice" ? (
                              <label>
                                Perlakuan PPN
                                <select
                                  value={extraText(row, "vat_treatment")}
                                  onChange={(event) =>
                                    updateExtra(row, "vat_treatment", event.target.value)
                                  }
                                >
                                  <option value="">Ikut kategori / belum ditentukan</option>
                                  {Object.entries(VAT_TREATMENT_LABELS).map(([value, label]) => (
                                    <option key={value} value={value}>
                                      {label}
                                    </option>
                                  ))}
                                </select>
                              </label>
                            ) : (
                              <>
                                <label>
                                  Objek potongan PPh
                                  <select
                                    value={extraText(row, "wht_object")}
                                    onChange={(event) =>
                                      updateExtra(row, "wht_object", event.target.value)
                                    }
                                  >
                                    <option value="">Ikut kategori / belum ditentukan</option>
                                    {Object.entries(WHT_OBJECT_LABELS).map(([value, label]) => (
                                      <option key={value} value={value}>
                                        {label}
                                      </option>
                                    ))}
                                  </select>
                                </label>
                                <label>
                                  PPN ditagih vendor
                                  <MoneyInput
                                    value={extraText(row, "tax_amount")}
                                    onValueChange={(amount) =>
                                      updateExtra(row, "tax_amount", amount)
                                    }
                                    placeholder="0"
                                  />
                                </label>
                                <label>
                                  No. Faktur Pajak
                                  <input
                                    type="text"
                                    maxLength={100}
                                    value={extraText(row, "vat_invoice_ref")}
                                    onChange={(event) =>
                                      updateExtra(row, "vat_invoice_ref", event.target.value)
                                    }
                                  />
                                </label>
                              </>
                            )}
                          </div>
                        </td>
                      </tr>
                    ) : null}
                  </Fragment>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <div className="plan-lines-editor-actions">
        <button type="button" className="btn-secondary" onClick={addRow}>
          + Tambah Baris
        </button>
      </div>
    </div>
  );
}
