import { requirePermission } from "@/services/identity/access";
import { getEntitySettingsOverview } from "@/services/settings/settings";
import { SettingsScreen } from "@/features/settings/SettingsScreen";

/** Settings (unbuilt-screens backlog, decision 243), read-only. Gated on `settings.view`, the permission
 * `numbering_sequences_select`/`approval_rules_select`/`entity_settings_select` RLS already require and
 * `navigation.ts` declares for this item. The numbering example uses the current UTC year. */
export default async function SettingsPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("settings.view", { entityCode: entity });

  const overview = await getEntitySettingsOverview(membership.entity_id);

  return <SettingsScreen overview={overview} exampleYear={new Date().getUTCFullYear()} />;
}
