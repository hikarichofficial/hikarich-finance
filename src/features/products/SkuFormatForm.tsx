"use client";

import { useMemo, useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import {
  composeSku,
  SKU_PART_HELP,
  SKU_PART_LABELS,
  SKU_SCOPE_LABELS,
  SKU_SEPARATORS,
  type SkuComponent,
  type SkuFormat,
} from "@/domain/products/sku";
import type { SkuSettings } from "@/schemas/sku";
import { saveSkuSettingsAction } from "./skuActions";
import { idleSkuActionState } from "./skuActionsState";

const KNOWN_SEPARATORS = SKU_SEPARATORS.map((s) => s.value);

/**
 * SKU Format builder (decision 324): order and on/off of the four parts, separator, prefix, suffix, how an empty
 * part is handled, and the numbering rule (digits, start, step, scope). The preview is computed here from what is
 * on screen, so the Owner sees the result before saving; saving changes new SKUs only.
 */
export function SkuFormatForm({
  settings,
  entity,
  sample,
}: {
  settings: SkuSettings;
  entity: string | undefined;
  sample: { brand: string; type: string; variant: string };
}) {
  const [state, action, pending] = useActionState(saveSkuSettingsAction, idleSkuActionState);
  const actionForm = usePreservingForm(action, state);
  const [auto, setAuto] = useState(settings.auto_generate);
  const [components, setComponents] = useState<SkuComponent[]>(
    settings.components.map((c) => ({ ...c })),
  );
  const [separatorChoice, setSeparatorChoice] = useState(
    KNOWN_SEPARATORS.includes(settings.separator) ? settings.separator : "custom",
  );
  const [customSeparator, setCustomSeparator] = useState(
    KNOWN_SEPARATORS.includes(settings.separator) ? "" : settings.separator,
  );
  const [prefix, setPrefix] = useState(settings.prefix);
  const [suffix, setSuffix] = useState(settings.suffix);
  const [emptyHandling, setEmptyHandling] = useState<"skip" | "placeholder">(
    settings.empty_handling,
  );
  const [placeholder, setPlaceholder] = useState(settings.empty_placeholder);
  const [digits, setDigits] = useState(settings.number_digits);
  const [start, setStart] = useState(settings.number_start);
  const [step, setStep] = useState(settings.number_step);
  const [scope, setScope] = useState(settings.number_scope);

  const separator = separatorChoice === "custom" ? customSeparator : separatorChoice;

  function move(index: number, delta: number) {
    setComponents((current) => {
      const next = [...current];
      const target = index + delta;
      if (target < 0 || target >= next.length) return current;
      [next[index], next[target]] = [next[target]!, next[index]!];
      return next;
    });
  }
  function patch(index: number, change: Partial<SkuComponent>) {
    setComponents((current) => current.map((c, i) => (i === index ? { ...c, ...change } : c)));
  }

  const format: SkuFormat = useMemo(
    () => ({
      components,
      separator,
      prefix,
      suffix,
      emptyHandling,
      emptyPlaceholder: placeholder,
      digits,
    }),
    [components, separator, prefix, suffix, emptyHandling, placeholder, digits],
  );
  const baseSample = composeSku(
    format,
    { ...sample, number: start, variant: null },
    { base: true },
  );
  const variantSample = composeSku(format, { ...sample, number: start, variant: sample.variant });

  return (
    <form {...actionForm} className="record-form sku-format-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="components" value={JSON.stringify(components)} />

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Pratinjau</h2>
        </div>
        <dl className="record-summary-grid record-summary-compact">
          <div>
            <dt>SKU produk</dt>
            <dd className="sku-preview">{"sku" in baseSample ? baseSample.sku : "—"}</dd>
          </div>
          <div>
            <dt>SKU variant</dt>
            <dd className="sku-preview">{"sku" in variantSample ? variantSample.sku : "—"}</dd>
          </div>
        </dl>
        <p className="hint">
          Perubahan format hanya berlaku untuk SKU baru, kecuali Owner mengubah SKU produk secara
          manual. Dokumen dan transaksi lama tetap menyimpan SKU lamanya.
        </p>
      </section>

      <label className="checkbox-field">
        <input
          type="checkbox"
          name="auto_generate"
          checked={auto}
          onChange={(event) => setAuto(event.target.checked)}
        />
        Buat SKU otomatis saat produk ditambahkan
      </label>
      {!auto ? (
        <p className="hint">
          SKU otomatis mati: produk baru tidak mendapat SKU sampai Owner mengisinya manual. SKU
          manual tidak mengikuti struktur otomatis, tetapi tetap harus unik.
        </p>
      ) : null}

      <h3>Susunan SKU</h3>
      <ol className="sku-components">
        {components.map((component, index) => (
          <li key={component.key} className="sku-component">
            <div>
              <strong>{SKU_PART_LABELS[component.key]}</strong>
              <p className="hint">{SKU_PART_HELP[component.key]}</p>
            </div>
            <label className="checkbox-field">
              <input
                type="checkbox"
                checked={component.enabled}
                onChange={(event) => patch(index, { enabled: event.target.checked })}
              />
              Dipakai
            </label>
            <label className="checkbox-field">
              <input
                type="checkbox"
                checked={component.required}
                disabled={!component.enabled}
                onChange={(event) => patch(index, { required: event.target.checked })}
              />
              Wajib
            </label>
            <span className="sku-component-move">
              <button
                type="button"
                className="btn-secondary"
                aria-label="Naikkan"
                disabled={index === 0}
                onClick={() => move(index, -1)}
              >
                ↑
              </button>
              <button
                type="button"
                className="btn-secondary"
                aria-label="Turunkan"
                disabled={index === components.length - 1}
                onClick={() => move(index, 1)}
              >
                ↓
              </button>
            </span>
          </li>
        ))}
      </ol>

      <div className="sku-grid">
        <label>
          Pemisah
          <select
            value={separatorChoice}
            onChange={(event) => setSeparatorChoice(event.target.value)}
          >
            {SKU_SEPARATORS.map((s) => (
              <option key={s.label} value={s.value}>
                {s.label}
              </option>
            ))}
            <option value="custom">Lainnya…</option>
          </select>
        </label>
        {separatorChoice === "custom" ? (
          <label>
            Pemisah sendiri (1–2 tanda: - / . _ : ~ | +)
            <input
              value={customSeparator}
              maxLength={2}
              pattern="[-/._:~|+]{0,2}"
              onChange={(event) => setCustomSeparator(event.target.value)}
            />
          </label>
        ) : null}
        <input type="hidden" name="separator" value={separator} />
        <label>
          Awalan (opsional)
          <input
            name="prefix"
            value={prefix}
            maxLength={12}
            pattern="[A-Za-z0-9._/\-]{0,12}"
            placeholder="mis. HIK"
            onChange={(event) => setPrefix(event.target.value.toUpperCase())}
          />
        </label>
        <label>
          Akhiran (opsional)
          <input
            name="suffix"
            value={suffix}
            maxLength={12}
            pattern="[A-Za-z0-9._/\-]{0,12}"
            onChange={(event) => setSuffix(event.target.value.toUpperCase())}
          />
        </label>
        <label>
          Bagian kosong
          <select
            name="empty_handling"
            value={emptyHandling}
            onChange={(event) => setEmptyHandling(event.target.value as "skip" | "placeholder")}
          >
            <option value="skip">Dilewati (tanpa pemisah ganda)</option>
            <option value="placeholder">Diganti isian tetap</option>
          </select>
        </label>
        {emptyHandling === "placeholder" ? (
          <label>
            Isian tetap
            <input
              name="empty_placeholder"
              value={placeholder}
              maxLength={6}
              pattern="[A-Za-z0-9]{1,6}"
              onChange={(event) => setPlaceholder(event.target.value.toUpperCase())}
            />
          </label>
        ) : (
          <input type="hidden" name="empty_placeholder" value={placeholder} />
        )}
      </div>

      <h3>Aturan Nomor Produk</h3>
      <p className="hint">
        Nomor dibuat otomatis oleh database dan tidak pernah dipakai ulang, juga bila produknya
        dihapus atau diarsipkan.
      </p>
      <div className="sku-grid">
        <label>
          Jumlah digit
          <input
            type="number"
            name="number_digits"
            min={1}
            max={9}
            value={digits}
            onChange={(event) => setDigits(Number(event.target.value) || 1)}
          />
        </label>
        <label>
          Mulai dari
          <input
            type="number"
            name="number_start"
            min={0}
            value={start}
            onChange={(event) => setStart(Number(event.target.value) || 0)}
          />
        </label>
        <label>
          Kenaikan
          <input
            type="number"
            name="number_step"
            min={1}
            value={step}
            onChange={(event) => setStep(Number(event.target.value) || 1)}
          />
        </label>
        <label>
          Cakupan nomor
          <select
            name="number_scope"
            value={scope}
            onChange={(event) => setScope(event.target.value as SkuSettings["number_scope"])}
          >
            {(Object.keys(SKU_SCOPE_LABELS) as (keyof typeof SKU_SCOPE_LABELS)[]).map((key) => (
              <option key={key} value={key}>
                {SKU_SCOPE_LABELS[key]}
              </option>
            ))}
          </select>
        </label>
      </div>

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Format SKU"}
      </button>
    </form>
  );
}
