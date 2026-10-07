import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { KpiStrip } from "./KpiStrip";

// Decision 331: every card opens the page its title names, for the month the dashboard shows.
describe("KpiStrip destinations", () => {
  const html = renderToStaticMarkup(
    createElement(KpiStrip, {
      currency: "IDR",
      period: { start: "2026-10-01", end: "2026-10-31" },
      finance: { revenue: "875000", discounts: "125000", expense: "300000", netResult: "575000" },
      cash: null,
      receivables: null,
      payables: null,
    }),
  );

  it("opens the Laba Rugi report of the dashboard month, at the matching section", () => {
    expect(html).toContain(
      "/reports?statement=pnl&amp;from=2026-10-01&amp;to=2026-10-31#pnl-revenue",
    );
    expect(html).toContain(
      "/reports?statement=pnl&amp;from=2026-10-01&amp;to=2026-10-31#pnl-expense",
    );
    expect(html).toContain('/reports?statement=pnl&amp;from=2026-10-01&amp;to=2026-10-31"');
  });

  it("says revenue is already net of discounts", () => {
    expect(html).toContain("Sudah dikurangi diskon");
  });
});
