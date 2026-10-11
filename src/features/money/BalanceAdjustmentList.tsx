"use client";

import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { formatMoney } from "@/domain/money/format";
import type { BalanceAdjustmentRow } from "@/schemas/money";
import { reverseBalanceAdjustmentAction } from "./balanceAdjustmentActions";

/**
 * What has been adjusted, and the way back (OWNER, 11 October 2026; decision 405). Penyesuaian Lanjutan was
 * a form and nothing else: once recorded, an adjustment could not be seen from this screen again and could
 * not be undone at all -- on the one screen whose whole purpose is correcting mistakes.
 *
 * Cancelling does not delete. The database posts the opposite journal and the opposite movement, **on the
 * original's own date**, and keeps both; a reversed row stays in this list, greyed, so the trail reads the
 * way it happened. The date matters: a reversal taken today on a September entry would otherwise show cash
 * leaving in a month where nothing moved, which is exactly how this gap was found.
 */
export function BalanceAdjustmentList({
  rows,
  entity,
  canAdjust,
}: {
  rows: readonly BalanceAdjustmentRow[];
  entity: string | undefined;
  canAdjust: boolean;
}) {
  const [state, action, pending] = useActionState(reverseBalanceAdjustmentAction, {
    status: "idle" as const,
  });
  const actionForm = usePreservingForm(action, state);
  const [cancelling, setCancelling] = useState<string | null>(null);
  const [reason, setReason] = useState("");

  if (rows.length === 0) {
    return (
      <p className="dashboard-empty">Belum ada penyesuaian saldo yang dicatat untuk Entity ini.</p>
    );
  }

  return (
    <>
      <table className="record-table record-table-stacked">
        <thead>
          <tr>
            <th scope="col">Tanggal</th>
            <th scope="col">Akun</th>
            <th scope="col">Akun Lawan</th>
            <th scope="col" className="num">
              Jumlah
            </th>
            <th scope="col">Alasan</th>
            <th scope="col">Status</th>
            <th scope="col">Tindakan</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.adjustment_id} data-muted={row.status === "reversed" ? "true" : undefined}>
              <td>{row.movement_date}</td>
              <td data-label="Akun">{row.account_name}</td>
              <td data-label="Akun Lawan">
                {row.counter_code ? `${row.counter_code} · ${row.counter_name}` : "—"}
              </td>
              <td className="num" data-label="Jumlah">
                {row.direction === "out" ? "−" : "+"}
                {formatMoney(row.amount, row.currency)}
              </td>
              <td data-label="Alasan">{row.reason ?? "—"}</td>
              <td data-label="Status">
                <span
                  className={`status-badge status-badge-${row.status === "reversed" ? "neutral" : "success"}`}
                >
                  {row.status === "reversed" ? "Dibatalkan" : "Berlaku"}
                </span>
              </td>
              <td data-label="Tindakan">
                {row.status === "reversed" || !canAdjust ? (
                  "—"
                ) : cancelling === row.adjustment_id ? (
                  <form {...actionForm} className="purpose-edit-form">
                    <input type="hidden" name="adjustment_id" value={row.adjustment_id} />
                    <input type="hidden" name="entity" value={entity ?? ""} />
                    <input
                      type="text"
                      name="reason"
                      aria-label="Alasan pembatalan"
                      required
                      minLength={5}
                      maxLength={500}
                      placeholder="Alasan pembatalan"
                      value={reason}
                      onChange={(event) => setReason(event.target.value)}
                    />
                    <button type="submit" className="btn-danger" disabled={pending}>
                      {pending ? "Membatalkan…" : "Batalkan"}
                    </button>
                    <button type="button" className="btn-ghost" onClick={() => setCancelling(null)}>
                      Tutup
                    </button>
                  </form>
                ) : (
                  <button
                    type="button"
                    className="btn-ghost"
                    onClick={() => {
                      setCancelling(row.adjustment_id);
                      setReason("");
                    }}
                  >
                    Batalkan
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <p className="hint">
        Membatalkan tidak menghapus. Sistem memposting jurnal kebalikannya pada tanggal penyesuaian
        aslinya, dan keduanya tetap terlihat — itulah cara pembukuan mengoreksi diri.
      </p>

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
    </>
  );
}
