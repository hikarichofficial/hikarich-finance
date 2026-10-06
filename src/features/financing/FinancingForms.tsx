"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useState, type ReactNode } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import {
  activateLoanAction,
  cancelEquityEventAction,
  cancelLoanAction,
  confirmEquityEventAction,
  createEquityEventAction,
  createLoanAction,
  createObligationAction,
  payDividendAction,
  repayLoanAction,
  reverseDividendPaymentAction,
  reverseEquityEventAction,
  reverseLoanFxRevaluationAction,
  reverseLoanPaymentAction,
  reverseObligationSettlementAction,
  revalueLoanFxAction,
  restructureLoanAction,
  setLoanAssetAction,
  setLoanFxTermsAction,
  settleObligationAction,
  voidObligationAction,
  writeOffLoanAction,
  writeOffObligationAction,
  type FinancingActionState,
} from "./financingActions";
import { MoneyInput } from "@/features/shared/MoneyInput";

/**
 * The financing write forms: create a loan / other receivable or payable / equity event, and the commands
 * on each Detail screen. Each form posts to one server action over one unmodified P8 RPC. The page decides
 * which forms to show (status and permission); the database still checks everything again.
 */

const idleFinancingActionState: FinancingActionState = { status: "idle" };

type FinancingAction = (
  previous: FinancingActionState,
  formData: FormData,
) => Promise<FinancingActionState>;

export interface FinancingOption {
  id: string;
  label: string;
}

function Feedback({ state, next }: { state: FinancingActionState; next: string }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}{" "}
      {state.stepUp ? (
        <StepUpLink href={`/auth/step-up?next=${encodeURIComponent(next)}`}>
          Verifikasi ulang →
        </StepUpLink>
      ) : null}
    </p>
  );
}

/** One command form that opens from a button, like `RefundForm`. */
function CommandForm({
  action,
  idName,
  id,
  next,
  openLabel,
  submitLabel,
  primary,
  children,
}: {
  action: FinancingAction;
  idName: string;
  id: string;
  next: string;
  openLabel: string;
  submitLabel: string;
  primary?: boolean;
  children: ReactNode;
}) {
  const [state, formAction, pending] = useActionState(action, idleFinancingActionState);
  const formActionForm = usePreservingForm(formAction, state);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button
        type="button"
        className={primary ? "btn-primary" : "btn-secondary"}
        onClick={() => setOpen(true)}
      >
        {openLabel}
      </button>
    );
  }

  return (
    <form {...formActionForm} className="record-form">
      <input type="hidden" name={idName} value={id} />
      {children}
      <Feedback state={state} next={next} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : submitLabel}
      </button>
    </form>
  );
}

function AccountField({
  label,
  accounts,
}: {
  label: string;
  accounts: readonly FinancingOption[];
}) {
  return (
    <label>
      {label}
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
  );
}

function DateField({ label, today }: { label: string; today: string }) {
  return (
    <label>
      {label}
      <input type="date" name="date" required defaultValue={today} max={today} />
    </label>
  );
}

function ReasonField() {
  return (
    <label>
      Alasan
      <input name="reason" required minLength={5} maxLength={1000} />
    </label>
  );
}

function MoneyField({
  name,
  label,
  defaultValue,
  required,
}: {
  name: string;
  label: string;
  defaultValue?: string;
  required?: boolean;
}) {
  return (
    <label>
      {label}
      <MoneyInput name={name} required={required} defaultValue={defaultValue} placeholder="0" />
    </label>
  );
}

function PickField({
  name,
  label,
  placeholder,
  options,
}: {
  name: string;
  label: string;
  placeholder: string;
  options: readonly FinancingOption[];
}) {
  return (
    <label>
      {label}
      <select name={name} required defaultValue="">
        <option value="" disabled>
          {placeholder}
        </option>
        {options.map((option) => (
          <option key={option.id} value={option.id}>
            {option.label}
          </option>
        ))}
      </select>
    </label>
  );
}

/** A text field whose value is usually one of a known, finite set (a counterparty already in Contacts) but
 * can still be typed freely for a name not yet on file -- "boleh diklik dan pilih, atau tetap bisa ketik
 * baru" per the owner (5 Oct 2026). Native `<input list>` renders this as a text box with a dropdown of
 * suggestions, so no new component or RPC is needed. */
