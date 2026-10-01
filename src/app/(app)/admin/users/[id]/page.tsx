import Link from "next/link";
import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  listMemberships,
  listOverrides,
  listPermissions,
  listProfiles,
  listRolePermissionKeys,
  listRoles,
} from "@/services/admin/users";
import {
  MEMBERSHIP_STATUS_LABELS,
  effectivePermissions,
  userAdminActions,
} from "@/domain/admin/users";
import {
  ChangeRoleForm,
  MembershipStatusForm,
  PermissionOverrideForm,
} from "@/features/admin/UserAccessForms";

/** Member Detail (decision 246): role, status, overrides and the resulting permission read-out, plus the
 * access-change forms the viewer may use. The membership is looked up within the active Entity only. */
export default async function MemberDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("users.view", { entityCode: entity });
  const entityId = membership.entity_id;

  const [members, roles, permissions] = await Promise.all([
    listMemberships(entityId),
    listRoles(),
    listPermissions(),
  ]);
  const member = members.find((m) => m.id === id);
  if (!member) notFound();

  const [profiles, roleKeys, overrides] = await Promise.all([
    listProfiles([member.user_id]),
    listRolePermissionKeys(member.role_id),
    listOverrides(member.id),
  ]);
  const role = roles.find((r) => r.id === member.role_id);
  const isSelf = member.user_id === access.user_id;
  const actions = userAdminActions(isSelf, {
    canAssign:
      can(access, entityId, "users.assign_role") && can(access, entityId, "users.assign_entity"),
    canDisable: can(access, entityId, "users.disable"),
    canOverride: can(access, entityId, "users.change_permissions"),
  });
  const anyAction = actions.canAssign || actions.canDisable || actions.canOverride;
  const suffix = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const here = `/admin/users/${member.id}${suffix}`;
  const effective = effectivePermissions(roleKeys, overrides);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={`/admin/users${suffix}`}>← Kembali ke daftar pengguna</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Anggota Entitas</p>
          <h1>{profiles[0]?.display_name ?? "Pengguna"}</h1>
          <p className="record-detail-counterparty">{role?.name ?? "—"}</p>
        </div>
        <div className="record-detail-header-end">
          <span
            className={`status-badge status-badge-${member.status === "active" ? "success" : "neutral"}`}
          >
            {MEMBERSHIP_STATUS_LABELS[member.status]}
          </span>
        </div>
      </header>

      {isSelf ? (
        <p className="hint">
          Ini akun Anda sendiri. Akses Anda hanya dapat diubah oleh pengguna lain.
        </p>
      ) : null}
      {anyAction && !access.recent_step_up ? (
        <p className="hint">
          Perubahan akses memerlukan verifikasi ulang.{" "}
          <Link href={`/auth/step-up?next=${encodeURIComponent(here)}`}>Verifikasi sekarang</Link>.
        </p>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Izin Efektif</h2>
        </div>
        {effective.length === 0 ? (
          <p>Tidak ada izin.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Izin</th>
                <th scope="col">Sumber</th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {effective.map((p) => (
                <tr key={p.key}>
                  <td>
                    <code>{p.key}</code>
                  </td>
                  <td data-label="Sumber">{p.source === "role" ? "Peran" : "Pengecualian"}</td>
                  <td data-label="Status">
                    <span
                      className={`status-badge status-badge-${p.denied ? "critical" : "success"}`}
                    >
                      {p.denied ? "Ditolak" : "Berlaku"}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {overrides.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Pengecualian Izin</h2>
          </div>
          <ul>
            {overrides.map((o) => (
              <li key={o.permission_key}>
                <code>{o.permission_key}</code>: {o.effect === "grant" ? "diberikan" : "ditolak"}
                {o.reason ? ` — ${o.reason}` : ""}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {actions.canAssign ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Ubah Peran</h2>
          </div>
          <ChangeRoleForm
            membershipId={member.id}
            userId={member.user_id}
            currentRoleKey={role?.role_key ?? ""}
            roles={roles}
            entity={entity}
          />
        </section>
      ) : null}
      {actions.canOverride ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Atur Pengecualian Izin</h2>
          </div>
          <PermissionOverrideForm membershipId={member.id} permissions={permissions} />
        </section>
      ) : null}
      {actions.canDisable ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">
              {member.status === "active" ? "Nonaktifkan" : "Aktifkan"} Keanggotaan
            </h2>
          </div>
          <MembershipStatusForm membershipId={member.id} active={member.status === "active"} />
        </section>
      ) : null}
    </div>
  );
}
