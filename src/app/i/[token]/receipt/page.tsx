import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { PrintButton } from "@/features/sales/PrintButton";
import { ReceiptDocumentView } from "@/features/sales/ReceiptDocumentView";
import { getPublicReceipt } from "@/services/sales/public";

export const metadata: Metadata = {
  title: "Kwitansi",
  robots: { index: false, follow: false },
  referrer: "no-referrer",
};

export default async function PublicReceiptPage({
  params,
  searchParams,
}: {
  params: Promise<{ token: string }>;
  searchParams: Promise<{ no?: string }>;
}) {
  const { token } = await params;
  const { no } = await searchParams;
  const view = await getPublicReceipt(token, no ?? "");
  if (view.state !== "ok") notFound();

  return (
    <main className="doc-page">
      <div className="doc-actions no-print">
        <a href={`/i/${token}`}>← Kembali ke faktur</a>
        <PrintButton />
      </div>
      <ReceiptDocumentView receipt={view.receipt} />
    </main>
  );
}
