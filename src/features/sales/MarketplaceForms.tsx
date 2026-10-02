"use client";

import { useActionState, useState } from "react";
import type { SettlementAccountOption } from "@/features/shared/SettlementForm";
import {
  createStoreAction,
  recordSettlementAction,
  reverseSettlementAction,
  type MarketplaceActionState,
} from "./marketplaceActions";

const IDLE: MarketplaceActionState = { status: "idle" };

export const MARKETPLACE_PLATFORM_LABELS: Readonly<Record<string, string>> = {
  shopee: "Shopee",
  tokopedia: "Tokopedia",
  lazada: "Lazada",
  blibli: "Blibli",
  tiktok_shop: "TikTok Shop",
  bukalapak: "Bukalapak",
  other: "Lainnya",
};

function Feedback({ state }: { state: MarketplaceActionState }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}
    </p>
  );
}

/** Add a marketplace store (decision 260). */
export function MarketplaceStoreForm({
  entity,
  accounts,
}: {
  entity: string | undefined;
  accounts: readonly SettlementAccountOption[];
}) {
  const [state, action, pending] = useActionState(createStoreAction, IDLE);
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Marketplace
        <select name="platform" defaultValue="shopee">
          {Object.entries(MARKETPLACE_PLATFORM_LABELS).map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Nama Toko
        <input name="name" required minLength={2} maxLength={120} placeholder="mis. Hikarich Official" />
      </label>
      <label>
        Rekening Tujuan Pencairan (opsional)
        <select name="account_id" defaultValue="">
          <option value="">— Pilih saat mencatat pencairan —</option>
          {accounts.map((account) => (
            <option key={account.id} value={account.id}>
              {account.label}
            </option>
          ))}
        </select>
      </label>
      <label className="checkbox-field">
        <input type="checkbox" name="pph22_exempt" /> Bebas pungutan PPh 22 (orang pribadi omzet sampai
        Rp500 juta yang sudah menyerahkan surat pernyataan)
      </label>
      <Feedback state={state} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Tambah Toko"}
      </button>
    </form>
  );
}

/** Record one settlement (payout) of a store (decision 260). The database computes PPh 22 and, while the
 * Entity is PKP, the output VAT; leaving "PPh 22 dipungut" empty accepts the computed amount. */
export function MarketplaceSettlementForm({
  entity,
  stores,
  accounts,
  today,
}: {
  entity: string | undefined;
  stores: readonly { id: string; label: string; accountId: string | null }[];
  accounts: readonly SettlementAccountOption[];
  today: string;
}) {
  const [state, action, pending] = useActionState(recordSettlementAction, IDLE);
  const [storeId, setStoreId] = useState(stores[0]?.id ?? "");
  const defaultAccount = stores.find((s) => s.id === storeId)?.accountId ?? "";

  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Toko
        <select name="store_id" required value={storeId} onChange={(e) => setStoreId(e.target.value)}>
          {stores.map((store) => (
            <option key={store.id} value={store.id}>
              {store.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Penjualan dari Tanggal
        <input type="date" name="period_start" required defaultValue={today} />
      </label>
      <label>
        Sampai Tanggal
        <input type="date" name="period_end" required defaultValue={today} />
      </label>
      <label>
        Tanggal Dana Cair
        <input type="date" name="settlement_date" required defaultValue={today} />
      </label>
      <label>
        Masuk ke Rekening
        <select name="account_id" required key={storeId} defaultValue={defaultAccount}>
          <option value="" disabled>
            Pilih rekening kas/bank
          </option>
          {accounts.map((account) => (
            <option key={account.id} value={account.id}>
              {account.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Total Penjualan (omzet, sebelum PPN)
        <input name="gross" required inputMode="decimal" placeholder="mis. 2500000" />
      </label>
      <label>
        Biaya Admin / Komisi Marketplace
        <input name="fees" inputMode="decimal" placeholder="0" />
      </label>
      <label>
        PPh 22 Dipungut Marketplace (kosongkan untuk dihitung otomatis 0,5%)
        <input name="pph22" inputMode="decimal" />
      </label>
      <label>
        Nomor Laporan / Referensi (opsional)
        <input name="reference" maxLength={200} />
      </label>
      <p className="hint">
        Dana cair = penjualan + PPN (hanya bila PKP) − biaya − PPh 22. Angka ditulis tanpa titik ribuan.
      </p>
      <Feedback state={state} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Catat Pencairan"}
      </button>
    </form>
  );
}

/** Reverse a recorded settlement: the journal, the cash movement and the tax are undone. */
export function ReverseSettlementForm({ settlementId, today }: { settlementId: string; today: string }) {
  const [state, action, pending] = useActionState(reverseSettlementAction, IDLE);
  const [open, setOpen] = useState(false);
  if (!open) {
    return (
      <button type="button" className="btn-ghost" onClick={() => setOpen(true)}>
        Batalkan
      </button>
    );
  }
  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="settlement_id" value={settlementId} />
      <input type="hidden" name="date" value={today} />
      <label>
        Alasan (minimal 5 karakter)
        <input name="reason" required minLength={5} maxLength={500} />
      </label>
      <Feedback state={state} />
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "Membatalkan…" : "Batalkan Pencairan"}
      </button>
    </form>
  );
}
