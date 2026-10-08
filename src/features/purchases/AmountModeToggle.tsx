"use client";

import { foldToAmount } from "@/domain/purchases/expenseAmount";
import type { RecurringLineRow } from "@/features/planning/RecurringLinesEditor";

/**
 * "Rinci per barang" switch for the expense and bill forms (decision 353). Off (the default) the lines take one
 * amount as on the receipt or invoice; on, the quantity x unit price columns come back. Switching off folds
 * quantity x price into the amount, so no value is lost.
 */
export function AmountModeToggle({
  detailed,
  onDetailedChange,
  onRows,
  noun,
}: {
  detailed: boolean;
  onDetailedChange: (detailed: boolean) => void;
  onRows: (update: (rows: RecurringLineRow[]) => RecurringLineRow[]) => void;
  noun: "struk" | "tagihan";
}) {
  return (
    <>
      <label className="checkbox-field">
        <input
          type="checkbox"
          checked={detailed}
          onChange={(event) => {
            const next = event.target.checked;
            if (!next) {
              onRows((rows) =>
                rows.map((row) => ({
                  ...row,
                  unit_price: foldToAmount(row.quantity, row.unit_price),
                  quantity: "",
                })),
              );
            }
            onDetailedChange(next);
          }}
        />
        Rinci per barang (kuantitas × harga satuan)
      </label>
      <p className="hint">
        Isi satu jumlah saja sesuai {noun}. Rincian per barang hanya bila perlu.
      </p>
    </>
  );
}
