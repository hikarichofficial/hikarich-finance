import { formatMoney } from "@/domain/money/format";
import { groupTurnoverView } from "@/domain/tax/personalTax";
import type { TaxGroupTurnover } from "@/schemas/personalTax";

/**
 * "Omzet gabungan" (decision 365): the owner's books count together toward the Rp 4,8 miliar ceiling of the
 * final tax, so every Ringkasan Pajak shows this book and the owner's other books side by side, read by the
 * system -- nothing to fill in. Shown only when the owner has another book.
 */
export function GroupTurnoverCard({
  group,
  currency,
  ownName,
}: {
  group: TaxGroupTurnover;
  currency: string;
  ownName: string;
}) {
  if (group.others.length === 0) return null;
  const view = groupTurnoverView(group, ownName);
  if (!view) return null;
  const money = (v: string) => formatMoney(v, currency);
  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Omzet gabungan {group.year}</h2>
        <span className="delta-chip" data-tone={view.over ? "bad" : undefined}>
          {Math.round(Number(view.share) * 100)}%
        </span>
      </div>
      <div className="pp-meter" data-tone={view.over ? "bad" : undefined} aria-hidden="true">
        <span style={{ width: `${Number(view.share) * 100}%` }} />
      </div>
      <ul className="pp-parts">
        {view.parts.map((part) => (
          <li key={part.name}>
            <span>{part.name}</span>
            <strong>{money(part.turnover)}</strong>
          </li>
        ))}
        <li data-total="true">
          <span>Total · batas {money(view.ceiling)}</span>
          <strong>{money(view.total)}</strong>
        </li>
      </ul>
      <p className="hint">
        {view.over
          ? "Omzet gabungan melewati batas: PPh Final UMKM tidak berlaku lagi untuk sisa tahun ini."
          : "Semua buku Anda dijumlahkan otomatis untuk batas PPh Final UMKM."}
      </p>
    </section>
  );
}