function PartyField({
  listId,
  label,
  knownParties,
}: {
  listId: string;
  label: ReactNode;
  knownParties: readonly string[];
}) {
  return (
    <label>
      {label}
      <input name="counterparty" required maxLength={200} autoComplete="off" list={listId} />
      <datalist id={listId}>
        {knownParties.map((name) => (
          <option key={name} value={name} />
        ))}
      </datalist>
    </label>
  );
}

// ================================================================ create forms
export function LoanCreateForm({
  entity,
  isCompany,
  today,
  knownParties,
}: {
  entity: string | undefined;
  isCompany: boolean;
  today: string;
  knownParties: readonly string[];
}) {
  const [state, action, pending] = useActionState(createLoanAction, idleFinancingActionState);
  const actionForm = usePreservingForm(action, state);
  const [direction, setDirection] = useState("borrowed");

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Jenis Pinjaman
        <select
          name="direction"
          value={direction}
          onChange={(event) => setDirection(event.target.value)}
        >
          <option value="borrowed">Pinjaman diterima (kita berutang)</option>
          <option value="lent">Pinjaman diberikan (kita meminjamkan)</option>
        </select>
      </label>
      <PartyField
        listId="loan-counterparty-options"
        label={direction === "borrowed" ? "Pemberi Pinjaman" : "Peminjam"}
        knownParties={knownParties}
      />
      <label>
        Tujuan Pinjaman
        <input name="purpose" required minLength={3} maxLength={500} autoComplete="off" />
      </label>
      <MoneyField name="principal" label="Jumlah Pokok" required />
      <label>
        Tanggal Perjanjian
        <input type="date" name="agreement_date" required defaultValue={today} max={today} />
      </label>
      {isCompany && direction === "borrowed" ? (
        <label>
          Jangka Waktu
          <select name="term_class" defaultValue="short">
            <option value="short">Jangka pendek (sampai 1 tahun)</option>
            <option value="long">Jangka panjang (lebih dari 1 tahun)</option>
          </select>
        </label>
      ) : null}
      <label>
        Bunga per Tahun (%)
        <input name="rate_percent" inputMode="decimal" defaultValue="0" />
      </label>
      <label>
        Cara Hitung Cicilan
        <select name="method" defaultValue="annuity">
          <option value="annuity">Anuitas (cicilan sama tiap kali)</option>
          <option value="flat">Flat (pokok dan bunga tetap)</option>
          <option value="interest_only">Bunga saja, pokok di akhir</option>
        </select>
      </label>
      <label>
        Jumlah Cicilan
        <input name="installments" type="number" min={1} max={600} required defaultValue={12} />
      </label>
      <label>
        Jarak Antar Cicilan
        <select name="step_months" defaultValue="1">
          <option value="1">Tiap bulan</option>
          <option value="3">Tiap 3 bulan</option>
          <option value="6">Tiap 6 bulan</option>
          <option value="12">Tiap tahun</option>
        </select>
      </label>
      <label>
        Tanggal Cicilan Pertama
        <input type="date" name="first_due" required />
      </label>
      <p className="hint">
        Pinjaman disimpan sebagai draf. Uang baru dicatat saat pinjaman diaktifkan di halaman
        detailnya.
      </p>
      <Feedback state={state} next="/assets/loans/new" />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Pinjaman"}
      </button>
    </form>
  );
}

export function ObligationCreateForm({
  entity,
  kind,
  accounts,
  today,
  knownParties,
}: {
  entity: string | undefined;
  kind: "receivable" | "payable";
  accounts: readonly FinancingOption[];
  today: string;
  knownParties: readonly string[];
}) {
  const [state, action, pending] = useActionState(createObligationAction, idleFinancingActionState);
  const actionForm = usePreservingForm(action, state);
  const receivable = kind === "receivable";

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="kind" value={kind} />
      <PartyField
        listId="obligation-counterparty-options"
        label={receivable ? "Siapa yang Berutang ke Kita" : "Kepada Siapa Kita Berutang"}
        knownParties={knownParties}
      />
      <label>
        Keterangan
        <input name="purpose" required minLength={3} maxLength={500} autoComplete="off" />
      </label>
      <MoneyField name="amount" label="Jumlah" required />
      <DateField label="Tanggal" today={today} />
      <label>
        Jatuh Tempo (opsional)
        <input type="date" name="due_date" />
      </label>
      <AccountField
        label={receivable ? "Uang Keluar dari Rekening" : "Uang Masuk ke Rekening"}
        accounts={accounts}
      />
      <Feedback state={state} next="/assets/obligations/new" />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan"}
      </button>
    </form>
  );
}

