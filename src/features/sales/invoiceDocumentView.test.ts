import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { DEFAULT_INVOICE_LAYOUT, updateBlock } from "@/domain/sales/invoiceLayout";
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

describe("InvoiceDocumentView layout (decision 321)", () => {
  function order(html: string): string[] {
    return [...html.matchAll(/data-block="([a-z]+)"/g)].map((match) => match[1]!);
  }

  it("uses the standard arrangement when nothing is set: the original look", () => {
    const html = render(doc(), LOGO);
    // (drawn in the order of the page: a block, what follows it, then the next block)
    expect(order(html).slice(0, 5)).toEqual(["logo", "issuer", "customer", "dates", "title"]);
    // the company name sits under the logo, the title at the right of it
    expect(html).toMatch(/data-node="title" style="--x:60;--w:40;--y:8;--z:1"/);
    expect(html).toMatch(/data-node="issuer" style="--x:0;--w:52;--y:8;--z:1"/);
    // the item table is the whole width in a zone of its own
    expect(html).toMatch(/data-zone="table"[^>]*><div class="doc-node" data-node="lines"/);
  });

  it("draws a block that follows another one inside it, so it stays under it whatever its height", () => {
    const html = render(doc(), LOGO);
    const logo = html.indexOf('data-node="logo"');
    const issuer = html.indexOf('data-node="issuer"');
    const children = html.indexOf('class="doc-children"');
    expect(logo).toBeLessThan(children);
    expect(children).toBeLessThan(issuer);
  });

  it("without a logo the company name takes the logo's place at the top", () => {
    const html = render(doc());
    expect(html).not.toContain('data-node="logo"');
    // issuer and title are now blocks of the zone itself, at the logo's own offset
    expect(html).toMatch(
      /data-zone="head"[^>]*><div class="doc-node" data-node="issuer" style="--x:0;--w:52;--y:0/,
    );
  });

  it("sets the text size and the minimum height of a block", () => {
    const layout = updateBlock(
      updateBlock(DEFAULT_INVOICE_LAYOUT, "customer", { size: "xl", h: 120, valign: "middle" }),
      "totals",
      { size: "sm" },
    );
    const html = renderToStaticMarkup(createElement(InvoiceDocumentView, { doc: doc(), layout }));
    expect(html).toContain('data-node="customer" style="--x:0;--w:48;--y:24;--z:1.35"');
    expect(html).toContain('data-valign="middle" style="--bh:120px"');
    expect(html).toContain("--z:0.9");
  });

  it("follows the arrangement frozen into an issued invoice, not the standard", () => {
    const frozen = updateBlock(DEFAULT_INVOICE_LAYOUT, "title", { x: 10, w: 30 });
    const html = render(doc({ issuer: { legal_name: "PT A", layout: frozen } as never }), LOGO);
    expect(html).toContain('data-node="title" style="--x:10;--w:30');
  });

  it("an explicit arrangement (a draft preview) wins over the frozen one", () => {
    const frozen = updateBlock(DEFAULT_INVOICE_LAYOUT, "title", { x: 10, w: 30 });
    const explicit = updateBlock(DEFAULT_INVOICE_LAYOUT, "title", { x: 20, w: 20 });
    const html = renderToStaticMarkup(
      createElement(InvoiceDocumentView, {
        doc: doc({ issuer: { legal_name: "PT A", layout: frozen } as never }),
        layout: explicit,
      }),
    );
    expect(html).toContain('data-node="title" style="--x:20;--w:20');
  });

  it("shows the standard for an invoice frozen with the old grid layout (version 1)", () => {
    const old = { v: 1, grid: 24, blocks: [] };
    const html = render(doc({ issuer: { legal_name: "PT A", layout: old } as never }), LOGO);
    expect(html).toMatch(/data-node="title" style="--x:60;--w:40;--y:8/);
  });

  it("never lets a stored layout hide the amounts, and skips blocks that have nothing to show", () => {
    const hostile = {
      v: 2,
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
