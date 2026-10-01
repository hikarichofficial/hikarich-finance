import Link from "next/link";
import { RULE_STATUS_LABELS, RULE_STATUS_TONE, RULE_VERIFICATION_LABELS } from "@/domain/tax/tax";
import { ruleFamilyLabel } from "@/domain/tax/taxRulesList";
import type { TaxRuleVersionRow } from "@/schemas/tax";
import { formatShortDate } from "./format";

/**
 * Tax Rule Detail (decision 239, Step 05 §13): one version of one rule code, read-only -- its parameters,
 * legal source, verification and publish/discard history, plus every other version of the same code so a
 * viewer can see how the rule changed over time. No per-rule RPC exists, so the page looks the row up from
 * the same `listTaxRuleVersions` read the List screen uses, the `PeriodClosePage`/`CustomerDetailPage`
 * precedent for a Detail screen with no dedicated single-row RPC.
 */
export function TaxRuleDetailScreen({
  rule,
  siblings,
  backHref,
  entity,
}: {
  rule: TaxRuleVersionRow;
  siblings: readonly TaxRuleVersionRow[];
  backHref: string;
  entity: string | undefined;
}) {
  const otherVersions = siblings.filter((v) => v.id !== rule.id);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke aturan pajak</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pajak · Aturan · {ruleFamilyLabel(rule.family)}</p>
          <h1>
            {rule.code} · v{rule.rule_version}
            {rule.is_repeal ? " (pencabutan)" : ""}
          </h1>
        </div>
        <span className={`status-badge status-badge-${RULE_STATUS_TONE[rule.status]}`}>
          {RULE_STATUS_LABELS[rule.status]}
        </span>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Berlaku Sejak</dt>
            <dd>{formatShortDate(rule.effective_from)}</dd>
          </div>
          <div>
            <dt>Verifikasi</dt>
            <dd>{RULE_VERIFICATION_LABELS[rule.verification_status]}</dd>
          </div>
          <div>
            <dt>Diverifikasi Pada</dt>
            <dd>{formatShortDate(rule.verified_on)}</dd>
          </div>
          <div>
            <dt>Diterbitkan Pada</dt>
            <dd>{rule.published_at ? formatShortDate(rule.published_at.slice(0, 10)) : "—"}</dd>
          </div>
          {rule.status === "discarded" ? (
            <>
              <div>
                <dt>Dibatalkan Pada</dt>
                <dd>{rule.discarded_at ? formatShortDate(rule.discarded_at.slice(0, 10)) : "—"}</dd>
              </div>
              <div>
                <dt>Alasan Pembatalan</dt>
                <dd>{rule.discard_reason ?? "—"}</dd>
              </div>
            </>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Sumber Hukum</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Judul Sumber</dt>
            <dd>{rule.source_title}</dd>
          </div>
          <div>
            <dt>Referensi</dt>
            <dd>{rule.source_ref}</dd>
          </div>
          <div>
            <dt>Tautan</dt>
            <dd>
              {rule.source_url ? (
                <a href={rule.source_url} target="_blank" rel="noopener noreferrer">
                  Buka sumber →
                </a>
              ) : (
                "—"
              )}
            </dd>
          </div>
          {rule.notes ? (
            <div>
              <dt>Catatan</dt>
              <dd>{rule.notes}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Parameter</h2>
        </div>
        <pre className="record-raw-block">{JSON.stringify(rule.params, null, 2)}</pre>
      </section>

      {otherVersions.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Versi Lain dari Kode Ini</h2>
          </div>
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Versi</th>
                <th scope="col">Berlaku Sejak</th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {otherVersions.map((version) => {
                const versionHref = entity
                  ? `/tax/rules/${version.id}?entity=${encodeURIComponent(entity)}`
                  : `/tax/rules/${version.id}`;
                return (
                  <tr key={version.id}>
                    <td>
                      <Link href={versionHref}>v{version.rule_version}</Link>
                    </td>
                    <td data-label="Berlaku Sejak">{formatShortDate(version.effective_from)}</td>
                    <td data-label="Status">
                      <span
                        className={`status-badge status-badge-${RULE_STATUS_TONE[version.status]}`}
                      >
                        {RULE_STATUS_LABELS[version.status]}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </section>
      ) : null}
    </div>
  );
}
