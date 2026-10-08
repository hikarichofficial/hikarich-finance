"use client";

import { trimDecimalText } from "@/domain/money/format";
import { Fragment, useState } from "react";
import type { CategoryRow } from "@/schemas/categories";
import type { RecurringKind } from "@/domain/planning/planning";
import {
  VAT_TREATMENT_LABELS,
  WHT_OBJECT_LABELS,
  WHT_QUICK_CHOICES,
  categorySettlesWithholding,
  type WhtObject,
} from "@/domain/tax/tax";
import { formatMoneyTyping, plainMoneyText } from "@/domain/money/typing";
import { splitVatInclusive, VAT_RATE_PERCENT } from "@/domain/tax/vatInclusive";
import {
  LINE_FIELD_HINTS,
  type LineField,
  type ProblemTarget,
} from "@/domain/forms/problemTargets";
import { exactSuggestion, type LineSuggestion } from "@/domain/sales/lineSuggestions";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { ContactPicker } from "@/features/contacts/ContactPicker";
import { QuickAddCategoryDrawer } from "@/features/categories/QuickAddCategoryDrawer";
import { LineDescriptionInput } from "./LineDescriptionInput";
import {
  buildInitialRecurringLines,
  buildRecurringLinesJson,
  canIncludeVat,
  newRecurringLineRow,
  serializedRowKeys,
  type RecurringLineRow,
} from "@/domain/planning/recurringLines";

