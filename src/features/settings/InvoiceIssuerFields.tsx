"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import { useActionState } from "@/features/feedback/useActionState";
import { updateEntityIdentityAction } from "./actions";
import { idleTimeSettingsState } from "./actionsState";

/** What the invoice shows about the company, typed straight into the preview (OWNER, 6 October 2026). */
export interface IssuerDraft {
  legal_name: string;
  brand_name: string;
  address_line: string;
  city: string;
  province: string;
  postal_code: string;
  contact_email: string;
  contact_phone: string;
}

const FIELDS: readonly {
  key: keyof IssuerDraft;
  label: string;
  max: number;
  type?: string;
  required?: boolean;
}[] = [
  { key: "legal_name", label: "Nama Resmi", max: 200, required: true },
  { key: "brand_name", label: "Nama Merek", max: 200 },
  { key: "address_line", label: "Alamat", max: 300 },
  { key: "city", label: "Kota", max: 100 },
  { key: "province", label: "Provinsi", max: 100 },
  { key: "postal_code", label: "Kode Pos", max: 20 },
  { key: "contact_email", label: "Email", max: 200, type: "email" },
  { key: "contact_phone", label: "Telepon", max: 40 },
];

/**
 * The company's name, address and contact details, edited here next to the invoice preview: every keystroke shows
 * in the preview straight away. Saving writes the very same record as Pengaturan → Nama & Profil (the same action,
 * permission, step-up and version check), so what is saved here is what Pengaturan, new invoices, receipts and
 * emails use too -- there is one copy of the data, not two. Invoices already issued keep the name they were issued with.
 */
export function InvoiceIssuerFields({
  entity,
  saved,
  draft,
  onChange,
  website,
  version,
  stepUpHref,
}: {
  entity: string | undefined;
  /** What is stored now (Pengaturan), to tell whether the typed text has been saved yet. */
  saved: IssuerDraft;
  draft: IssuerDraft;
  onChange: (next: IssuerDraft) => void;
  /** Not shown on the invoice, but part of the same record, so it is sent back unchanged. */
  website: string;
  version: number;
  stepUpHref: string;
}) {
  const [state, action, pending] = useActionState(
    updateEntityIdentityAction,
    idleTimeSettingsState,
  );
  const unsaved = FIELDS.some((field) => draft[field.key].trim() !== saved[field.key].trim());
  return (
    <form action={action} className="record-form lay-issuer">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="expected_version" value={version} />
      <input type="hidden" name="website" value={website} />
      <h3 className="dashboard-section-title">Data perusahaan di invoice</h3>
      <p className="hint">
        Ketik langsung di sini; invoice di bawah ikut berubah. Disimpan ke Pengaturan, jadi nama dan
        alamat yang sama dipakai di invoice, kuitansi, dan email. Invoice yang sudah terbit tidak
        berubah.
      </p>
      <div className="lay-issuer-grid">
        {FIELDS.map((field) => (
          <label key={field.key}>
            {field.label}
            <input
              name={field.key}
              type={field.type ?? "text"}
              required={field.required}
              maxLength={field.max}
              value={draft[field.key]}
              onChange={(event) => onChange({ ...draft, [field.key]: event.target.value })}
            />
          </label>
        ))}
      </div>
      <div className="lay-issuer-actions">
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan Data Perusahaan"}
        </button>
        {unsaved ? (
          <span className="hint" role="status">
            Belum disimpan: invoice di bawah hanya contoh sampai tombol ini ditekan.
          </span>
        ) : null}
      </div>
      {state.status !== "idle" ? (
        <p
          role={state.status === "error" ? "alert" : "status"}
          className={state.status === "error" ? "error" : "hint"}
        >
          {state.message}
          {state.stepUp ? (
            <>
              {" "}
              <StepUpLink href={stepUpHref}>Verifikasi sekarang</StepUpLink>.
            </>
          ) : null}
        </p>
      ) : null}
    </form>
  );
}
