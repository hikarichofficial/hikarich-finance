import type { ReactNode } from "react";
import { formatMoney } from "@/domain/money/format";
import {
  ENTITY_TYPE_LABELS,
  NUMBERING_SCOPE_LABELS,
  RESET_POLICY_LABELS,
  entitySettingLabel,
  entitySettingValueText,
  monthName,
  numberingExample,
  timezoneLabel,
} from "@/domain/settings/settings";
import type { EntitySettingsOverview } from "@/services/settings/settings";

/**
 * Settings (P13 unbuilt-screens backlog, decision 243): the active Entity's profile, document numbering,
 * approval rules and stored key/value settings on one page. The Entity's timezone and fiscal-year start are
 * editable by `system.entity_config` holders (decision 248, `timeSettingsEditor`); the rest is read-only.
 */

function activeTone(active: boolean): "success" | "neutral" {
  return active ? "success" : "neutral";
}

function approverLabel(roleId: string | null, roleNames: ReadonlyMap<string, string>): string {
  if (!roleId) return "Peran mana pun yang berwenang";
  return roleNames.get(roleId) ?? "—";
}

function Field({ label, value }: { label: string; value: string | null | undefined }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{value && value.trim() ? value : "—"}</dd>
    </div>
  );
}

export function SettingsScreen({
  overview,
  exampleYear,
  timeSettingsEditor,
  identityEditor,
  createEntityEditor,
  negativeBalanceEditor,
}: {
  overview: EntitySettingsOverview;
  exampleYear: number;
  timeSettingsEditor?: ReactNode;
  /** The names/address form, for holders of `system.entity_config` (decision 272). */
  identityEditor?: ReactNode;
  /** The add-an-Entity form, shown to an OWNER (decision 276). */
  createEntityEditor?: ReactNode;
  /** The "which account kinds may never go negative" form, for holders of `system.entity_config`
   * (decision 55, OWNER answer 4 October 2026). When given, the raw `money.block_negative_balance` row is
   * left out of the generic list below -- this form is its editable replacement. */
  negativeBalanceEditor?: ReactNode;
}) {
  const { entity, profile, numbering, approvalRules, roleNames, settings } = overview;
  const otherSettings = negativeBalanceEditor
    ? settings.filter((s) => s.setting_key !== "money.block_negative_balance")
    : settings;
  const address = profile
    ? [
        profile.address_line,
        profile.city,
        profile.province,
        profile.postal_code,
        profile.country_code,
      ]
        .filter((part) => part && part.trim())
        .join(", ")
    : null;

  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pengaturan Entitas</p>
          <h1>{entity.brand_name ?? entity.legal_name}</h1>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${activeTone(entity.status === "active")}`}>
            {entity.status === "active" ? "Aktif" : "Nonaktif"}
          </span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Profil Entitas</h2>
        </div>
        <dl className="record-summary-grid">
          <Field label="Nama Resmi" value={entity.legal_name} />
          <Field label="Nama Merek" value={entity.brand_name} />
          <Field label="Kode" value={entity.code} />
          <Field label="Jenis" value={ENTITY_TYPE_LABELS[entity.entity_type]} />
          <Field label="Mata Uang Dasar" value={entity.base_currency} />
          <Field label="Zona Waktu" value={timezoneLabel(entity.timezone)} />
          <Field label="Awal Tahun Fiskal" value={monthName(entity.fiscal_year_start_month)} />
          <Field label="Alamat" value={address} />
          <Field label="Email" value={profile?.contact_email} />
          <Field label="Telepon" value={profile?.contact_phone} />
          <Field label="Situs Web" value={profile?.website} />
        </dl>
      </section>

      {identityEditor ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Ubah Nama &amp; Profil</h2>
          </div>
          {identityEditor}
        </section>
      ) : null}

      {timeSettingsEditor ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Zona Waktu &amp; Tahun Buku</h2>
          </div>
          {timeSettingsEditor}
        </section>
      ) : null}

      {createEntityEditor ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Tambah Entity</h2>
          </div>
          {createEntityEditor}
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Penomoran Dokumen</h2>
        </div>
        {numbering.length === 0 ? (
          <p>Belum ada urutan penomoran untuk entitas ini.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Dokumen</th>
                <th scope="col">Contoh Nomor</th>
                <th scope="col">Reset</th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {numbering.map((sequence) => (
                <tr key={sequence.id}>
                  <td>{NUMBERING_SCOPE_LABELS[sequence.scope]}</td>
                  <td data-label="Contoh Nomor">
                    <code>{numberingExample(sequence, exampleYear)}</code>
                  </td>
                  <td data-label="Reset">{RESET_POLICY_LABELS[sequence.reset_policy]}</td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${activeTone(sequence.is_active)}`}>
                      {sequence.is_active ? "Aktif" : "Nonaktif"}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Aturan Persetujuan</h2>
        </div>
        {approvalRules.length === 0 ? (
          <p>Belum ada aturan persetujuan untuk entitas ini.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Modul · Aksi</th>
                <th scope="col" className="num">
                  Mulai Jumlah
                </th>
                <th scope="col">Persetujuan</th>
                <th scope="col">Penyetuju</th>
                <th scope="col">Berlaku</th>
              </tr>
            </thead>
            <tbody>
              {approvalRules.map((rule) => (
                <tr key={rule.id}>
                  <td>
                    <code>
                      {rule.module} · {rule.action}
                    </code>
                  </td>
                  <td className="num" data-label="Mulai Jumlah">
                    {rule.min_amount === null
                      ? "Semua jumlah"
                      : formatMoney(String(rule.min_amount), entity.base_currency)}
                  </td>
                  <td data-label="Persetujuan">
                    {rule.requires_approval
                      ? rule.allow_self_approval
                        ? "Wajib (boleh menyetujui sendiri)"
                        : "Wajib"
                      : "Tidak wajib"}
                  </td>
                  <td data-label="Penyetuju">{approverLabel(rule.approver_role_id, roleNames)}</td>
                  <td data-label="Berlaku">
                    {rule.effective_from}
                    {rule.effective_to ? ` s.d. ${rule.effective_to}` : " dan seterusnya"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Pengaturan Lain</h2>
        </div>
        {negativeBalanceEditor}
        {otherSettings.length === 0 ? (
          negativeBalanceEditor ? null : (
            <p>Tidak ada pengaturan tambahan; semua memakai nilai bawaan sistem.</p>
          )
        ) : (
          <dl className="record-summary-grid">
            {otherSettings.map((setting) => (
              <Field
                key={setting.setting_key}
                label={entitySettingLabel(setting.setting_key)}
                value={entitySettingValueText(setting.setting_value)}
              />
            ))}
          </dl>
        )}
      </section>
    </div>
  );
}
