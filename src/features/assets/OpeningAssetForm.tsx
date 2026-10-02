"use client";

import Link from "next/link";
import { useActionState, useState } from "react";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { loadOpeningAssetAction, type AssetActionState } from "./assetActions";
import { DepreciationFields, type AssetAccountOption } from "./AssetForms";

const idleState: AssetActionState = { status: "idle" };

/**
 * "Aset yang Sudah Dimiliki": one asset the business owned before it started using this app. The person
 * gives what it cost, when it was bought, and how much depreciation had already been taken up to the
 * cut-over date; the database plans the months that remain.
 */
export function OpeningAssetForm({
  entity,
  next,
  today,
  depreciable,
  currency,
  accounts,
}: {
  entity: string | undefined;
  next: string;
  today: string;
  depreciable: boolean;
  currency: string;
  accounts: readonly AssetAccountOption[];
}) {
  const [state, action, pending] = useActionState(loadOpeningAssetAction, idleState);
  const actionForm = usePreservingForm(action, state);
  const [cost, setCost] = useState("");
  const [name, setName] = useState("");

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Nama Aset
        <input
          name="name"
          required
          maxLength={200}
          placeholder="mis. Laptop kerja, Meja kantor"
          value={name}
          onChange={(event) => setName(event.target.value)}
        />
      </label>
      <label>
        Akun Aset Tetap
        <select name="cost_account" required defaultValue="">
          <option value="" disabled>
            Pilih akun
          </option>
          {accounts.map((account) => (
            <option key={account.id} value={account.id}>
              {account.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Harga Perolehan (tanpa titik ribuan)
        <input
          name="cost"
          required
          inputMode="decimal"
          value={cost}
          onChange={(event) => setCost(event.target.value)}
        />
      </label>
      <label>
        Tanggal Beli
        <input type="date" name="acquisition_date" required max={today} />
      </label>
      <label>
        Mulai Dipakai
        <input type="date" name="in_service_date" required max={today} />
      </label>
      <label>
        Tanggal Mulai Dicatat di Aplikasi Ini
        <input type="date" name="cutover_date" required defaultValue={today} max={today} />
      </label>
      <label>
        Penyusutan yang Sudah Dicatat sampai Tanggal Itu (opsional)
        <input name="accumulated" inputMode="decimal" placeholder="0" />
      </label>
      <DepreciationFields depreciable={depreciable} name={name} cost={cost} currency={currency} />
      <label>
        Nomor Seri (opsional)
        <input name="serial_number" maxLength={100} />
      </label>
      <label>
        Lokasi (opsional)
        <input name="location" maxLength={200} />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}{" "}
          {state.stepUp ? (
            <Link href={`/auth/step-up?next=${encodeURIComponent(next)}`}>Verifikasi ulang →</Link>
          ) : null}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Aset"}
      </button>
    </form>
  );
}