export function EquityCreateForm({
  entity,
  kinds,
  today,
  knownParties,
}: {
  entity: string | undefined;
  kinds: readonly FinancingOption[];
  today: string;
  knownParties: readonly string[];
}) {
  const [state, action, pending] = useActionState(
    createEquityEventAction,
    idleFinancingActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const [kind, setKind] = useState(kinds[0]?.id ?? "");
  const hasClass = kind === "contribution" || kind === "capital_return";
  const needsResolution = kind === "capital_return" || kind === "dividend";

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Jenis
        <select name="kind" value={kind} onChange={(event) => setKind(event.target.value)}>
          {kinds.map((option) => (
            <option key={option.id} value={option.id}>
              {option.label}
            </option>
          ))}
        </select>
      </label>
      <PartyField
        listId="equity-counterparty-options"
        label="Nama Pemilik / Pihak"
        knownParties={knownParties}
      />
      <label>
        Keterangan
        <input name="purpose" required minLength={3} maxLength={500} autoComplete="off" />
      </label>
      <MoneyField name="amount" label="Jumlah" required />
      <DateField label="Tanggal" today={today} />
      {hasClass ? (
        <label>
          Golongan Modal
          <select name="equity_class" defaultValue="capital">
            <option value="capital">Modal disetor</option>
            <option value="additional">Tambahan modal</option>
          </select>
        </label>
      ) : null}
      {needsResolution ? (
        <label>
          Nomor Keputusan Pemegang Saham (RUPS)
          <input name="resolution_reference" required minLength={3} maxLength={200} />
        </label>
      ) : null}
      <p className="hint">
        Data disimpan sebagai draf. Pencatatan ke buku terjadi saat dikonfirmasi di halaman
        detailnya.
      </p>
      <Feedback state={state} next="/assets/equity/new" />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan"}
      </button>
    </form>
  );
}

