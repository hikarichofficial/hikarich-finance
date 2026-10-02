"use client";

import { SettlementForm, type SettlementAccountOption } from "@/features/shared/SettlementForm";
import { payBillAction } from "./actions";

/** Pay one approved bill (decision 258). */
export function PayBillForm({
  billId,
  accounts,
  outstanding,
  today,
}: {
  billId: string;
  accounts: readonly SettlementAccountOption[];
  outstanding: string;
  today: string;
}) {
  return (
    <SettlementForm
      action={payBillAction}
      idName="bill_id"
      id={billId}
      accounts={accounts}
      outstanding={outstanding}
      today={today}
      openLabel="Bayar Tagihan"
      submitLabel="Simpan Pembayaran"
      accountLabel="Dibayar dari Rekening"
    />
  );
}
