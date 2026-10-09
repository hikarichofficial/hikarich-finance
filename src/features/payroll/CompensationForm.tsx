"use client";

import { useMemo, useState } from "react";
import { Decimal } from "@/domain/money/decimal";
import { formatMoney } from "@/domain/money/format";
import {
  COMPONENT_PRESETS,
  componentCode,
  findPreset,
  uniqueComponentCode,
  type ComponentKind,
  type ComponentPreset,
} from "@/domain/payroll/compensationPresets";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { formatShortDate } from "./format";
import { PayrollToggleForm } from "./PayrollToggleForm";
import { setCompensationAction } from "./payrollActions";

export interface CompensationRowView {
  component: string;
  kind: string;
  label: string;
  amount: string;
  taxable: boolean;
  bpjsBase: boolean;
  /** When this component started, shown on its row so the read-only table above is not needed as well. */
  effectiveFrom?: string;
}

interface Row {
  id: number;
  /** The saved code of an existing component (kept as is, so the same component is replaced), "" for a new one. */
  savedCode: string;
  label: string;
  kind: ComponentKind;
  amount: string;
  taxable: boolean;
  bpjsBase: boolean;
  /** True once the person changed a flag by hand: a later change of the name then leaves the flags alone. */
  flagsTouched: boolean;
  /** Empty for a row that is not saved yet. */
  effectiveFrom: string;
}

function fromPreset(id: number, preset: ComponentPreset): Row {
  return {
    id,
    savedCode: "",
    label: preset.label,
    kind: preset.kind,
    amount: "",
    taxable: preset.taxable,
    bpjsBase: preset.bpjsBase,
    flagsTouched: false,
    effectiveFrom: "",
  };
}

let rowSequence = 0;

/** A key for a row that stays the same while rows above it are added or removed. */
function newId(): number {
  rowSequence += 1;
  return rowSequence;
}

function toNumber(text: string): Decimal {
  return Decimal.tryParse(text === "" ? "0" : text) ?? Decimal.zero();
}

/**
 * Salary components from a date (`employee_set_compensation`, `payroll.compensation_edit`). Each component is
 * effective-dated on its own: a row saved here replaces that component from the date given, and a component
 * left out keeps its current amount.
 *
 * OWNER, 9 October 2026: the old form asked for a name, a code, a kind and two flags per row, all typed by
 * hand. Now a name is picked from a list or typed freely, the code is made from it, a preset fills the kind
 * and the two tax/BPJS flags, and a running total is shown. The fields posted to the server are the same as
 * before (`label_i`, `component_i`, `kind_i`, `amount_i`, `taxable_i`, `bpjs_base_i`, `row_count`).
 */
