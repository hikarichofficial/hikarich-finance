import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  entityHasAccountingPeriods,
  getEntitySettingsOverview,
} from "@/services/settings/settings";
import { SettingsScreen } from "@/features/settings/SettingsScreen";
import { TimeSettingsForm } from "@/features/settings/TimeSettingsForm";

/** Settings (unbuilt-screens backlog, decision 243). Gated on `settings.view`, the permission
 * `numbering_sequences_select`/`approval_rules_select`/`entity_settings_select` RLS already require and
 * `navigation.ts` declares for this item. The numbering example uses the current UTC year. Holders of
 * `system.entity_config` (OWNER by default) can change the timezone and fiscal-year start (decision 248). */
export default async function SettingsPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("settings.view", { entityCode: entity });
  const entityId = membership.entity_id;
  const canEdit = can(access, entityId, "system.entity_config");

  const [overview, hasPeriods] = await Promise.all([
    getEntitySettingsOverview(entityId),
    canEdit ? entityHasAccountingPeriods(entityId) : Promise.resolve(null),
  ]);
  const here = entity ? `/admin/settings?entity=${encodeURIComponent(entity)}` : "/admin/settings";

  return (
    <SettingsScreen
      overview={overview}
      exampleYear={new Date().getUTCFullYear()}
      timeSettingsEditor={
        canEdit ? (
          <TimeSettingsForm
            entity={entity}
            timezone={overview.entity.timezone}
            fiscalYearStartMonth={overview.entity.fiscal_year_start_month}
            version={overview.entity.version}
            fiscalYearLocked={hasPeriods !== false}
            stepUpHref={`/auth/step-up?next=${encodeURIComponent(here)}`}
          />
        ) : null
      }
    />
  );
}
