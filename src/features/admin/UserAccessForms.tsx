"use client";

import { useActionState } from "react";
import type { PermissionRow, RoleRow } from "@/schemas/admin";
import {
  changeRoleAction,
  revokeDeviceAction,
  setOverrideAction,
  setStatusAction,
  type UserActionState,
} from "./userActions";
import { idleUserActionState } from "./userActionsState";

/** Access-change forms on a membership (decision 246). Every change asks for a written reason, which the
 * RPC records in the audit trail. */

function Result({ state }: { state: UserActionState }) {
  if (state.status === "idle") return null;
  return (
    <p
      role={state.status === "error" ? "alert" : "status"}
      className={state.status === "error" ? "error" : "hint"}
    >
      {state.message}
    </p>
  );
}

function ReasonField() {
  return (
    <label>
      Alasan (minimal 5 karakter)
      <input name="reason" required minLength={5} maxLength={500} />
    </label>
  );
}

export function ChangeRoleForm({
  membershipId,
  userId,
  currentRoleKey,
  roles,
  entity,
}: {
  membershipId: string;
  userId: string;
  currentRoleKey: string;
  roles: readonly RoleRow[];
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(changeRoleAction, idleUserActionState);
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="membership_id" value={membershipId} />
      <input type="hidden" name="user_id" value={userId} />
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Peran
        <select name="role_key" defaultValue={currentRoleKey}>
          {roles.map((role) => (
            <option key={role.id} value={role.role_key}>
              {role.name}
            </option>
          ))}
        </select>
      </label>
      <ReasonField />
      <Result state={state} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Ubah Peran"}
      </button>
    </form>
  );
}

export function MembershipStatusForm({
  membershipId,
  active,
}: {
  membershipId: string;
  active: boolean;
}) {
  const [state, action, pending] = useActionState(setStatusAction, idleUserActionState);
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="membership_id" value={membershipId} />
      <input type="hidden" name="active" value={active ? "false" : "true"} />
      <ReasonField />
      <Result state={state} />
      <button type="submit" className={active ? "btn-danger" : "btn-primary"} disabled={pending}>
        {pending ? "Menyimpan…" : active ? "Nonaktifkan Keanggotaan" : "Aktifkan Keanggotaan"}
      </button>
    </form>
  );
}

export function PermissionOverrideForm({
  membershipId,
  permissions,
}: {
  membershipId: string;
  permissions: readonly PermissionRow[];
}) {
  const [state, action, pending] = useActionState(setOverrideAction, idleUserActionState);
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="membership_id" value={membershipId} />
      <label>
        Izin
        <select name="permission_key" required defaultValue="">
          <option value="" disabled>
            Pilih izin
          </option>
          {permissions.map((p) => (
            <option key={p.key} value={p.key}>
              {p.key}
              {p.description ? ` — ${p.description}` : ""}
            </option>
          ))}
        </select>
      </label>
      <label>
        Efek
        <select name="effect" defaultValue="grant">
          <option value="grant">Berikan (tambahan di luar peran)</option>
          <option value="deny">Tolak (cabut walau peran memberi)</option>
          <option value="clear">Hapus pengecualian</option>
        </select>
      </label>
      <ReasonField />
      <Result state={state} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Pengecualian"}
      </button>
    </form>
  );
}

export function RevokeDeviceForm({
  deviceId,
  entity,
}: {
  deviceId: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(revokeDeviceAction, idleUserActionState);
  if (state.status === "ok") return <Result state={state} />;
  return (
    <details>
      <summary>Cabut</summary>
      <form action={action} className="record-form">
        <input type="hidden" name="device_id" value={deviceId} />
        <input type="hidden" name="entity" value={entity ?? ""} />
        <ReasonField />
        <button type="submit" className="btn-danger" disabled={pending}>
          {pending ? "Mencabut…" : "Cabut perangkat"}
        </button>
        <Result state={state} />
      </form>
    </details>
  );
}