export function CompensationForm({
  employeeId,
  current,
  today,
  currency = "IDR",
}: {
  employeeId: string;
  current: readonly CompensationRowView[];
  today: string;
  currency?: string;
}) {
  const [rows, setRows] = useState<readonly Row[]>(() => {
    if (current.length > 0) {
      return current.map((c): Row => ({
        id: newId(),
        savedCode: c.component,
        label: c.label,
        kind: c.kind === "deduction" ? "deduction" : "earning",
        amount: c.amount,
        taxable: c.taxable,
        bpjsBase: c.bpjsBase,
        flagsTouched: true,
        effectiveFrom: c.effectiveFrom ?? "",
      }));
    }
    return [fromPreset(newId(), COMPONENT_PRESETS[0])];
  });

  // The code each row will post: its saved code, else made from the name, never the same as another row's.
  const codes = useMemo(() => {
    const taken = new Set<string>();
    for (const row of rows) if (row.savedCode) taken.add(row.savedCode);
    return rows.map((row) => {
      if (row.savedCode) return row.savedCode;
      const code = uniqueComponentCode(componentCode(row.label), taken);
      if (code) taken.add(code);
      return code;
    });
  }, [rows]);

  const usedLabels = new Set(rows.map((row) => row.label.trim().toLowerCase()));
  const suggestions = COMPONENT_PRESETS.filter((p) => !usedLabels.has(p.label.toLowerCase()));

  const totals = useMemo(() => {
    let earn = Decimal.zero();
    let deduct = Decimal.zero();
    for (const row of rows) {
      const amount = toNumber(row.amount);
      if (row.kind === "earning") earn = earn.add(amount);
      else deduct = deduct.add(amount);
    }
    return { earn, deduct, net: earn.sub(deduct) };
  }, [rows]);

  function update(id: number, patch: Partial<Row>) {
    setRows((previous) => previous.map((row) => (row.id === id ? { ...row, ...patch } : row)));
  }

  function rename(id: number, label: string) {
    setRows((previous) =>
      previous.map((row) => {
        if (row.id !== id) return row;
        const preset = row.flagsTouched || row.savedCode ? null : findPreset(label);
        return preset
          ? {
              ...row,
              label,
              kind: preset.kind,
              taxable: preset.taxable,
              bpjsBase: preset.bpjsBase,
            }
          : { ...row, label };
      }),
    );
  }

  function setKind(id: number, kind: ComponentKind) {
    setRows((previous) =>
      previous.map((row) =>
        row.id === id
          ? {
              ...row,
              kind,
              flagsTouched: true,
              // A deduction does not lower the PPh 21 base by default and is never part of the BPJS wage.
              taxable: kind === "earning",
              bpjsBase: kind === "earning" ? row.bpjsBase : false,
            }
          : row,
      ),
    );
  }

  const countPosted = rows.filter((row) => row.label.trim() !== "" || row.amount !== "").length;
  // The potongan note is only worth the reader's time once there is a potongan on the form.
  const hasDeduction = rows.some((row) => row.kind === "deduction");

  return (
    <PayrollToggleForm
      action={setCompensationAction}
      openLabel="Atur Gaji & Komponen"
      submitLabel="Simpan Gaji & Komponen"
      alwaysOpen
      wide
    >
      <input type="hidden" name="employee_id" value={employeeId} />
      <input type="hidden" name="row_count" value={rows.length} />

      <label className="comp-date">
        Berlaku mulai
        <input type="date" name="effective_from" required defaultValue={today} />
      </label>
      <p className="hint">
        Isi komponen yang baru atau berubah saja; komponen lain tetap seperti sebelumnya. Pilih nama
        dari daftar atau ketik sendiri; kode dibuat otomatis.
      </p>

      <datalist id={`comp-presets-${employeeId}`}>
        {COMPONENT_PRESETS.map((preset) => (
          <option key={preset.label} value={preset.label}>
            {preset.hint}
          </option>
        ))}
      </datalist>

      <div className="comp-list">
        {rows.map((row, index) => (
          <div key={row.id} className="comp-row" data-kind={row.kind}>
            <div className="comp-row-main">
              <input
                className="comp-name"
                name={`label_${index}`}
                list={`comp-presets-${employeeId}`}
                maxLength={120}
                autoComplete="off"
                aria-label={`Nama komponen ${index + 1}`}
                placeholder="Pilih dari daftar atau ketik nama sendiri"
                value={row.label}
                onChange={(event) => rename(row.id, event.target.value)}
              />
              <div className="comp-amount">
                <span aria-hidden="true">{currency === "IDR" ? "Rp" : currency}</span>
                <MoneyInput
                  name={`amount_${index}`}
                  value={row.amount}
                  onValueChange={(plain) => update(row.id, { amount: plain })}
                  placeholder="0"
                  aria-label={`Jumlah per bulan ${index + 1}`}
                />
              </div>
              <button
                type="button"
                className="comp-remove"
                aria-label={`Hapus komponen ${index + 1}`}
                onClick={() => setRows((previous) => previous.filter((r) => r.id !== row.id))}
                disabled={rows.length === 1}
              >
                ×
              </button>
            </div>
            <div className="comp-row-opts">
              <input type="hidden" name={`kind_${index}`} value={row.kind} />
              <input type="hidden" name={`component_${index}`} value={codes[index] ?? ""} />
              <div className="comp-kind" role="group" aria-label="Jenis komponen">
                <button
                  type="button"
                  aria-pressed={row.kind === "earning"}
                  onClick={() => setKind(row.id, "earning")}
                >
                  Penghasilan
                </button>
                <button
                  type="button"
                  aria-pressed={row.kind === "deduction"}
                  onClick={() => setKind(row.id, "deduction")}
                >
                  Potongan
                </button>
              </div>
              <label className="comp-chip">
                <input
                  type="checkbox"
                  name={`taxable_${index}`}
                  checked={row.taxable}
                  onChange={(event) =>
                    update(row.id, { taxable: event.target.checked, flagsTouched: true })
                  }
                />
                <span>{row.kind === "earning" ? "Kena PPh 21" : "Mengurangi dasar PPh 21"}</span>
              </label>
              {row.kind === "earning" ? (
                <label className="comp-chip">
                  <input
                    type="checkbox"
                    name={`bpjs_base_${index}`}
                    checked={row.bpjsBase}
                    onChange={(event) =>
                      update(row.id, { bpjsBase: event.target.checked, flagsTouched: true })
                    }
                  />
                  <span>Dasar upah BPJS</span>
                </label>
              ) : null}
              <span className="comp-code" title="Kode dibuat otomatis dari nama">
                {row.effectiveFrom ? `Berlaku sejak ${formatShortDate(row.effectiveFrom)} · ` : ""}
                {codes[index] ? codes[index] : "kode otomatis"}
              </span>
            </div>
          </div>
        ))}
      </div>

      {rows.length < 30 ? (
        <div className="comp-suggest">
          {(["earning", "deduction"] as const).map((kind) => {
            const group = suggestions.filter((preset) => preset.kind === kind);
            return (
              <div key={kind} className="comp-suggest-group">
                <span className="comp-suggest-title">
                  {kind === "earning" ? "Tambah penghasilan" : "Tambah potongan"}
                </span>
                <div className="comp-suggest-chips">
                  {group.map((preset) => (
                    <button
                      key={preset.label}
                      type="button"
                      className="comp-suggest-chip"
                      data-kind={preset.kind}
                      title={preset.hint}
                      onClick={() =>
                        setRows((previous) => {
                          // A lone empty first row is replaced instead of pushed down.
                          const onlyBlank =
                            previous.length === 1 &&
                            previous[0].label.trim() === "" &&
                            previous[0].amount === "";
                          return onlyBlank
                            ? [fromPreset(newId(), preset)]
                            : [...previous, fromPreset(newId(), preset)];
                        })
                      }
                    >
                      {preset.label}
                    </button>
                  ))}
                  {/* Each group gets its own, so a potongan with a name of the OWNER's choosing is one click
                      away too (OWNER, 9 October 2026). A new potongan starts outside the PPh 21 base, which
                      is right for the common ones (pinjaman, kasbon) and a tick away for an absence. */}
                  <button
                    type="button"
                    className="comp-suggest-chip comp-suggest-own"
                    data-kind={kind}
                    onClick={() =>
                      setRows((previous) => [
                        ...previous,
                        {
                          id: newId(),
                          savedCode: "",
                          label: "",
                          kind,
                          amount: "",
                          taxable: kind === "earning",
                          bpjsBase: false,
                          flagsTouched: false,
                          effectiveFrom: "",
                        },
                      ])
                    }
                  >
                    Ketik nama sendiri
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      ) : null}

      <dl className="comp-total" aria-live="polite">
        <div>
          <dt>Total penghasilan</dt>
          <dd>{formatMoney(totals.earn.toString(), currency)}</dd>
        </div>
        <div>
          <dt>Total potongan</dt>
          <dd>{formatMoney(totals.deduct.toString(), currency)}</dd>
        </div>
        <div className="comp-total-net">
          <dt>Gaji sebelum BPJS dan PPh 21</dt>
          <dd>{formatMoney(totals.net.toString(), currency)}</dd>
        </div>
      </dl>
      <p className="hint">
        BPJS dan PPh 21 dihitung otomatis saat proses payroll dibuat. {countPosted} komponen akan
        disimpan.
      </p>
      {hasDeduction ? (
        <p className="hint">
          Centang &ldquo;Mengurangi dasar PPh 21&rdquo; hanya bila karyawan memang menerima lebih
          sedikit, misalnya potongan absensi. Cicilan pinjaman dan kasbon tidak dicentang: gaji
          tetap diterima penuh lalu dipakai membayar utang, jadi pajaknya tidak ikut berkurang.
        </p>
      ) : null}
    </PayrollToggleForm>
  );
}
