"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import Link from "next/link";
import {
  FISCAL_CLASSES,
  findFiscalClass,
  monthlyStraightLine,
} from "@/domain/assets/fiscalClasses";
import { formatMoney } from "@/domain/money/format";
import { useActionState, useState, type ReactNode } from "react";
import {
  activateAssetAction,
  cancelAssetAction,
  disposeAssetAction,
  postDepreciationAction,
  registerPendingAssetAction,
  replanAssetAction,
  reverseDepreciationAction,
  reverseDisposalAction,
  setAssetConditionAction,
  setAssetFiscalClassAction,
  transferAssetAction,
  updateAssetDetailsAction,
  type AssetActionState,
} from "./assetActions";

/**
 * The fixed-asset write forms (P8 RPCs, all `assets.manage`). Each is a small form that opens from a
 * button; the page decides which ones to render from the asset's status and the person's permission, and
 * the database checks both again.
 */

const idleAssetActionState: AssetActionState = { status: "idle" };

type AssetAction = (previous: AssetActionState, formData: FormData) => Promise<AssetActionState>;

export interface AssetAccountOption {
  id: string;
  label: string;
}

export interface AssetLineOption {
  id: string;
  label: string;
}

function Feedback({ state, next }: { state: AssetActionState; next: string }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}{" "}
      {state.stepUp ? (
        <Link href={`/auth/step-up?next=${encodeURIComponent(next)}`}>Verifikasi ulang →</Link>
      ) : null}
    </p>
  );
}

/** A form that stays closed behind one button until the person asks for it. */
function ActionForm({
  action,
  assetId,
  next,
  openLabel,
  submitLabel,
  children,
}: {
  action: AssetAction;
  assetId: string;
  next: string;
  openLabel: string;
  submitLabel: string;
  children: ReactNode;
}) {
  const [state, formAction, pending] = useActionState(action, idleAssetActionState);
  const formActionForm = usePreservingForm(formAction, state);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <div>
        {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
        <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
          {openLabel}
        </button>
      </div>
    );
  }

  return (
    <form {...formActionForm} className="record-form">
      <input type="hidden" name="asset_id" value={assetId} />
      {children}
      <Feedback state={state} next={next} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : submitLabel}
      </button>
      <button type="button" className="btn-secondary" onClick={() => setOpen(false)}>
        Tutup
      </button>
    </form>
  );
}

export function FiscalFields({
  fiscalClass,
  fiscalMethod,
  optional,
  onClassChange,
}: {
  fiscalClass: string | null;
  fiscalMethod: string | null;
  optional: boolean;
  /** Told the chosen group, so a form can suggest the useful life that goes with it. */
  onClassChange?: (key: string) => void;
}) {
  return (
    <>
      <label>
        Golongan Fiskal (untuk pajak){optional ? " (opsional)" : ""}
        <select
          name="fiscal_class"
          defaultValue={fiscalClass ?? ""}
          required={!optional}
          onChange={(event) => onClassChange?.(event.target.value)}
        >
          {optional ? (
            <option value="">Belum ditentukan</option>
          ) : (
            <option value="" disabled>
              Pilih golongan
            </option>
          )}
          {FISCAL_CLASSES.map((option) => (
            <option key={option.key} value={option.key}>
              {option.label} — {option.examples}
            </option>
          ))}
        </select>
      </label>
      <label>
        Metode Penyusutan Fiskal
        <select name="fiscal_method" defaultValue={fiscalMethod ?? "straight_line"}>
          <option value="straight_line">Garis lurus</option>
          <option value="declining_balance">Saldo menurun (bukan untuk bangunan)</option>
        </select>
      </label>
    </>
  );
}

/**
 * Method, useful life and residual value, with the fiscal group. Choosing a group fills in the useful life
 * that goes with it (the person can still change it), and the hint shows the monthly amount straight line
 * gives: (cost − residual) ÷ months. The database computes the plan that is actually posted.
 */
