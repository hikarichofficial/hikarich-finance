import { redirect } from "next/navigation";
import { reportSubrouteHref } from "@/domain/reports/reports";

/** `/reports/tax` nav sub-item (decision 244, OWNER's choice of destination): forwards to the screen that
 * already shows this content, keeping the active Entity. Access is enforced by the target page's own
 * `requirePermission`, not repeated here. */
export default async function ReportsTaxRedirectPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  redirect(reportSubrouteHref("tax", entity));
}
