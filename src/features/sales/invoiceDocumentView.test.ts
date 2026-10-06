import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { DEFAULT_INVOICE_LAYOUT, moveBlock } from "@/domain/sales/invoiceLayout";
import { InvoiceDocumentView } from "./InvoiceDocumentView";
import type { InvoiceDocument } from "@/schemas/sales";

const LOGO = "data:image/png;base64,iVBORw0KGgo=";

function doc(overrides: Partial<InvoiceDocument> = {}): InvoiceDocument {
  return {
    invoice_number: "HKD-2026-0001",
    status: "issued",
    issue_date: "2026-10-06",
    due_date: "2026-10-20",
    currency: "IDR",
    subtotal: "500000",
    discount_total: "0",
    tax_total: "0",
    total: "500000",
    settled: "0",
    outstanding: "500000",
    settlement_status: "unpaid",
    is_overdue: false,
    refunded: "0",
    notes: null,
    terms: null,
    payment_note: null,
    issuer: { legal_name: "PT Hikarich Kitana Digital", brand_name: "PT Hikarich Kitana Digital" },
    customer: { display_name: "Penjualan Umum" },
    payment_instructions: {
      institution_name: "Bank Mandiri",
      account_number: "1234567890",
      account_holder: "PT Hikarich Kitana Digital",
      channel_name: "Xendit",
      payment_url: "https://pay.example.test/abc",
    },
    lines: [
      {
        line_no: 1,
        description: "Jasa konsultasi",
        quantity: "1",
        unit_price: "500000",
        discount_type: "none",
        discount_amount: "0",
        line_total: "500000",
      },
    ] as never,
    payments: [],
    ...overrides,
  } as InvoiceDocument;
}

function render(d: InvoiceDocument, logo?: string | null): string {
  return renderToStaticMarkup(createElement(InvoiceDocumentView, { doc: d, logo }));
}

describe("InvoiceDocumentView (decision 307)", () => {
  it("shows the logo beside the issuer and the name once when brand and legal name are equal", () => {
    const html = render(doc(), LOGO);
    expect(html).toContain('class="doc-logo"');
    expect(html).toContain(LOGO);
    expect(html.match(/PT Hikarich Kitana Digital/g)?.length).toBe(2); // brand heading + account holder
  });

  it("shows no logo image when none is set or when the value is not an embedded image", () => {
    expect(render(doc())).not.toContain("doc-logo");
    expect(render(doc(), "https://example.test/logo.png")).not.toContain("doc-logo");
  });

  it("offers a clickable payment link that opens safely", () => {
    const html = render(doc());
    expect(html).toContain('href="https://pay.example.test/abc"');
    expect(html).toContain('rel="noopener noreferrer"');
    expect(html).toContain('target="_blank"');
    expect(html).toContain("1234567890");
  });

  it("never turns a non-https address into a link", () => {
    const html = render(
      doc({ payment_instructions: { payment_url: "javascript:alert(1)", channel_name: "X" } }),
    );
    expect(html).not.toContain("javascript:");
    expect(html).not.toContain("doc-pay-link");
  });

  it("shows no payment block once the invoice is paid", () => {
    expect(render(doc({ settlement_status: "paid" }))).not.toContain("doc-pay-link");
  });

  it("keeps each total as a label and amount on one row, with Total last", () => {
    const html = render(doc());
    expect(html).toContain('<dl class="doc-totals"><div><dt>Subtotal</dt><dd>');
    expect(html.indexOf("<dt>Subtotal</dt>")).toBeLessThan(html.indexOf("<dt>Total</dt>"));
  });

  it("shows the legal name first and the brand name below it (OWNER, 6 October 2026)", () => {
    const html = render(
      doc({
        issuer: { legal_name: "PT Hikarich Kitana Digital", brand_name: "Kamar Kajian Market" },
      }),
    );
    expect(html.indexOf("PT Hikarich Kitana Digital")).toBeLessThan(
      html.indexOf("Kamar Kajian Market"),
    );
    expect(html).toMatch(
      /<h1 class="doc-brand">PT Hikarich Kitana Digital<\/h1><p>Kamar Kajian Market<\/p>/,
    );
    // a brand without a legal name still leads
    expect(render(doc({ issuer: { brand_name: "Merek Saja" } }))).toContain(">Merek Saja</h1>");
  });
});

describe("InvoiceDocumentView layout (decision 310)", () => {
  function order(html: string): string[] {
    return [...html.matchAll(/data-block="([a-z]+)"/g)].map((match) => match[1]!);
  }

  it("uses the standard arrangement when nothing is set", () => {
    const html = render(doc(), LOGO);
    expect(order(html).slice(0, 4)).toEqual(["logo", "issuer", "title", "customer"]);
    expect(html).toContain("doc-row-2");
  });

  it("follows the arrangement frozen into an issued invoice, not the standard", () => {
    const frozen = moveBlock(DEFAULT_INVOICE_LAYOUT, "title", 0);
    const html = render(doc({ issuer: { legal_name: "PT A", layout: frozen } as never }), LOGO);
    expect(order(html)[0]).toBe("title");
  });

  it("an explicit arrangement (a draft preview) wins over the frozen one", () => {
    const frozen = moveBlock(DEFAULT_INVOICE_LAYOUT, "title", 0);
    const explicit = moveBlock(DEFAULT_INVOICE_LAYOUT, "dates", 0);
    const html = renderToStaticMarkup(
      createElement(InvoiceDocumentView, {
        doc: doc({ issuer: { legal_name: "PT A", layout: frozen } as never }),
        layout: explicit,
      }),
    );
    expect(order(html)[0]).toBe("dates");
  });

  it("never lets a stored layout hide the amounts, and skips blocks that have nothing to show", () => {
    const hostile = {
      v: 1,
      blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((block) => ({ ...block, show: false })),
    };
    const html = render(doc({ issuer: { legal_name: "PT A", layout: hostile } as never }));
    expect(order(html)).toEqual(
      expect.arrayContaining(["issuer", "title", "customer", "dates", "lines", "totals"]),
    );
    expect(order(html)).not.toContain("notes"); // no notes on this invoice
    expect(order(html)).not.toContain("logo"); // no logo passed
  });
});
