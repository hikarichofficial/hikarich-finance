import type { InvoiceDocument } from "@/schemas/sales";

/** A made-up invoice for the layout editor's preview (decision 310). It carries the company's real names and
 * address so the arrangement looks like the real thing, and sample customer, items and payment details so every
 * block has something to show. Nothing here is stored. */
export function sampleInvoiceDocument(issuer: Record<string, unknown>): InvoiceDocument {
  return {
    invoice_number: "INV-2026-0001",
    status: "issued",
    issue_date: "2026-10-06",
    due_date: "2026-10-20",
    currency: "IDR",
    subtotal: "1500000",
    discount_total: "100000",
    tax_total: "154000",
    total: "1554000",
    settled: "500000",
    outstanding: "1054000",
    settlement_status: "partial",
    is_overdue: false,
    refunded: "0",
    notes: "Terima kasih atas kepercayaan Anda. (Contoh catatan)",
    terms: "Pembayaran paling lambat pada tanggal jatuh tempo. (Contoh syarat)",
    payment_note: null,
    issuer,
    customer: {
      display_name: "Contoh Pelanggan",
      legal_name: "PT Contoh Pelanggan Sejahtera",
      address_line: "Jl. Contoh No. 1",
      city: "Jakarta",
    },
    payment_instructions: {
      institution_name: "Bank Contoh",
      account_number: "1234567890",
      account_holder: "Nama Pemilik Rekening",
      channel_name: "Transfer bank",
    },
    lines: [
      {
        line_no: 1,
        description: "Jasa konsultasi",
        quantity: "1",
        unit_price: "1000000",
        discount_type: "none",
        discount_value: "0",
        discount_amount: "0",
        tax_amount: "110000",
        line_total: "1000000",
      },
      {
        line_no: 2,
        description: "Paket produk",
        quantity: "2",
        unit_price: "250000",
        discount_type: "fixed",
        discount_value: "100000",
        discount_amount: "100000",
        tax_amount: "44000",
        line_total: "400000",
      },
    ],
    payments: [
      {
        receipt_number: "KW-2026-0001",
        payment_date: "2026-10-07",
        amount: "500000",
        currency: "IDR",
      },
    ],
  } as InvoiceDocument;
}
