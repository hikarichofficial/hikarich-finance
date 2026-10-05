import type { EmailDeliveryRow } from "@/services/email/deliveries";

const SENT_AT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  timeZone: "Asia/Makassar",
});

/** "Riwayat Pengiriman Email" of an invoice or a payment receipt: what went out, to whom and when. Sending again
 * is done with the form on the same page; each attempt adds a row here. */
export function EmailHistory({
  rows,
  emptyText,
}: {
  rows: readonly EmailDeliveryRow[];
  emptyText: string;
}) {
  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Riwayat Pengiriman Email</h2>
      </div>
      {rows.length === 0 ? (
        <p className="dashboard-empty">{emptyText}</p>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Waktu (WITA)</th>
              <th scope="col">Tujuan</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id}>
                <td>{SENT_AT.format(new Date(row.sent_at))} WITA</td>
                <td data-label="Tujuan">{row.recipient}</td>
                <td data-label="Status">
                  <span
                    className={`status-badge status-badge-${row.status === "sent" ? "success" : "critical"}`}
                  >
                    {row.status === "sent" ? "Terkirim" : "Gagal"}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
