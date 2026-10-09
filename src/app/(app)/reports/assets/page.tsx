import { redirect } from "next/navigation";
import { reportSubrouteHref } from "@/domain/reports/reports";

/** `/reports/assets` nav sub-item (decision 393): forwards to the Kontrol Aset Tetap tab, keeping the active
 * Entity. Access is enforced by the target page's own `requirePermission`, not repeated here. */
export default async function ReportsAssetsRedirectPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  redirect(reportSubrouteHref("assets", entity));
}