export function DepreciationFields({
  depreciable,
  cost,
  currency,
}: {
  /** False for a Personal ledger, whose assets are tracked at cost. */
  depreciable: boolean;
  /** The asset's cost when it is already known (activation); the opening form passes what was typed. */
  cost?: string;
  currency?: string;
}) {
  const [method, setMethod] = useState(depreciable ? "straight_line" : "none");
  const [life, setLife] = useState("");
  const [residual, setResidual] = useState("");
  const monthly =
    method === "straight_line" && cost ? monthlyStraightLine(cost, residual, life) : null;

  return (
    <>
      <FiscalFields
        fiscalClass={null}
        fiscalMethod={null}
        optional
        onClassChange={(key) => {
          const months = findFiscalClass(key)?.lifeMonths;
          if (months) setLife(String(months));
        }}
      />
      <label>
        Metode Penyusutan
        <select name="method" value={method} onChange={(event) => setMethod(event.target.value)}>
          {depreciable ? <option value="straight_line">Garis lurus</option> : null}
          {depreciable ? <option value="declining_balance">Saldo menurun</option> : null}
          <option value="none">Tidak disusutkan (mis. tanah)</option>
        </select>
      </label>
      {method !== "none" ? (
        <>
          <label>
            Umur Manfaat (bulan)
            <input
              name="life_months"
              inputMode="numeric"
              required
              placeholder="mis. 48"
              maxLength={4}
              value={life}
              onChange={(event) => setLife(event.target.value)}
            />
          </label>
          <label>
            Nilai Sisa (opsional)
            <input
              name="residual"
              inputMode="decimal"
              placeholder="0"
              value={residual}
              onChange={(event) => setResidual(event.target.value)}
            />
          </label>
          <p className="hint">
            {monthly !== null && currency
              ? `Penyusutan per bulan: ${formatMoney(monthly.toFixed(2), currency)} = (harga perolehan − nilai sisa) ÷ umur manfaat.`
              : "Garis lurus: (harga perolehan − nilai sisa) ÷ umur manfaat, sama tiap bulan. Saldo menurun: tarif tetap dari nilai buku, makin kecil tiap tahun."}{" "}
            Pilih golongan fiskal agar umur manfaat terisi otomatis.
          </p>
        </>
      ) : null}
    </>
  );
}

/** Activate a draft asset: in-service date, method and life; the database writes the monthly plan. */
export function ActivateAssetForm({
  assetId,
  next,
  today,
  depreciable,
  cost,
  currency,
}: {
  assetId: string;
  next: string;
  today: string;
  /** False for a Personal ledger, whose assets are tracked at cost. */
  depreciable: boolean;
  cost?: string;
  currency?: string;
}) {
  return (
    <ActionForm
      action={activateAssetAction}
      assetId={assetId}
      next={next}
      openLabel="Aktifkan Aset"
      submitLabel="Aktifkan Aset"
    >
      <label>
        Mulai Dipakai
        <input type="date" name="in_service_date" required defaultValue={today} max={today} />
      </label>
      <DepreciationFields depreciable={depreciable} cost={cost} currency={currency} />
    </ActionForm>
  );
}

export function UpdateAssetDetailsForm({
  assetId,
  next,
  name,
  description,
  serialNumber,
}: {
  assetId: string;
  next: string;
  name: string;
  description: string | null;
  serialNumber: string | null;
}) {
  return (
    <ActionForm
      action={updateAssetDetailsAction}
      assetId={assetId}
      next={next}
      openLabel="Ubah Data Aset"
      submitLabel="Simpan Data Aset"
    >
      <label>
        Nama Aset
        <input name="name" required maxLength={200} defaultValue={name} />
      </label>
      <label>
        Keterangan (opsional)
        <textarea name="description" maxLength={2000} rows={3} defaultValue={description ?? ""} />
      </label>
      <label>
        Nomor Seri (opsional)
        <input name="serial_number" maxLength={100} defaultValue={serialNumber ?? ""} />
      </label>
    </ActionForm>
  );
}

export function AssetConditionForm({
  assetId,
  next,
  today,
  condition,
}: {
  assetId: string;
  next: string;
  today: string;
  condition: string;
}) {
  return (
    <ActionForm
      action={setAssetConditionAction}
      assetId={assetId}
      next={next}
      openLabel="Ubah Kondisi"
      submitLabel="Simpan Kondisi"
    >
      <label>
        Kondisi
        <select name="condition" defaultValue={condition}>
          <option value="in_use">Dipakai</option>
          <option value="in_storage">Disimpan</option>
          <option value="under_repair">Sedang diperbaiki</option>
          <option value="damaged">Rusak</option>
          <option value="lost">Hilang</option>
        </select>
      </label>
      <label>
        Tanggal
        <input type="date" name="date" required defaultValue={today} max={today} />
      </label>
      <label>
        Catatan (wajib jika rusak atau hilang)
        <input name="note" maxLength={1000} placeholder="mis. layar pecah saat dipindahkan" />
      </label>
    </ActionForm>
  );
}

