import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { listMemberships, listProfiles, listRoles } from "@/services/admin/users";
import { MEMBERSHIP_STATUS_LABELS } from "@/domain/admin/users";

/** Users & Roles (Step 09 §21, decision 246), gated `users.view` -- the RLS permission on
 * `entity_memberships`/`profiles` and the nav item's own gate since decision 244. Adding a brand-new user
 * needs an account created through Supabase Auth first, so this screen manages existing members. */
export default async function UsersPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("users.view", { entityCode: entity });
  const [members, roles] = await Promise.all([listMemberships(membership.entity_id), listRoles()]);
  const profiles = await listProfiles(members.map((m) => m.user_id));
  const nameOf = new Map(profiles.map((p) => [p.id, p.display_name]));
  const roleOf = new Map(roles.map((r) => [r.id, r.name]));
  const suffix = entity ? `?entity=${encodeURIComponent(entity)}` : "";

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Pengguna &amp; Peran</h1>
          <p className="list-screen-summary">{members.length} anggota entitas ini.</p>
        </div>
      </header>
      <table className="record-table record-table-stacked">
        <thead>
          <tr>
            <th scope="col">Nama</th>
            <th scope="col">Peran</th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody>
          {members.map((m) => (
            <tr key={m.id}>
              <td>
                <Link href={`/admin/users/${m.id}${suffix}`}>
                  {nameOf.get(m.user_id) ?? "Pengguna"}
                  {m.user_id === access.user_id ? " (Anda)" : ""}
                </Link>
              </td>
              <td data-label="Peran">{roleOf.get(m.role_id) ?? "—"}</td>
              <td data-label="Status">
                <span
                  className={`status-badge status-badge-${m.status === "active" ? "success" : "neutral"}`}
                >
                  {MEMBERSHIP_STATUS_LABELS[m.status]}
                </span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