// ================================================================ loan detail commands
export function LoanActionsPanel({
  loanId,
  lent,
  status,
  outstanding,
  payments,
  accounts,
  today,
  next,
  fxCurrency,
  fxNote,
  fxLatestRevaluationId,
  assets,
  currentAssetId,
}: {
  loanId: string;
  lent: boolean;
  status: "draft" | "active" | "closed" | "cancelled";
  outstanding: string;
  /** Active payments of the current schedule: the ones the database lets you reverse. */
  payments: readonly FinancingOption[];
  accounts: readonly FinancingOption[];
  today: string;
  next: string;
  /** The loan's FX setting (decision 281), if any; null once it is locked by a revaluation is still a currency. */
  fxCurrency?: string | null;
  fxNote?: string | null;
  /** Only the most recent posted revaluation can be reversed; null when there is none to reverse. */
  fxLatestRevaluationId?: string | null;
  /** Fixed assets this (borrowed) loan can be linked to as the thing it financed (Step 01 #19). */
  assets?: readonly FinancingOption[];
  currentAssetId?: string | null;
}) {
  const common = { idName: "loan_id", id: loanId, next };
  return (
    <>
      {status === "draft" ? (
        <>
          <CommandForm
            {...common}
            action={activateLoanAction}
            openLabel="Aktifkan Pinjaman"
            submitLabel="Aktifkan"
            primary
          >
            <DateField
              label={lent ? "Tanggal Uang Diberikan" : "Tanggal Uang Diterima"}
              today={today}
            />
            <AccountField
              label={lent ? "Uang Keluar dari Rekening" : "Uang Masuk ke Rekening"}
              accounts={accounts}
            />
          </CommandForm>
          <CommandForm
            {...common}
            action={cancelLoanAction}
            openLabel="Batalkan Pinjaman"
            submitLabel="Batalkan Pinjaman"
          >
            <ReasonField />
          </CommandForm>
        </>
      ) : null}
      {status === "active" ? (
        <>
          <CommandForm
            {...common}
            action={repayLoanAction}
            openLabel={lent ? "Catat Cicilan Diterima" : "Bayar Cicilan"}
            submitLabel="Simpan Pembayaran"
            primary
          >
            <DateField label="Tanggal Bayar" today={today} />
            <AccountField
              label={lent ? "Uang Masuk ke Rekening" : "Dibayar dari Rekening"}
              accounts={accounts}
            />
            <MoneyField name="principal" label="Pokok" defaultValue="0" />
            <MoneyField name="interest" label="Bunga" defaultValue="0" />
            <MoneyField name="fee" label="Biaya / Denda" defaultValue="0" />
            <label>
              Catatan (wajib jika ada bunga atau biaya)
              <input name="note" maxLength={1000} />
            </label>
          </CommandForm>
          <CommandForm
            {...common}
            action={writeOffLoanAction}
            openLabel="Hapus Sisa Pinjaman"
            submitLabel="Simpan Penghapusan"
          >
            <DateField label="Tanggal" today={today} />
            <MoneyField name="amount" label="Jumlah Dihapus" defaultValue={outstanding} required />
            <ReasonField />
            <p className="hint">Perlu verifikasi ulang sebelum menyimpan.</p>
          </CommandForm>
          <CommandForm
            {...common}
            action={restructureLoanAction}
            openLabel="Restrukturisasi Jadwal"
            submitLabel="Simpan Jadwal Baru"
          >
            <DateField label="Tanggal Efektif" today={today} />
            <label>
              Bunga per Tahun (%)
              <input name="rate_percent" inputMode="decimal" defaultValue="0" />
            </label>
            <label>
              Cara Hitung Cicilan
              <select name="method" defaultValue="annuity">
                <option value="annuity">Anuitas (cicilan sama tiap kali)</option>
                <option value="flat">Flat (pokok dan bunga tetap)</option>
                <option value="interest_only">Bunga saja, pokok di akhir</option>
              </select>
            </label>
            <label>
              Jumlah Cicilan (sisa jadwal baru)
              <input
                name="installments"
                type="number"
                min={1}
                max={600}
                required
                defaultValue={12}
              />
            </label>
            <label>
              Jarak Antar Cicilan
              <select name="step_months" defaultValue="1">
                <option value="1">Tiap bulan</option>
                <option value="3">Tiap 3 bulan</option>
                <option value="6">Tiap 6 bulan</option>
                <option value="12">Tiap tahun</option>
              </select>
            </label>
            <label>
              Tanggal Cicilan Pertama (jadwal baru)
              <input type="date" name="first_due" required />
            </label>
            <ReasonField />
            <p className="hint">
              Jadwal lama berhenti di tanggal efektif; pembayaran yang sudah tercatat tidak berubah.
              Perlu verifikasi ulang sebelum menyimpan.
            </p>
          </CommandForm>
        </>
      ) : null}
      {!lent && status !== "cancelled" && assets && assets.length > 0 ? (
        <CommandForm
          {...common}
          action={setLoanAssetAction}
          openLabel={currentAssetId ? "Ubah Tautan Aset" : "Tautkan ke Aset"}
          submitLabel="Simpan Tautan"
        >
          <label>
            Aset yang Dibiayai Pinjaman Ini
            <select name="asset_id" defaultValue={currentAssetId ?? ""}>
              <option value="">(tidak ditautkan)</option>
              {assets.map((asset) => (
                <option key={asset.id} value={asset.id}>
                  {asset.label}
                </option>
              ))}
            </select>
          </label>
          <p className="hint">Tautan saja -- tidak memengaruhi pencatatan pinjaman atau aset.</p>
        </CommandForm>
      ) : null}
      {payments.length > 0 && (status === "active" || status === "closed") ? (
        <CommandForm
          {...common}
          action={reverseLoanPaymentAction}
          openLabel="Batalkan Pembayaran"
          submitLabel="Batalkan Pembayaran"
        >
          <PickField
            name="payment_id"
            label="Pembayaran"
            placeholder="Pilih pembayaran"
            options={payments}
          />
          <DateField label="Tanggal Pembatalan" today={today} />
          <ReasonField />
        </CommandForm>
      ) : null}
      {status === "active" || status === "closed" ? (
        <CommandForm
          {...common}
          action={setLoanFxTermsAction}
          openLabel={fxCurrency ? "Ubah Mata Uang Pinjaman" : "Atur Mata Uang Asing"}
          submitLabel="Simpan"
        >
          <label>
            Kode Mata Uang (ISO 4217, 3 huruf)
            <input
              name="currency"
              required
              minLength={3}
              maxLength={3}
              style={{ textTransform: "uppercase" }}
              defaultValue={fxCurrency ?? ""}
              placeholder="USD"
            />
          </label>
          <label>
            Catatan
            <input name="note" maxLength={500} defaultValue={fxNote ?? ""} />
          </label>
          {fxCurrency ? (
            <p className="hint">
              Mata uang terkunci setelah ada revaluasi; nilai yang sama tetap bisa disimpan untuk
              memperbarui catatan.
            </p>
          ) : null}
        </CommandForm>
      ) : null}
      {status === "active" && fxCurrency ? (
        <CommandForm
          {...common}
          action={revalueLoanFxAction}
          openLabel="Catat Revaluasi Kurs"
          submitLabel="Simpan Revaluasi"
        >
          <label>
            Tanggal (akhir bulan)
            <input type="date" name="date" required defaultValue={today} max={today} />
          </label>
          <MoneyField name="fc_outstanding" label={`Saldo Outstanding (${fxCurrency})`} required />
          <MoneyField name="rate" label={`Kurs (Rp per 1 ${fxCurrency})`} required />
          <label>
            Catatan
            <input name="note" maxLength={1000} placeholder="Mis. kurs tengah BI" />
          </label>
          <p className="hint">
            Selisih terhadap saldo outstanding saat ini akan diposting otomatis ke Laba/Rugi Selisih
            Kurs.
          </p>
        </CommandForm>
      ) : null}
      {fxLatestRevaluationId ? (
        <CommandForm
          {...common}
          action={reverseLoanFxRevaluationAction}
          openLabel="Batalkan Revaluasi Terakhir"
          submitLabel="Batalkan Revaluasi"
        >
          <input type="hidden" name="revaluation_id" value={fxLatestRevaluationId} />
          <DateField label="Tanggal Pembatalan" today={today} />
          <ReasonField />
        </CommandForm>
      ) : null}
    </>
  );
}

