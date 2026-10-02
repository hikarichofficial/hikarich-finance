"use client";

import { SettlementForm, type SettlementAccountOption } from "@/features/shared/SettlementForm";
import { recordInvoicePaymentAction } from "./actions";

/** Record Payment on one issued invoice (decision 258). */
export function RecordPaymentForm({
  invoiceId,
  accounts,
  outstanding,
  today,
}: {
  invoiceId: string;
  accounts: readonly SettlementAccountOption[];
  outstanding: string;
  today: string;
}) {
  return (
    <SettlementForm
      action={recordInvoicePaymentAction}
      idName="invoice_id"
      id={invoiceId}
      accounts={accounts}
      outstanding={outstanding}
      today={today}
      openLabel="Catat Pembayaran"
      submitLabel="Simpan Pembayaran"
      accountLabel="Diterima di Rekening"
    />
  );
}
