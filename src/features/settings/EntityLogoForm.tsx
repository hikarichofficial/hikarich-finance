"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import { useActionState } from "@/features/feedback/useActionState";
import { updateEntityLogoAction } from "./actions";
import { idleTimeSettingsState } from "./actionsState";

/** Upload or remove the company logo shown at the top of invoices and receipts (decision 307). PNG, JPEG or
 * WebP, up to about 280 KB; a square or wide logo on a plain background looks best. Needs a recent step-up. */
export function EntityLogoForm({
  entity,
  logo,
  stepUpHref,
}: {
  entity: string | undefined;
  logo: string | null;
  stepUpHref: string;
}) {
  const [state, action, pending] = useActionState(updateEntityLogoAction, idleTimeSettingsState);
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <h3 className="dashboard-section-title">Logo Perusahaan</h3>
      <p className="hint">
        Logo tampil di kiri atas invoice dan kuitansi. Format PNG, JPEG, atau WebP, maksimal sekitar
        280 KB. Perubahan memerlukan verifikasi ulang.{" "}
        <StepUpLink href={stepUpHref}>Verifikasi sekarang</StepUpLink>.
      </p>
      {logo ? (
        // eslint-disable-next-line @next/next/no-img-element -- an embedded data: image, not optimizable
        <img className="settings-logo-preview" src={logo} alt="Logo saat ini" />
      ) : (
        <p className="hint">Belum ada logo.</p>
      )}
      <label>
        Pilih Logo Baru
        <input type="file" name="logo" accept="image/png,image/jpeg,image/webp" />
      </label>
      <div className="record-form-actions">
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan Logo"}
        </button>
        {logo ? (
          <button
            type="submit"
            name="remove"
            value="1"
            className="btn-secondary"
            disabled={pending}
            formNoValidate
          >
            Hapus Logo
          </button>
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
