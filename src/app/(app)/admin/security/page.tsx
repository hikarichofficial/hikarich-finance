import { StepUpLink } from "@/features/feedback/StepUp";
import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { getEntitySettingsOverview } from "@/services/settings/settings";
import {
  SECURITY_PAGE_SIZE,
  listMemberships,
  listProfiles,
  listSecurityEvents,
  listTrustedDevices,
} from "@/services/admin/users";
import {
  SECURITY_SEVERITY_LABELS,
  SECURITY_SEVERITY_TONE,
  parsePageOffset,
} from "@/domain/admin/users";
import { formatAuditTimestamp } from "@/features/audit/format";
import { RevokeDeviceForm } from "@/features/admin/UserAccessForms";
import { can } from "@/domain/authz/access";

/**
 * Security Center (Step 09 §21 Security, decision 246), read-only, gated `security.view` -- the RLS
 * permission on `security_events`/`trusted_devices` and the nav item's gate since decision 244. Shows the
 * Entity's MFA requirement, its security events (paged) and its members' trusted devices. An active device
 * can be revoked (decision 247, `revoke_trusted_device`): one's own always, another member's with
 * `security.manage` and a recent step-up -- the RPC enforces both and records a security event.
 */
export default async function SecurityPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; offset?: string }>;
}) {
  const { entity, offset: offsetParam } = await searchParams;
  const { access, membership } = await requirePermission("security.view", {
    entityCode: entity,
  });
  const entityId = membership.entity_id;
  const offset = parsePageOffset(offsetParam, SECURITY_PAGE_SIZE);

  const members = await listMemberships(entityId);
  const userIds = members.map((m) => m.user_id);
  const [events, devices, profiles, settings] = await Promise.all([
    listSecurityEvents(entityId, offset),
    listTrustedDevices(userIds),
    listProfiles(userIds),
    getEntitySettingsOverview(entityId).catch(() => null),
  ]);
  const canManage = can(access, entityId, "security.manage");
  const here = entity ? `/admin/security?entity=${encodeURIComponent(entity)}` : "/admin/security";
  const nameOf = new Map(profiles.map((p) => [p.id, p.display_name]));
  const mfa = settings?.settings.find((s) => s.setting_key === "security.require_mfa");
  const pageHref = (o: number) => {
    const params = new URLSearchParams();
    if (entity) params.set("entity", entity);
    if (o > 0) params.set("offset", String(o));
    const qs = params.toString();
    return qs ? `/admin/security?${qs}` : "/admin/security";
  };

  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Administrasi</p>
          <h1>Keamanan</h1>
        </div>
        <div className="record-detail-header-end">
          <span
            className={`status-badge status-badge-${mfa?.setting_value === true ? "success" : "attention"}`}
          >
            {mfa?.setting_value === true ? "MFA wajib" : "MFA tidak diwajibkan"}
          </span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Kejadian Keamanan</h2>
        </div>
        {events.rows.length === 0 ? (
          <p>Tidak ada kejadian keamanan pada halaman ini.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Waktu</th>
                <th scope="col">Kejadian</th>
                <th scope="col">Pengguna</th>
                <th scope="col">Tingkat</th>
              </tr>
            </thead>
            <tbody>
              {events.rows.map((e) => (
                <tr key={e.id}>
                  <td>{formatAuditTimestamp(e.occurred_at)}</td>
                  <td data-label="Kejadian">
                    <code>{e.event_type}</code>
                  </td>
                  <td data-label="Pengguna">{e.user_id ? (nameOf.get(e.user_id) ?? "—") : "—"}</td>
                  <td data-label="Tingkat">
                    <span
                      className={`status-badge status-badge-${SECURITY_SEVERITY_TONE[e.severity]}`}
                    >
                      {SECURITY_SEVERITY_LABELS[e.severity]}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        {offset > 0 || events.hasMore ? (
          <div className="list-screen-toolbar" aria-label="Navigasi halaman">
            {offset > 0 ? (
              <Link
                href={pageHref(Math.max(0, offset - SECURITY_PAGE_SIZE))}
                className="btn-secondary"
              >
                Sebelumnya
              </Link>
            ) : null}
            {events.hasMore ? (
              <Link href={pageHref(offset + SECURITY_PAGE_SIZE)} className="btn-secondary">
                Berikutnya
              </Link>
            ) : null}
          </div>
        ) : null}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Perangkat Tepercaya</h2>
        </div>
        {canManage ? (
          <p className="hint">
            Mencabut perangkat pengguna lain memerlukan verifikasi ulang dalam 30 menit terakhir.{" "}
            <StepUpLink href={`/auth/step-up?next=${encodeURIComponent(here)}`}>
              Verifikasi sekarang
            </StepUpLink>
            .
          </p>
        ) : null}
        {devices.length === 0 ? (
          <p>Belum ada perangkat tepercaya yang tercatat.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Perangkat</th>
                <th scope="col">Pengguna</th>
                <th scope="col">Terakhir Terlihat</th>
                <th scope="col">Status</th>
                <th scope="col">Tindakan</th>
              </tr>
            </thead>
            <tbody>
              {devices.map((d) => (
                <tr key={d.id}>
                  <td>{d.label ?? "Perangkat tanpa label"}</td>
                  <td data-label="Pengguna">{nameOf.get(d.user_id) ?? "—"}</td>
                  <td data-label="Terakhir Terlihat">{formatAuditTimestamp(d.last_seen_at)}</td>
                  <td data-label="Status">
                    <span
                      className={`status-badge status-badge-${d.revoked_at ? "neutral" : "success"}`}
                    >
                      {d.revoked_at ? "Dicabut" : "Tepercaya"}
                    </span>
                  </td>
                  <td data-label="Tindakan">
                    {!d.revoked_at && (canManage || d.user_id === access.user_id) ? (
                      <RevokeDeviceForm deviceId={d.id} entity={entity} />
                    ) : (
                      "—"
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
