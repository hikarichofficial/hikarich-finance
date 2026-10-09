import { redirect } from "next/navigation";
import { reportSubrouteHref } from "@/domain/reports/reports";

/** `/reports/loans` nav sub-item (decision 393): forwards to the Ringkasan Pinjaman tab, keeping the active
 * Entity. Access is enforced by the target page's own `requirePermission`, not repeated here. */
export default async function ReportsLoansRedirectPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  redirect(reportSubrouteHref("loans", entity));
}
