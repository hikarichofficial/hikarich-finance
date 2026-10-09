"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { SuggestTextInput } from "@/features/shared/SuggestTextInput";
import { createContext, useContext, useState, type ReactNode } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import {
  activateLoanAction,
  cancelEquityEventAction,
  cancelLoanAction,
  changeLoanRateAction,
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
import { formatMoney } from "@/domain/money/format";
import { sumNextInstallments, type UnpaidInstallment } from "@/domain/financing/financing";

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

/**
 * Only one command form is open at a time on a loan's Detail screen: the panel keeps the label of the open one
 * (a form outside a panel falls back to its own state). A form closes after it saves, so the next time it opens
 * it is fresh instead of showing the last values.
 */
const OpenCommandContext = createContext<{
  active: string | null;
  setActive: (label: string | null) => void;
} | null>(null);

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
  const panel = useContext(OpenCommandContext);
  const [localOpen, setLocalOpen] = useState(false);
  // The result the form had when it was opened: a newer "ok" result means it saved, so it closes again.
  const [openedWith, setOpenedWith] = useState(state);
  const wanted = panel ? panel.active === openLabel : localOpen;
  const saved = state.status === "ok" && state !== openedWith;
  const open = wanted && !saved;
  const openForm = () => {
    setOpenedWith(state);
    if (panel) panel.setActive(openLabel);
    else setLocalOpen(true);
  };

  if (!open) {
    return (
      <button
        type="button"
        className={primary ? "btn-primary" : "btn-secondary"}
        onClick={openForm}
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

/** The counterparty of a loan, an obligation or an equity event: a name usually already on file (Contacts and
 * earlier records) but free to type for one that is not -- "boleh diklik dan pilih, atau tetap bisa ketik baru"
 * (OWNER, 5 October 2026). Since 6 October 2026 it is a type-and-pick field like the customer on an invoice: the
 * list appears only once typing starts, narrows as more is typed, and offers "+ Tambah ... baru" for a new name. */
function PartyField({
  label,
  knownParties,
}: {
  label: ReactNode;
  knownParties: readonly string[];
}) {
  return (
    <SuggestTextInput
      label={label}
      name="counterparty"
      suggestions={knownParties}
      noun="pihak"
      required
      maxLength={200}
    />
  );
}

// ================================================================ create forms
/** Bunga Berjenjang (decisions 374/375): later rates, each from a year of the schedule, up to 20 rows. */
function RateStepsField({ hint }: { hint: string }) {
  const [rows, setRows] = useState(0);
  return (
    <fieldset>
      <legend>Bunga berikutnya (opsional)</legend>
      <p className="hint">{hint}</p>
      {Array.from({ length: rows }, (_, n) => (
        <div key={n} className="form-row">
          <label>
            Mulai tahun ke-
            <input
              type="number"
              name={`step_year_${n}`}
              min={2}
              max={50}
              step={1}
              inputMode="numeric"
              required
            />
          </label>
          <label>
            Bunga per tahun (%)
            <input name={`step_rate_${n}`} inputMode="decimal" required />
          </label>
        </div>
      ))}
      <div className="form-row">
        {rows < 20 ? (
          <button type="button" className="btn-ghost" onClick={() => setRows(rows + 1)}>
            + Tambah tahap bunga
          </button>
        ) : null}
        {rows > 0 ? (
          <button type="button" className="btn-ghost" onClick={() => setRows(rows - 1)}>
            Hapus tahap terakhir
          </button>
        ) : null}
      </div>
    </fieldset>
  );
}

export function LoanCreateForm({
  entity,
  isCompany,
  today,
  knownParties,
  knownPurposes = [],
}: {
  entity: string | undefined;
  isCompany: boolean;
  today: string;
  knownParties: readonly string[];
  /** Purposes written on earlier loans, obligations and equity events, offered while typing. */
  knownPurposes?: readonly string[];
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
        label={direction === "borrowed" ? "Pemberi Pinjaman" : "Peminjam"}
        knownParties={knownParties}
      />
      <SuggestTextInput
        label="Tujuan Pinjaman"
        name="purpose"
        suggestions={knownPurposes}
        noun="keterangan"
        required
        maxLength={500}
      />
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
      <RateStepsField hint="Untuk bunga yang berubah, misalnya pinjaman 10 tahun: tahun ke-1 sampai ke-3 memakai bunga di atas, mulai tahun ke-4 bunganya lain. Isi tahun mulai dan bunganya. Tahun dihitung dari Tanggal Cicilan Pertama; cicilan anuitas dihitung ulang dari sisa pokok." />
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
  knownPurposes = [],
}: {
  entity: string | undefined;
  kind: "receivable" | "payable";
  accounts: readonly FinancingOption[];
  today: string;
  knownParties: readonly string[];
  /** Purposes written on earlier loans, obligations and equity events, offered while typing. */
  knownPurposes?: readonly string[];
}) {
  const [state, action, pending] = useActionState(createObligationAction, idleFinancingActionState);
  const actionForm = usePreservingForm(action, state);
  const receivable = kind === "receivable";

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="kind" value={kind} />
      <PartyField
        label={receivable ? "Siapa yang Berutang ke Kita" : "Kepada Siapa Kita Berutang"}
        knownParties={knownParties}
      />
      <SuggestTextInput
        label="Keterangan"
        name="purpose"
        suggestions={knownPurposes}
        noun="keterangan"
        required
        maxLength={500}
      />
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
  knownPurposes = [],
}: {
  entity: string | undefined;
  kinds: readonly FinancingOption[];
  today: string;
  knownParties: readonly string[];
  /** Purposes written on earlier loans, obligations and equity events, offered while typing. */
  knownPurposes?: readonly string[];
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
      <PartyField label="Nama Pemilik / Pihak" knownParties={knownParties} />
      <SuggestTextInput
        label="Keterangan"
        name="purpose"
        suggestions={knownPurposes}
        noun="keterangan"
        required
        maxLength={500}
      />
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

/**
 * What a loan payment pays (decision 376): the next N instalments straight from the schedule (the amounts are not
 * typed), a partial early repayment of the principal, or amounts typed by hand for what the schedule does not cover.
 */
function RepayFields({
  lent,
  unpaid,
  currency,
  canPrepay,
}: {
  lent: boolean;
  unpaid: readonly UnpaidInstallment[];
  currency: string;
  canPrepay: boolean;
}) {
  const [mode, setMode] = useState<"installments" | "prepay" | "custom">(
    unpaid.length > 0 ? "installments" : "custom",
  );
  const [count, setCount] = useState(1);
  const safeCount = Math.min(Math.max(1, count || 1), Math.max(1, unpaid.length));
  const totals = sumNextInstallments(unpaid, safeCount);
  const taken = [...unpaid].sort((a, b) => a.seq - b.seq).slice(0, totals.count);
  const first = taken[0]?.seq;
  const last = taken[taken.length - 1]?.seq;
  return (
    <>
      <label>
        {lent ? "Yang diterima" : "Yang dibayar"}
        <select name="mode" value={mode} onChange={(e) => setMode(e.target.value as typeof mode)}>
          {unpaid.length > 0 ? <option value="installments">Cicilan sesuai jadwal</option> : null}
          {canPrepay ? (
            <option value="prepay">Pelunasan dipercepat (bayar sebagian pokok)</option>
          ) : null}
          <option value="custom">Jumlah lain (isi sendiri)</option>
        </select>
      </label>
      {mode === "installments" ? (
        <>
          <label>
            Jumlah cicilan yang {lent ? "diterima" : "dibayar"} (1 sampai {unpaid.length})
            <input
              type="number"
              name="count"
              min={1}
              max={unpaid.length}
              step={1}
              inputMode="numeric"
              required
              value={count}
              onChange={(e) => setCount(Number(e.target.value))}
            />
          </label>
          <dl className="hint">
            <div>
              <dt>
                {first === last ? `Cicilan ke-${first}` : `Cicilan ke-${first} sampai ke-${last}`}
              </dt>
              <dd>
                Pokok {formatMoney(totals.principal, currency)}, bunga{" "}
                {formatMoney(totals.interest, currency)}
                {Number(totals.fee) > 0 ? `, biaya ${formatMoney(totals.fee, currency)}` : ""}
              </dd>
            </div>
            <div>
              <dt>Total</dt>
              <dd>{formatMoney(totals.total, currency)}</dd>
            </div>
          </dl>
          <p className="hint">
            Jumlahnya diambil dari jadwal, jadi tidak perlu diketik. Cicilan yang terlambat ikut
            terhitung lebih dulu.
          </p>
        </>
      ) : null}
      {mode === "prepay" ? (
        <>
          <MoneyField name="prepay_principal" label="Pokok yang dibayar sekarang" required />
          <label>
            Setelah itu
            <select name="prepay_mode" defaultValue="shorten">
              <option value="shorten">Persingkat jangka waktu (cicilan tetap sama)</option>
              <option value="reduce">Perkecil cicilan (jangka waktu tetap)</option>
            </select>
          </label>
          <p className="hint">
            Jadwal sisa dihitung ulang dari sisa pokok. Bunga yang sudah jatuh tempo dibayar lewat
            Cicilan sesuai jadwal. Setelah jadwal berubah, pembayaran ini tidak bisa dibatalkan
            lagi.
          </p>
        </>
      ) : null}
      {mode === "custom" ? (
        <>
          <MoneyField name="principal" label="Pokok" defaultValue="0" />
          <MoneyField name="interest" label="Bunga" defaultValue="0" />
          <MoneyField name="fee" label="Biaya / Denda" defaultValue="0" />
        </>
      ) : null}
      <label>
        {mode === "custom"
          ? "Catatan (wajib bila ada biaya atau denda di luar jadwal)"
          : "Catatan (opsional)"}
        <input name="note" maxLength={1000} />
      </label>
    </>
  );
}

/**
 * The rate a schedule stores ("12.0000") shown the way someone types a percent ("12"), so the
 * Restrukturisasi form opens on the loan's own rate instead of 0 (OWNER, 9 October 2026).
 */
function tidyRatePercent(rate: string | null | undefined): string {
  if (!rate) return "0";
  const trimmed = rate.includes(".") ? rate.replace(/0+$/, "").replace(/\.$/, "") : rate;
  return trimmed === "" || trimmed === "-" ? "0" : trimmed;
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
  unpaid,
  currency,
  canPrepay,
  currentRate,
  currentMethod,
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
  /** What is still owed on each instalment that is not fully paid (decision 376). */
  unpaid: readonly UnpaidInstallment[];
  currency: string;
  /** A generated (not manual) schedule can be recalculated after a partial early repayment. */
  canPrepay: boolean;
  /** The rate the active schedule runs on, so Restrukturisasi starts from it instead of 0 (OWNER, 9 October 2026). */
  currentRate?: string | null;
  /** The way the active schedule is calculated, so Restrukturisasi starts from it. */
  currentMethod?: "annuity" | "flat" | "interest_only" | "manual" | null;
}) {
  const common = { idName: "loan_id", id: loanId, next };
  const [active, setActive] = useState<string | null>(null);
  const currentRatePercent = tidyRatePercent(currentRate);
  // "manual" has no generated schedule to copy: Restrukturisasi always writes a generated one.
  const currentMethod_ =
    currentMethod && currentMethod !== "manual" ? currentMethod : ("annuity" as const);
  return (
    <OpenCommandContext.Provider value={{ active, setActive }}>
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
            <RepayFields lent={lent} unpaid={unpaid} currency={currency} canPrepay={canPrepay} />
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
              <input name="rate_percent" inputMode="decimal" defaultValue={currentRatePercent} />
            </label>
            <label>
              Cara Hitung Cicilan
              <select name="method" defaultValue={currentMethod_}>
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
            <RateStepsField hint="Bunga berikutnya untuk jadwal baru ini, jika sudah diketahui. Tahun dihitung dari Tanggal Cicilan Pertama jadwal baru." />
            <ReasonField />
            <p className="hint">
              Untuk pinjaman yang sulit dibayar: jadwal diganti mulai tanggal efektif dengan cara
              hitung, bunga, dan jumlah cicilan yang baru, dari sisa pokok. Jadwal lama tersimpan
              sebagai riwayat; pembayaran sebelumnya tidak berubah dan tidak bisa dibatalkan lagi.
              Kalau yang berubah hanya bunganya, pakai Ubah Bunga. Perlu verifikasi ulang.
            </p>
          </CommandForm>
          <CommandForm
            {...common}
            action={changeLoanRateAction}
            openLabel="Ubah Bunga"
            submitLabel="Simpan Bunga Baru"
          >
            <label>
              Bunga Baru Berlaku Mulai
              <input type="date" name="rate_from" required defaultValue={today} />
            </label>
            <label>
              Bunga Baru per Tahun (%)
              <input name="new_rate" inputMode="decimal" required />
            </label>
            <ReasonField />
            <p className="hint">
              Boleh tanggal yang akan datang. Cicilan yang jatuh tempo sebelum tanggal itu tetap;
              cicilan mulai tanggal itu dihitung ulang dari sisa pokok dengan jangka waktu yang
              sama. Jadwal lama tersimpan sebagai riwayat, dan pembayaran yang dicatat sebelum
              perubahan tidak bisa dibatalkan lagi setelahnya. Perlu verifikasi ulang.
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
    </OpenCommandContext.Provider>
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