// ================================================================ obligation detail commands
export function ObligationActionsPanel({
  obligationId,
  receivable,
  open,
  canVoid,
  outstanding,
  settlements,
  accounts,
  today,
  next,
}: {
  obligationId: string;
  receivable: boolean;
  /** Status `open`: settle and write off are accepted. */
  open: boolean;
  /** Open, entered by hand and without an active settlement. */
  canVoid: boolean;
  outstanding: string;
  settlements: readonly FinancingOption[];
  accounts: readonly FinancingOption[];
  today: string;
  next: string;
}) {
  const common = { idName: "obligation_id", id: obligationId, next };
  return (
    <>
      {open ? (
        <>
          <CommandForm
            {...common}
            action={settleObligationAction}
            openLabel={receivable ? "Catat Penerimaan" : "Catat Pembayaran"}
            submitLabel="Simpan Pelunasan"
            primary
          >
            <DateField label="Tanggal" today={today} />
            <AccountField
              label={receivable ? "Uang Masuk ke Rekening" : "Dibayar dari Rekening"}
              accounts={accounts}
            />
            <MoneyField name="principal" label="Jumlah Pokok" defaultValue={outstanding} required />
            <MoneyField name="interest" label="Bunga (jika ada)" defaultValue="0" />
            <MoneyField name="fee" label="Biaya (jika ada)" defaultValue="0" />
            <label>
              Catatan (wajib jika ada bunga atau biaya)
              <input name="note" maxLength={1000} />
            </label>
          </CommandForm>
          <CommandForm
            {...common}
            action={writeOffObligationAction}
            openLabel="Hapus Sisa"
            submitLabel="Simpan Penghapusan"
          >
            <DateField label="Tanggal" today={today} />
            <MoneyField name="amount" label="Jumlah Dihapus" defaultValue={outstanding} required />
            <ReasonField />
            <p className="hint">Perlu verifikasi ulang sebelum menyimpan.</p>
          </CommandForm>
        </>
      ) : null}
      {canVoid ? (
        <CommandForm
          {...common}
          action={voidObligationAction}
          openLabel="Batalkan (Salah Catat)"
          submitLabel="Batalkan"
        >
          <DateField label="Tanggal Pembatalan" today={today} />
          <ReasonField />
        </CommandForm>
      ) : null}
      {settlements.length > 0 ? (
        <CommandForm
          {...common}
          action={reverseObligationSettlementAction}
          openLabel="Batalkan Pelunasan"
          submitLabel="Batalkan Pelunasan"
        >
          <PickField
            name="settlement_id"
            label="Pelunasan"
            placeholder="Pilih pelunasan"
            options={settlements}
          />
          <DateField label="Tanggal Pembatalan" today={today} />
          <ReasonField />
        </CommandForm>
      ) : null}
    </>
  );
}

