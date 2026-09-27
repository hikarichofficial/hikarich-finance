"use client";

import type { CategoryRow } from "@/schemas/categories";
import type { RecurringKind } from "@/domain/planning/planning";

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
 */

export interface RecurringLineRow {
  key: string;
  description: string;
  quantity: string;
  unit_price: string;
  category_id: string;
  treatment: "expense" | "asset" | "prepaid";
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
    extra: {},
    ...initial,
  };
}

export function newRecurringLineRow(seq: number): RecurringLineRow {
  return makeRow(`new-${seq}`);
}

const RENDERED_LINE_FIELDS = ["description", "quantity", "unit_price", "category_id", "treatment"];

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
      quantity: line.quantity != null ? String(line.quantity) : "",
      unit_price: line.unit_price != null ? String(line.unit_price) : "",
      category_id: typeof line.category_id === "string" ? line.category_id : "",
      treatment:
        line.treatment === "asset" || line.treatment === "prepaid" ? line.treatment : "expense",
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
      const unitPrice = row.unit_price.trim();
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
      }
      return [line];
    }),
  );
}

function categoryKindFor(kind: RecurringKind, treatment: RecurringLineRow["treatment"]): string {
  if (kind === "invoice") return "revenue";
  return treatment === "expense" ? "expense" : "asset";
}

export function RecurringLinesEditor({
  kind,
  categories,
  rows,
  onChange,
}: {
  kind: RecurringKind;
  categories: readonly CategoryRow[];
  rows: readonly RecurringLineRow[];
  onChange: (rows: RecurringLineRow[]) => void;
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

  const showTreatment = kind !== "invoice";

  return (
    <div className="plan-lines-editor">
      <p className="hint">Baris dengan deskripsi atau harga satuan kosong tidak akan disimpan.</p>
      {rows.length === 0 ? (
        <p className="dashboard-empty">Belum ada baris. Tambahkan baris untuk mulai mengisi.</p>
      ) : (
        <div className="plan-lines-table-wrap">
          <table className="record-table plan-lines-table">
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
                <th scope="col">Kategori</th>
                <th scope="col" aria-label="Hapus baris" />
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => {
                const kindFilter = categoryKindFor(kind, row.treatment);
                const rowCategories = categories.filter((category) => category.kind === kindFilter);
                return (
                  <tr key={row.key}>
                    <td>
                      <input
                        type="text"
                        maxLength={500}
                        value={row.description}
                        onChange={(event) => updateRow(row.key, { description: event.target.value })}
                        placeholder="Deskripsi baris"
                      />
                    </td>
                    <td className="num">
                      <input
                        type="text"
                        inputMode="decimal"
                        value={row.quantity}
                        onChange={(event) => updateRow(row.key, { quantity: event.target.value })}
                        placeholder="1"
                      />
                    </td>
                    <td className="num">
                      <input
                        type="text"
                        inputMode="decimal"
                        value={row.unit_price}
                        onChange={(event) => updateRow(row.key, { unit_price: event.target.value })}
                        placeholder="0"
                      />
                    </td>
                    {showTreatment ? (
                      <td>
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
                    <td>
                      <select
                        value={row.category_id}
                        onChange={(event) => updateRow(row.key, { category_id: event.target.value })}
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
                      <button type="button" className="btn-ghost" onClick={() => removeRow(row.key)}>
                        Hapus
                      </button>
                    </td>
                  </tr>
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
