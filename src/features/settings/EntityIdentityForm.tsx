"use client";

import Link from "next/link";
import { useActionState } from "react";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import type { EntityProfileRow } from "@/schemas/settings";
import { updateEntityIdentityAction } from "./actions";
import { idleTimeSettingsState } from "./actionsState";

/** Edit the Entity's legal name, brand name, address and contact details (decision 272). Documents already
 * issued keep the name they were issued with; new ones use what is saved here. */
export function EntityIdentityForm({
  entity,
  legalName,
  brandName,
  profile,
  version,
  stepUpHref,
}: {
  entity: string | undefined;
  legalName: string;
  brandName: string | null;
  profile: EntityProfileRow | null;
  version: number;
  stepUpHref: string;
}) {
  const [state, action, pending] = useActionState(
    updateEntityIdentityAction,
    idleTimeSettingsState,
  );
  const actionForm = usePreservingForm(action, { status: "idle" });
  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="expected_version" value={version} />
      <p className="hint">
        Nama dan merek bisa diganti kapan saja. Invoice dan kuitansi yang sudah terbit tetap memakai
        nama lama; dokumen baru memakai nama di sini. Perubahan memerlukan verifikasi ulang.{" "}
        <Link href={stepUpHref}>Verifikasi sekarang</Link>.
      </p>
      <label>
        Nama Resmi
        <input name="legal_name" required maxLength={200} defaultValue={legalName} />
      </label>
      <label>
        Nama Merek (opsional)
        <input name="brand_name" maxLength={200} defaultValue={brandName ?? ""} />
      </label>
      <label>
        Alamat (opsional)
        <input name="address_line" maxLength={300} defaultValue={profile?.address_line ?? ""} />
      </label>
      <label>
        Kota (opsional)
        <input name="city" maxLength={100} defaultValue={profile?.city ?? ""} />
      </label>
      <label>
        Provinsi (opsional)
        <input name="province" maxLength={100} defaultValue={profile?.province ?? ""} />
      </label>
      <label>
        Kode Pos (opsional)
        <input name="postal_code" maxLength={20} defaultValue={profile?.postal_code ?? ""} />
      </label>
      <label>
        Email (opsional)
        <input
          type="email"
          name="contact_email"
          maxLength={200}
          defaultValue={profile?.contact_email ?? ""}
        />
      </label>
      <label>
        Telepon (opsional)
        <input name="contact_phone" maxLength={40} defaultValue={profile?.contact_phone ?? ""} />
      </label>
      <label>
        Situs Web (opsional)
        <input name="website" maxLength={200} defaultValue={profile?.website ?? ""} />
      </label>
      <div>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan Nama & Profil"}
        </button>
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
              <Link href={stepUpHref}>Verifikasi sekarang</Link>.
            </>
          ) : null}
        </p>
      ) : null}
    </form>
  );
}