// ================================================================ equity detail commands
export function EquityActionsPanel({
  eventId,
  status,
  isDividend,
  needsApproval,
  canConfirmOrReverse,
  outstanding,
  payments,
  accounts,
  today,
  next,
}: {
  eventId: string;
  status: "draft" | "confirmed" | "reversed" | "cancelled";
  isDividend: boolean;
  /** A capital return or a dividend: confirm and reverse need approval and a recent re-verification. */
  needsApproval: boolean;
  canConfirmOrReverse: boolean;
  /** For a confirmed dividend: what is declared but not yet paid. */
  outstanding: string | null;
  payments: readonly FinancingOption[];
  accounts: readonly FinancingOption[];
  today: string;
  next: string;
}) {
  const common = { idName: "event_id", id: eventId, next };
  const stepUpHint = needsApproval ? (
    <p className="hint">Perlu verifikasi ulang sebelum menyimpan.</p>
  ) : null;
  return (
    <>
      {status === "draft" ? (
        <>
          {canConfirmOrReverse ? (
            <CommandForm
              {...common}
              action={confirmEquityEventAction}
              openLabel="Konfirmasi"
              submitLabel="Konfirmasi dan Catat"
              primary
            >
              {isDividend ? (
                <p className="hint">Dividen diumumkan dulu. Uang dicatat saat dividen dibayar.</p>
              ) : (
                <AccountField label="Rekening Kas/Bank" accounts={accounts} />
              )}
              {stepUpHint}
            </CommandForm>
          ) : null}
          <CommandForm
            {...common}
            action={cancelEquityEventAction}
            openLabel="Batalkan Draf"
            submitLabel="Batalkan Draf"
          >
            <ReasonField />
          </CommandForm>
        </>
      ) : null}
      {status === "confirmed" && isDividend && outstanding !== null && Number(outstanding) > 0 ? (
        <CommandForm
          {...common}
          action={payDividendAction}
          openLabel="Bayar Dividen"
          submitLabel="Simpan Pembayaran"
          primary
        >
          <DateField label="Tanggal Bayar" today={today} />
          <AccountField label="Dibayar dari Rekening" accounts={accounts} />
          <MoneyField name="amount" label="Jumlah" defaultValue={outstanding} required />
          <label>
            Catatan (opsional)
            <input name="note" maxLength={1000} />
          </label>
        </CommandForm>
      ) : null}
      {status === "confirmed" && canConfirmOrReverse && payments.length === 0 ? (
        <CommandForm
          {...common}
          action={reverseEquityEventAction}
          openLabel="Balik (Salah Catat)"
          submitLabel="Balik Pencatatan"
        >
          <DateField label="Tanggal Pembalikan" today={today} />
          <ReasonField />
          {stepUpHint}
        </CommandForm>
      ) : null}
      {status === "confirmed" && payments.length > 0 ? (
        <CommandForm
          {...common}
          action={reverseDividendPaymentAction}
          openLabel="Batalkan Pembayaran Dividen"
          submitLabel="Batalkan Pembayaran"
        >
          <PickField
            name="payment_id"
            label="Pembayaran"
            placeholder="Pilih pembayaran"
            options={payments}
          />
          <DateField label="Tanggal Pembatalan" today={today} />
          <ReasonField />
          <p className="hint">Perlu verifikasi ulang sebelum menyimpan.</p>
        </CommandForm>
      ) : null}
    </>
  );
}