export { buildInitialRecurringLines, buildRecurringLinesJson, newRecurringLineRow };
export type { RecurringLineRow };

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
  entity,
  amountOnly = false,
  whtAgent,
  foreignPayee = false,
  problems = [],
  problemSerial = 0,
  attempted = false,
}: {
  kind: RecurringKind;
  /** One "Jumlah" amount per line (quantity 1) instead of quantity x unit price (expense form, decision 353). */
  amountOnly?: boolean;
  /** The active Entity code, so a category added on the spot lands in the right Entity. */
  entity?: string;
  categories: readonly CategoryRow[];
  rows: readonly RecurringLineRow[];
  onChange: (rows: RecurringLineRow[]) => void;
  /** Show the per-line tax facts (VAT charged, tax-invoice number, withholding object / VAT treatment). */
  taxFields?: boolean;
  /** The Entity withholds tax (Pemotong Pajak = Ya): a line whose category does not settle it must be answered. */
  whtAgent?: boolean;
  /** The chosen vendor is a foreign company: "Kena PPh?" starts as "not subject" (PPh 23 is for domestic vendors). */
  foreignPayee?: boolean;
  /** Descriptions already used before (with their last price), for the popup above the description field. */
  suggestions?: readonly LineSuggestion[];
  /** Columns the last refusal was about (database line numbers): painted red with what to do, until changed. */
  problems?: readonly ProblemTarget[];
  /** Changes with every new refusal, so a column the person already fixed is not hidden for the next one. */
  problemSerial?: number;
  /** The person pressed save: a half-filled row or an unanswered required column is painted red too. */
  attempted?: boolean;
}) {
  // Categories added on the spot (decision 340) are usable at once, before the page itself refreshes.
  const [addedCategories, setAddedCategories] = useState<CategoryRow[]>([]);
  const [addingFor, setAddingFor] = useState<{
    rowKey: string;
    kind: "revenue" | "expense" | "asset";
    name: string;
  } | null>(null);
  // Columns the person has changed since the refusal: their red mark goes away at once.
  const [dismissed, setDismissed] = useState<{ serial: number; keys: ReadonlySet<string> }>({
    serial: problemSerial,
    keys: new Set(),
  });
  const dismissedKeys = dismissed.serial === problemSerial ? dismissed.keys : new Set<string>();
  function dismiss(rowKey: string, field: LineField) {
    const keys = new Set(dismissedKeys).add(`${rowKey}.${field}`);
    setDismissed({ serial: problemSerial, keys });
  }
  const serialKeys = serializedRowKeys(rows);
  /** Red marks of one row: field -> what to do. */
  function problemsOf(row: RecurringLineRow): Partial<Record<LineField, string>> {
    const out: Partial<Record<LineField, string>> = {};
    const line = serialKeys.indexOf(row.key) + 1;
    if (line > 0) {
      for (const target of problems) {
        if (
          target.scope === "line" &&
          target.line === line &&
          !dismissedKeys.has(`${row.key}.${target.field}`)
        ) {
          out[target.field] = LINE_FIELD_HINTS[target.field];
        }
      }
    }
    if (attempted) {
      const hasDescription = row.description.trim() !== "";
      const hasAmount = plainMoneyText(row.unit_price.trim()) !== "";
      if (hasDescription && !hasAmount) out.amount = "Isi jumlah, atau hapus baris ini.";
      if (!hasDescription && hasAmount) out.description = "Isi deskripsi, atau hapus baris ini.";
    }
    return out;
  }
  const allCategories = [
    ...categories,
    ...addedCategories.filter((added) => !categories.some((c) => c.id === added.id)),
  ];

  function addRow() {
    onChange([...rows, newRecurringLineRow(rows.length + 1)]);
  }

  function removeRow(key: string) {
    onChange(rows.filter((row) => row.key !== key));
  }

  function updateRow(key: string, patch: Partial<RecurringLineRow>) {
    const touched: [keyof RecurringLineRow, LineField][] = [
      ["description", "description"],
      ["unit_price", "amount"],
      ["quantity", "amount"],
      ["category_id", "category"],
      ["treatment", "treatment"],
    ];
    const hit = touched.filter(([name]) => name in patch);
    if (hit.length > 0) {
      const keys = new Set(dismissedKeys);
      for (const [, field] of hit) keys.add(`${key}.${field}`);
      setDismissed({ serial: problemSerial, keys });
    }
    onChange(rows.map((row) => (row.key === key ? { ...row, ...patch } : row)));
  }

  function updateExtra(row: RecurringLineRow, field: string, value: string) {
    const mapped: Record<string, LineField> = {
      wht_object: "wht",
      vat_invoice_ref: "vat_invoice_ref",
      tax_amount: "vat_amount",
    };
    const target = mapped[field];
    if (target) dismiss(row.key, target);
    const extra = { ...row.extra };
    if (value.trim() === "") delete extra[field];
    else extra[field] = value.trim();
    updateRow(row.key, { extra });
  }

  const showTreatment = kind !== "invoice";
  const showDiscount = kind === "invoice";
  const columnCount = amountOnly ? 5 : 6;

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
      <p className="hint">
        {amountOnly
          ? "Baris dengan deskripsi atau jumlah kosong tidak akan disimpan."
          : "Baris dengan deskripsi atau harga satuan kosong tidak akan disimpan."}
      </p>
      {rows.length === 0 ? (
        <p className="dashboard-empty">Belum ada baris. Tambahkan baris untuk mulai mengisi.</p>
      ) : (
        <div className="plan-lines-table-wrap">
          <table className="record-table plan-lines-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Deskripsi</th>
                {amountOnly ? null : (
                  <th scope="col" className="num">
                    Kuantitas
                  </th>
                )}
                <th scope="col" className="num">
                  {amountOnly ? "Jumlah (sesuai struk)" : "Harga Satuan"}
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
                const rowCategories = allCategories.filter(
                  (category) => category.kind === kindFilter,
                );
                const category = allCategories.find((c) => c.id === row.category_id);
                const settledKey = categorySettlesWithholding(category?.tax_category_key)
                  ? (category?.tax_category_key as WhtObject)
                  : null;
                const marks = problemsOf(row);
                const hint = (field: LineField) =>
                  marks[field] ? <p className="field-problem-hint">{marks[field]}</p> : null;
                const vatSplit =
                  row.price_includes_vat && canIncludeVat(row, kind)
                    ? splitVatInclusive(plainMoneyText(row.unit_price.trim()))
                    : null;
                return (
                  <Fragment key={row.key}>
                    <tr>
                      <td className={marks.description ? "cell-problem" : undefined}>
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
                        {hint("description")}
                      </td>
                      {amountOnly ? null : (
                        <td className="num" data-label="Kuantitas">
                          <input
                            type="text"
                            inputMode="decimal"
                            value={row.quantity}
                            onChange={(event) =>
                              updateRow(row.key, { quantity: event.target.value })
                            }
                            placeholder="1"
                          />
                        </td>
                      )}
                      <td
                        className={marks.amount ? "num cell-problem" : "num"}
                        data-label={amountOnly ? "Jumlah" : "Harga Satuan"}
                      >
                        <MoneyInput
                          value={row.unit_price}
                          onValueChange={(unit_price) => updateRow(row.key, { unit_price })}
                          placeholder="0"
                        />
                        {hint("amount")}
                        {hint("vat_amount")}
                      </td>
                      {showTreatment ? (
                        <td
                          data-label="Perlakuan"
                          className={marks.treatment ? "cell-problem" : undefined}
                        >
                          <select
                            value={row.treatment}
                            onChange={(event) => {
                              const treatment = event.target.value as RecurringLineRow["treatment"];
                              // A category of the other kind no longer fits the new treatment.
                              const stillFits = allCategories.some(
                                (c) =>
                                  c.id === row.category_id &&
                                  c.kind === categoryKindFor(kind, treatment),
                              );
                              updateRow(row.key, {
                                treatment,
                                category_id: stillFits ? row.category_id : "",
                              });
                            }}
                          >
                            <option value="expense">Beban</option>
                            <option value="asset">Aset</option>
                            <option value="prepaid">Dibayar di Muka</option>
                          </select>
                          {hint("treatment")}
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
                      <td
                        data-label="Kategori"
                        className={marks.category ? "cell-problem" : undefined}
                      >
                        <div className="category-picker-cell">
                          <ContactPicker
                            label="Kategori"
                            name={`line-category-${row.key}`}
                            noun="kategori"
                            optional
                            contacts={rowCategories.map((category) => ({
                              id: category.id,
                              display_name: category.name,
                            }))}
                            value={row.category_id}
                            onChange={(id) => updateRow(row.key, { category_id: id })}
                            onAddNew={(typed) =>
                              setAddingFor({
                                rowKey: row.key,
                                kind: kindFilter as "revenue" | "expense" | "asset",
                                name: typed,
                              })
                            }
                          />
                        </div>
                        {hint("category")}
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
                                {whtAgent === false
                                  ? null
                                  : (() => {
                                      // The answer shown is what will be used: the person's own choice, else the
                                      // category's, else "not subject" (OWNER, 8 October 2026).
                                      const chosen = extraText(row, "wht_object");
                                      const asset = row.treatment === "asset";
                                      const automatic: string =
                                        asset || foreignPayee
                                          ? "wht_none"
                                          : (settledKey ?? "wht_none");
                                      const shown = chosen !== "" ? chosen : automatic;
                                      const options: { value: string; label: string }[] = [
                                        ...WHT_QUICK_CHOICES,
                                      ];
                                      if (!options.some((o) => o.value === shown)) {
                                        options.push({
                                          value: shown,
                                          label: WHT_OBJECT_LABELS[shown as WhtObject] ?? shown,
                                        });
                                      }
                                      const source =
                                        chosen !== ""
                                          ? "Pilihan Anda untuk baris ini."
                                          : asset
                                            ? "Otomatis: pembelian aset / peralatan tidak kena PPh."
                                            : foreignPayee
                                              ? "Otomatis tidak kena PPh karena vendor luar negeri. Ubah bila konsultan pajak menyatakan lain."
                                              : settledKey
                                                ? "Otomatis dari kategori; boleh diubah."
                                                : "Belum dipilih: dihitung tidak kena PPh.";
                                      const borne =
                                        shown !== "wht_none" && shown !== "wht_review"
                                          ? " PPh ini beban PT: vendor dibayar penuh, pajaknya dibayar terpisah ke negara."
                                          : "";
                                      return (
                                        <label
                                          className={
                                            marks.wht
                                              ? "field-problem plan-lines-wht"
                                              : "plan-lines-wht"
                                          }
                                        >
                                          <strong>Kena PPh?</strong>
                                          <select
                                            value={shown}
                                            onChange={(event) =>
                                              updateExtra(row, "wht_object", event.target.value)
                                            }
                                          >
                                            {options.map((choice) => (
                                              <option key={choice.value} value={choice.value}>
                                                {choice.label}
                                              </option>
                                            ))}
                                          </select>
                                          <span className="hint">
                                            {source}
                                            {borne}
                                          </span>
                                          {hint("wht")}
                                        </label>
                                      );
                                    })()}
                                {canIncludeVat(row, kind) ? (
                                  <div className="plan-lines-tax-card">
                                    <strong>PPN dari vendor / restoran</strong>
                                    <label className="plan-lines-check">
                                      <input
                                        type="checkbox"
                                        checked={row.price_includes_vat === true}
                                        onChange={(event) =>
                                          updateRow(row.key, {
                                            price_includes_vat: event.target.checked,
                                          })
                                        }
                                      />
                                      <span>Jumlah sudah termasuk PPN {VAT_RATE_PERCENT}%</span>
                                    </label>
                                    <span className="hint">
                                      {row.price_includes_vat
                                        ? vatSplit
                                          ? `Sebelum PPN Rp ${formatMoneyTyping(vatSplit.net)} + PPN Rp ${formatMoneyTyping(vatSplit.vat)} (PPN yang dipungut vendor, bukan pajak yang Anda setor). PPh dihitung dari harga sebelum PPN.`
                                          : "Isi jumlah dulu; PPN dihitung otomatis."
                                        : "Centang bila struk memuat PPN, yaitu pajak yang dipungut vendor atau restoran (bukan pajak yang Anda setor). Harga sebelum PPN dihitung otomatis."}
                                    </span>
                                  </div>
                                ) : null}
                                {extraText(row, "tax_amount") !== "" && !vatSplit ? (
                                  <p className="hint">
                                    PPN tercatat di baris ini: Rp{" "}
                                    {formatMoneyTyping(extraText(row, "tax_amount"))}.
                                  </p>
                                ) : null}
                                <label
                                  className={
                                    marks.vat_invoice_ref
                                      ? "field-problem plan-lines-tax-card"
                                      : "plan-lines-tax-card"
                                  }
                                >
                                  <strong>No. Faktur Pajak</strong>
                                  <input
                                    type="text"
                                    maxLength={100}
                                    value={extraText(row, "vat_invoice_ref")}
                                    onChange={(event) =>
                                      updateExtra(row, "vat_invoice_ref", event.target.value)
                                    }
                                  />
                                  <span className="hint">
                                    Isi bila vendor memberi faktur pajak.
                                  </span>
                                  {hint("vat_invoice_ref")}
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
      {addingFor ? (
        <QuickAddCategoryDrawer
          key={`${addingFor.rowKey}-${addingFor.name}`}
          kind={addingFor.kind}
          entity={entity}
          initialName={addingFor.name}
          open
          onClose={() => setAddingFor(null)}
          onCreated={(created) => {
            setAddedCategories((list) => [
              ...list,
              {
                id: created.id,
                entity_id: "",
                name: created.name,
                kind: created.kind as CategoryRow["kind"],
                sort_order: 0,
              },
            ]);
            updateRow(addingFor.rowKey, { category_id: created.id });
            setAddingFor(null);
          }}
        />
      ) : null}
    </div>
  );
}
