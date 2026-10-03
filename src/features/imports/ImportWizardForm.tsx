"use client";

import { useActionState, useMemo, useState, type ChangeEvent } from "react";
import {
  IMPORT_FIELDS,
  importTemplate,
  mapImportTable,
  parseDelimited,
} from "@/domain/imports/csv";
import { IMPORT_DOMAIN_LABELS } from "@/domain/imports/imports";
import { importDomainSchema, type ImportDomain } from "@/schemas/imports";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { stageImportAction } from "./importActions";
import { idleImportActionState } from "./importActionsState";

const PREVIEW_ROWS = 5;

/** What the preview shows for the contact kind the database will receive. */
const KIND_LABELS: Readonly<Record<string, string>> = {
  customer: "Pelanggan",
  vendor: "Vendor",
  both: "Pelanggan dan vendor",
};

/**
 * Import Wizard, step 1 (Step 15 §15, decision 275): choose what is imported, paste a table or pick a CSV
 * file, see how the columns were read, then send it for checking. Nothing is written to the books here: the
 * rows are staged and validated, and the next screen shows the result row by row before anything is applied.
 */
export function ImportWizardForm({ entity }: { entity: string | undefined }) {
  const [state, action, pending] = useActionState(stageImportAction, idleImportActionState);
  const actionForm = usePreservingForm(action, state);
  const [domain, setDomain] = useState<ImportDomain>("contacts");
  const [table, setTable] = useState("");
  const [fileName, setFileName] = useState("");
  const [fileError, setFileError] = useState<string | null>(null);

  const fields = IMPORT_FIELDS[domain];
  const parsed = useMemo(() => parseDelimited(table), [table]);
  const mapped = useMemo(() => mapImportTable(domain, parsed), [domain, parsed]);
  const hasData = parsed.length >= 2;
  const shown = fields.filter((f) => Object.values(mapped.mapping).includes(f.key));

  function onFile(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    if (!file) return;
    if (file.size > 900_000) {
      setFileError("Berkas terlalu besar. Bagi menjadi beberapa berkas di bawah 900 KB.");
      return;
    }
    setFileError(null);
    setFileName(file.name);
    file
      .text()
      .then(setTable)
      .catch(() => setFileError("Berkas tidak dapat dibaca. Simpan sebagai CSV lalu coba lagi."));
  }

  return (
    <form {...actionForm} className="record-form record-form-wide">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="file_name" value={fileName} />
      <label>
        Data yang diimpor
        <select
          name="domain"
          value={domain}
          onChange={(event) => setDomain(importDomainSchema.parse(event.target.value))}
        >
          {importDomainSchema.options.map((option) => (
            <option key={option} value={option}>
              {IMPORT_DOMAIN_LABELS[option]}
            </option>
          ))}
        </select>
      </label>

      <div className="hint">
        <p>
          Baris pertama adalah judul kolom. Kolom yang dikenali:{" "}
          {fields.map((f, index) => (
            <span key={f.key}>
              {index > 0 ? ", " : ""}
              <strong>{f.label}</strong>
              {f.required ? " (wajib)" : ""}
            </span>
          ))}
          .
        </p>
        {domain === "contacts" ? (
          <p>Jenis diisi: pelanggan, vendor, atau keduanya.</p>
        ) : (
          <p>
            Nama Kontak harus sama dengan kontak yang sudah ada (impor Kontak lebih dulu). Tanggal
            boleh 15/08/2026 atau 2026-08-15. Mata uang rupiah ditulis IDR.
          </p>
        )}
        <button
          type="button"
          className="btn-ghost"
          onClick={() => setTable(importTemplate(domain))}
        >
          Isi dengan contoh
        </button>
      </div>

      <label>
        Pilih berkas CSV (opsional)
        <input type="file" accept=".csv,.txt,text/csv,text/plain" onChange={onFile} />
      </label>
      {fileError ? (
        <p role="alert" className="error">
          {fileError}
        </p>
      ) : null}

      <label style={{ maxWidth: "none" }}>
        Atau tempel tabel dari Excel / Google Sheets di sini
        <textarea
          name="table"
          rows={10}
          value={table}
          onChange={(event) => setTable(event.target.value)}
          spellCheck={false}
          required
        />
      </label>

      {hasData ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">
              Terbaca {mapped.rows.length} baris data
              {mapped.rows.length > PREVIEW_ROWS ? ` (contoh ${PREVIEW_ROWS} baris pertama)` : ""}
            </h2>
          </div>
          {mapped.missingFields.length > 0 ? (
            <p role="alert" className="error">
              Kolom wajib belum ada: {mapped.missingFields.map((f) => f.label).join(", ")}.
            </p>
          ) : null}
          {mapped.unknownHeaders.length > 0 ? (
            <p className="hint">
              Kolom yang tidak dikenali dan tidak ikut diimpor: {mapped.unknownHeaders.join(", ")}.
            </p>
          ) : null}
          {shown.length > 0 ? (
            <table className="record-table record-table-stacked">
              <thead>
                <tr>
                  {shown.map((f) => (
                    <th scope="col" key={f.key}>
                      {f.label}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {mapped.rows.slice(0, PREVIEW_ROWS).map((row, index) => (
                  <tr key={index}>
                    {shown.map((f) => (
                      <td key={f.key} data-label={f.label}>
                        {(f.kind === "contact_kind" ? KIND_LABELS[row[f.key]] : undefined) ??
                          (row[f.key] || "—")}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          ) : null}
        </section>
      ) : null}

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button
        type="submit"
        className="btn-primary"
        style={{ alignSelf: "flex-start" }}
        disabled={pending || !hasData || mapped.missingFields.length > 0}
      >
        {pending ? "Memeriksa…" : "Periksa Data"}
      </button>
      <p className="hint">
        Belum ada yang masuk ke pembukuan. Setelah diperiksa, Anda melihat hasil per baris lalu
        memutuskan untuk menerapkannya.
      </p>
    </form>
  );
}
