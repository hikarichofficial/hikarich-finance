"use client";

import { useCallback, useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { MoneyInput } from "@/features/shared/MoneyInput";
import {
  openingFormProblems,
  originProblem,
  suggestedAccumulated,
} from "@/domain/assets/assetFormGuide";
import { formatMoney } from "@/domain/money/format";
import { loadOpeningAssetAction, type AssetActionState } from "./assetActions";
import {
  DepreciationFields,
  InServiceDateField,
  type AssetAccountOption,
  type DepreciationFigures,
} from "./AssetForms";
import { AssetOriginFields, FieldProblem, FormProblem, invalidClass } from "./AssetFormHelp";

const idleState: AssetActionState = { status: "idle" };

/**
 * "Aset yang Sudah Dimiliki": one asset the business owned before it started using this app. The person
 * gives what it cost, when it was bought, whether it was new or used and the year it was made; the
 * depreciation figures are worked out from the kind of asset, and the database plans the months that remain.
 * A field that is wrong turns red with the way out written under it, whether the form noticed it or the
 * database refused it (decision 343).
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
  const [fxCurrency, setFxCurrency] = useState("");
  const [accountId, setAccountId] = useState("");
  const [acquisitionDate, setAcquisitionDate] = useState("");
  const [serviceDate, setServiceDate] = useState("");
  const [sameDate, setSameDate] = useState(true);
  const [cutoverDate, setCutoverDate] = useState(today);
  const [accumulated, setAccumulated] = useState("");
  const [condition, setCondition] = useState<"new" | "used">("new");
  const [year, setYear] = useState("");
  const [figures, setFigures] = useState<DepreciationFigures>({
    method: "",
    life: "",
    residual: "",
  });
  const onFigures = useCallback((next: DepreciationFigures) => setFigures(next), []);

  const effectiveService = sameDate ? acquisitionDate : serviceDate;
  const accountCode = accounts.find((account) => account.id === accountId)?.code ?? null;
  const own = openingFormProblems({
    cost,
    residual: figures.residual,
    accumulated,
    acquisitionDate,
    serviceDate: effectiveService,
    cutoverDate,
  });
  const yearProblem = originProblem(condition, year, effectiveService);
  // What the database last refused, marked on its field unless the form already has something to say there.
  const refused: Record<string, string> =
    state.status === "error" && state.field && state.fix ? { [state.field]: state.fix } : {};
  const problems: Record<string, string> = { ...refused, ...own };
  if (yearProblem) problems.manufacture_year = yearProblem;
  const depreciated = figures.method !== "none" && figures.method !== "";
  const suggestion = depreciated
    ? suggestedAccumulated(cost, figures.residual, figures.life, effectiveService, cutoverDate)
    : null;

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
      <label className={invalidClass(problems.cost_account)}>
        Akun Aset Tetap
        <select
          name="cost_account"
          required
          value={accountId}
          onChange={(event) => setAccountId(event.target.value)}
        >
          <option value="" disabled>
            Pilih akun
          </option>
          {accounts.map((account) => (
            <option key={account.id} value={account.id}>
              {account.label}
            </option>
          ))}
        </select>
        <FieldProblem message={problems.cost_account} />
      </label>
      <label>
        Harga Perolehan
        <MoneyInput name="cost" required value={cost} onValueChange={setCost} />
      </label>
      <label className={invalidClass(problems.acquisition_date)}>
        Tanggal Beli
        <input
          type="date"
          name="acquisition_date"
          required
          max={today}
          value={acquisitionDate}
          onChange={(event) => setAcquisitionDate(event.target.value)}
        />
        <FieldProblem message={problems.acquisition_date} />
      </label>
      <InServiceDateField
        acquisitionDate={acquisitionDate}
        today={today}
        value={serviceDate}
        onChange={setServiceDate}
        same={sameDate}
        onSameChange={setSameDate}
        problem={problems.in_service_date}
      />
      <label className={invalidClass(problems.cutover_date)}>
        Tanggal Mulai Dicatat di Aplikasi Ini
        <input
          type="date"
          name="cutover_date"
          required
          max={today}
          value={cutoverDate}
          onChange={(event) => setCutoverDate(event.target.value)}
        />
        <FieldProblem message={problems.cutover_date} />
      </label>
      <AssetOriginFields
        condition={condition}
        year={year}
        onConditionChange={setCondition}
        onYearChange={setYear}
        yearProblem={problems.manufacture_year}
      />
      <DepreciationFields
        depreciable={depreciable}
        name={name}
        cost={cost}
        currency={currency}
        accountCode={accountCode}
        condition={condition}
        manufactureYear={year}
        serviceDate={effectiveService}
        problems={problems}
        onFigures={onFigures}
      />
      {depreciated ? (
        <label className={invalidClass(problems.accumulated)}>
          Penyusutan yang Sudah Dicatat sampai Tanggal Mulai Dicatat (opsional)
          <MoneyInput
            name="accumulated"
            placeholder="0"
            value={accumulated}
            onValueChange={setAccumulated}
          />
          <FieldProblem message={problems.accumulated} />
          {suggestion !== null ? (
            <span className="hint">
              Perkiraan dari umur manfaat: {formatMoney(String(suggestion), currency)}.{" "}
              <button
                type="button"
                className="btn-secondary"
                onClick={() => setAccumulated(String(suggestion))}
              >
                Isi otomatis
              </button>
            </span>
          ) : (
            <span className="hint">
              Isi tanggal dan harga perolehan agar perkiraannya muncul. Kosongkan bila tidak tahu.
            </span>
          )}
        </label>
      ) : (
        <input type="hidden" name="accumulated" value="" />
      )}
      <label>
        Mata Uang Asal (opsional, kalau aset dibeli dalam mata uang asing)
        <input
          name="fx_currency"
          maxLength={3}
          placeholder={`kosongkan jika dibeli dalam ${currency}`}
          value={fxCurrency}
          onChange={(event) => setFxCurrency(event.target.value.toUpperCase())}
        />
      </label>
      {fxCurrency ? (
        <>
          <label>
            Harga Perolehan dalam {fxCurrency}
            <input name="fx_cost" required inputMode="decimal" />
          </label>
          <label className={invalidClass(problems.fx_rate)}>
            Kurs pada Tanggal Beli ({fxCurrency} ke {currency})
            <input name="fx_rate" required inputMode="decimal" />
            <FieldProblem message={problems.fx_rate} />
          </label>
          <p className="hint">
            Dicatat hanya sebagai catatan; nilai di atas (dalam {currency}) tetap dipakai untuk
            akuntansi dan tidak dihitung ulang.
          </p>
        </>
      ) : null}
      <label>
        Nomor Seri (opsional)
        <input name="serial_number" maxLength={100} />
      </label>
      <label>
        Lokasi (opsional)
        <input name="location" maxLength={200} />
      </label>
      <FormProblem state={state} next={next} />
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Aset"}
      </button>
    </form>
  );
}