export function AssetFiscalClassForm({
  assetId,
  next,
  fiscalClass,
  fiscalMethod,
}: {
  assetId: string;
  next: string;
  fiscalClass: string | null;
  fiscalMethod: string | null;
}) {
  return (
    <ActionForm
      action={setAssetFiscalClassAction}
      assetId={assetId}
      next={next}
      openLabel="Atur Golongan Fiskal"
      submitLabel="Simpan Golongan Fiskal"
    >
      <FiscalFields fiscalClass={fiscalClass} fiscalMethod={fiscalMethod} optional={false} />
    </ActionForm>
  );
}

/** Change of estimate: re-plans only the months still to come; posted months stay as they are. */
export function ReplanAssetForm({
  assetId,
  next,
  method,
  residual,
}: {
  assetId: string;
  next: string;
  method: string | null;
  residual: string | null;
}) {
  return (
    <ActionForm
      action={replanAssetAction}
      assetId={assetId}
      next={next}
      openLabel="Ubah Rencana Penyusutan"
      submitLabel="Simpan Rencana Baru"
    >
      <label>
        Metode Penyusutan
        <select
          name="method"
          defaultValue={method === "declining_balance" ? "declining_balance" : "straight_line"}
        >
          <option value="straight_line">Garis lurus</option>
          <option value="declining_balance">Saldo menurun</option>
        </select>
      </label>
      <label>
        Sisa Umur Manfaat (bulan)
        <input name="remaining_months" inputMode="numeric" required maxLength={4} />
      </label>
      <label>
        Nilai Sisa
        <input name="residual" inputMode="decimal" required defaultValue={residual ?? "0"} />
      </label>
      <label>
        Alasan Perubahan
        <input name="reason" required minLength={5} maxLength={1000} />
      </label>
    </ActionForm>
  );
}

export function TransferAssetForm({
  assetId,
  next,
  today,
}: {
  assetId: string;
  next: string;
  today: string;
}) {
  return (
    <ActionForm
      action={transferAssetAction}
      assetId={assetId}
      next={next}
      openLabel="Pindahkan Aset"
      submitLabel="Simpan Pemindahan"
    >
      <p className="hint">Isi salah satu atau keduanya. Yang kosong tidak berubah.</p>
      <label>
        Lokasi Baru
        <input name="location" maxLength={200} />
      </label>
      <label>
        Penanggung Jawab Baru
        <input name="custodian" maxLength={200} />
      </label>
      <label>
        Tanggal
        <input type="date" name="date" required defaultValue={today} max={today} />
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={1000} />
      </label>
    </ActionForm>
  );
}

/** Sell, scrap or otherwise remove an active asset; only a sale has proceeds (cash or on credit). */
export function DisposeAssetForm({
  assetId,
  next,
  today,
  accounts,
}: {
  assetId: string;
  next: string;
  today: string;
  accounts: readonly AssetAccountOption[];
}) {
  const [type, setType] = useState("sale");
  const [method, setMethod] = useState("cash");
  const isSale = type === "sale";

  return (
    <ActionForm
      action={disposeAssetAction}
      assetId={assetId}
      next={next}
      openLabel="Jual / Lepas Aset"
      submitLabel="Catat Pelepasan"
    >
      <label>
        Jenis Pelepasan
        <select name="type" value={type} onChange={(event) => setType(event.target.value)}>
          <option value="sale">Dijual</option>
          <option value="scrapped">Dibuang / dihapus</option>
          <option value="lost">Hilang</option>
          <option value="damaged">Rusak total</option>
          <option value="donated">Disumbangkan</option>
        </select>
      </label>
      <label>
        Tanggal
        <input type="date" name="date" required defaultValue={today} max={today} />
      </label>
      {isSale ? (
        <>
          <label>
            Cara Pembayaran
            <select
              name="proceeds_method"
              value={method}
              onChange={(event) => setMethod(event.target.value)}
            >
              <option value="cash">Diterima tunai / transfer</option>
              <option value="receivable">Belum dibayar (piutang)</option>
              <option value="none">Tanpa hasil</option>
            </select>
          </label>
          {method !== "none" ? (
            <label>
              Harga Jual
              <input name="proceeds" inputMode="decimal" required placeholder="0" />
            </label>
          ) : null}
          {method === "cash" ? (
            <label>
              Diterima di Rekening
              <select name="account_id" required defaultValue="">
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
          ) : null}
          {method === "receivable" ? (
            <>
              <label>
                Nama Pembeli
                <input name="counterparty" required maxLength={200} />
              </label>
              <label>
                Jatuh Tempo (opsional)
                <input type="date" name="due_date" />
              </label>
            </>
          ) : null}
        </>
      ) : null}
      <label>
        Alasan
        <input name="reason" required minLength={3} maxLength={1000} />
      </label>
    </ActionForm>
  );
}

