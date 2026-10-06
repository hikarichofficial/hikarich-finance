"use client";

import { useActionState } from "@/features/feedback/useActionState";
import { setContactStatusAction } from "./contactActions";
import { idleContactActionState } from "./contactActionsState";

/** Nonaktifkan / Aktifkan Kembali for a contact (finding #90). */
export function ContactStatusButton({
  contactId,
  entity,
  status,
}: {
  contactId: string;
  entity: string | undefined;
  status: "active" | "inactive";
}) {
  const [state, action, pending] = useActionState(setContactStatusAction, idleContactActionState);
  const next = status === "active" ? "inactive" : "active";
  return (
    <form action={action} className="inline-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="contact_id" value={contactId} />
      <input type="hidden" name="status" value={next} />
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "Memproses…" : status === "active" ? "Nonaktifkan" : "Aktifkan Kembali"}
      </button>
      {state.status === "error" ? (
        <span role="alert" className="error">
          {state.message}
        </span>
      ) : null}
    </form>
  );
}
