import Link from "next/link";
import type { AttentionItem, AttentionKind } from "@/domain/dashboard/dashboard";
import { formatShortDate } from "./format";

const KIND_LABEL: Readonly<Record<AttentionKind, string>> = {
  tax_review: "Tinjau Pajak",
  missing_evidence: "Bukti Belum Lengkap",
  reconciliation: "Rekonsiliasi",
};

const KIND_HREF: Readonly<Record<AttentionKind, string>> = {
  tax_review: "/tax",
  missing_evidence: "/documents/evidence",
  reconciliation: "/money/reconciliation",
};

const KIND_BADGE: Readonly<Record<AttentionKind, string>> = {
  tax_review: "status-badge-attention",
  missing_evidence: "status-badge-attention",
  reconciliation: "status-badge-progress",
};

/**
 * Tasks & Attention (Step 09 §8, Step 10 §10): the single prioritized list `buildAttentionItems` already
 * merged from the tax review queue, missing purchase evidence and open/unresolved reconciliations. Scope
 * (DECISIONS #163): pending invoice/bill approvals are deferred to Part 3, so this list is not yet the
 * complete "confirmation, approval, reconciliation, missing evidence or review" set the spec names -- only
 * the sources this Dashboard slice already has services for.
 */
export function TasksAttention({ items }: { items: readonly AttentionItem[] }) {
  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Perlu Perhatian</h2>
      </div>
      {items.length === 0 ? (
        <p className="dashboard-empty">Tidak ada yang perlu ditindaklanjuti saat ini.</p>
      ) : (
        <ul className="dashboard-list">
          {items.map((item) => (
            <li key={`${item.kind}-${item.id}`} className="dashboard-list-item">
              <div>
                <p className="dashboard-list-item-title">
                  <Link href={KIND_HREF[item.kind]}>{item.title}</Link>
                </p>
                <p className="dashboard-list-item-detail">{item.detail}</p>
              </div>
              <div className="dashboard-list-item-end">
                <span className={`status-badge ${KIND_BADGE[item.kind]}`}>
                  {KIND_LABEL[item.kind]}
                </span>
                {item.date ? (
                  <span className="dashboard-list-item-date">{formatShortDate(item.date)}</span>
                ) : null}
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
