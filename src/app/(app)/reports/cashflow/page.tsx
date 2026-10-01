import { redirect } from "next/navigation";
import { reportSubrouteHref } from "@/domain/reports/reports";

/** `/reports/cashflow` nav sub-item (decision 240): its content already ships as a `/reports?statement=` tab
 * (P13 Part 4), so this route only forwards there, keeping the active Entity. Access is enforced by the
 * target page's own `requirePermission`, not repeated here. */
export default async function ReportsCashflowRedirectPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  redirect(reportSubrouteHref("cashflow", entity));
}