export function ReverseDisposalForm({
  assetId,
  disposalId,
  next,
  today,
}: {
  assetId: string;
  disposalId: string;
  next: string;
  today: string;
}) {
  return (
    <ActionForm
      action={reverseDisposalAction}
      assetId={assetId}
      next={next}
      openLabel="Batalkan Pelepasan"
      submitLabel="Batalkan Pelepasan"
    >
      <input type="hidden" name="disposal_id" value={disposalId} />
      <label>
        Tanggal Pembatalan
        <input type="date" name="date" required defaultValue={today} max={today} />
      </label>
      <label>
        Alasan
        <input name="reason" required minLength={5} maxLength={1000} />
      </label>
    </ActionForm>
  );
}

export function CancelAssetForm({ assetId, next }: { assetId: string; next: string }) {
  return (
    <ActionForm
      action={cancelAssetAction}
      assetId={assetId}
      next={next}
      openLabel="Batalkan Aset"
      submitLabel="Batalkan Aset"
    >
      <p className="hint">
        Hanya untuk aset yang salah didaftarkan dan belum punya penyusutan terposting. Baris
        pembeliannya kembali menunggu didaftarkan.
      </p>
      <label>
        Alasan
        <input name="reason" required minLength={5} maxLength={1000} />
      </label>
    </ActionForm>
  );
}

/** Reverse one posted month of depreciation of this asset. */
export function ReverseDepreciationForm({
  assetId,
  next,
  today,
  lines,
}: {
  assetId: string;
  next: string;
  today: string;
  lines: readonly AssetLineOption[];
}) {
  return (
    <ActionForm
      action={reverseDepreciationAction}
      assetId={assetId}
      next={next}
      openLabel="Batalkan Penyusutan Terposting"
      submitLabel="Batalkan Penyusutan"
    >
      <label>
        Bulan Penyusutan
        <select name="line_id" required defaultValue="">
          <option value="" disabled>
            Pilih bulan
          </option>
          {lines.map((line) => (
            <option key={line.id} value={line.id}>
              {line.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Tanggal Pembatalan
        <input type="date" name="date" required defaultValue={today} max={today} />
      </label>
      <label>
        Alasan
        <input name="reason" required minLength={5} maxLength={1000} />
      </label>
    </ActionForm>
  );
}

/** Post the depreciation of every complete month up to a month-end; safe to repeat. */
export function PostDepreciationForm({
  entity,
  next,
  through,
}: {
  entity: string | undefined;
  next: string;
  /** The last day of the latest complete month. */
  through: string;
}) {
  const [state, action, pending] = useActionState(postDepreciationAction, idleAssetActionState);
  const actionForm = usePreservingForm(action, state);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Posting Sampai Akhir Bulan
        <input type="date" name="through" required defaultValue={through} />
      </label>
      <p className="hint">Pilih tanggal terakhir suatu bulan yang sudah lewat.</p>
      <Feedback state={state} next={next} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Memposting…" : "Posting Penyusutan"}
      </button>
    </form>
  );
}

/** One button per approved purchase or expense line that still waits to become an asset. */
export function RegisterPendingAssetForm({
  entity,
  next,
  kind,
  lineId,
}: {
  entity: string | undefined;
  next: string;
  kind: "bill_line" | "expense_line";
  lineId: string;
}) {
  const [state, action, pending] = useActionState(registerPendingAssetAction, idleAssetActionState);
  const actionForm = usePreservingForm(action, state);

  return (
    <form {...actionForm}>
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="kind" value={kind} />
      <input type="hidden" name="line_id" value={lineId} />
      <Feedback state={state} next={next} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Mendaftarkan…" : "Daftarkan sebagai Aset"}
      </button>
    </form>
  );
}
