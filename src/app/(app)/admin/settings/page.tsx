import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  entityHasAccountingPeriods,
  getEntitySettingsOverview,
} from "@/services/settings/settings";
import { SettingsScreen } from "@/features/settings/SettingsScreen";
import { CreateEntityForm } from "@/features/settings/CreateEntityForm";
import { EntityIdentityForm } from "@/features/settings/EntityIdentityForm";
import { NegativeBalanceBlockForm } from "@/features/settings/NegativeBalanceBlockForm";
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
  const negativeBalanceValue = overview.settings.find(
    (s) => s.setting_key === "money.block_negative_balance",
  )?.setting_value;
  const blockedKinds = Array.isArray(negativeBalanceValue)
    ? (negativeBalanceValue as string[])
    : [];

  return (
    <SettingsScreen
      overview={overview}
      exampleYear={new Date().getUTCFullYear()}
      identityEditor={
        canEdit ? (
          <EntityIdentityForm
            entity={entity}
            legalName={overview.entity.legal_name}
            brandName={overview.entity.brand_name}
            profile={overview.profile}
            version={overview.entity.version}
            stepUpHref={`/auth/step-up?next=${encodeURIComponent(here)}`}
          />
        ) : null
      }
      createEntityEditor={
        membership.role_key === "owner" ? (
          <CreateEntityForm stepUpHref={`/auth/step-up?next=${encodeURIComponent(here)}`} />
        ) : null
      }
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
      negativeBalanceEditor={
        canEdit ? (
          <NegativeBalanceBlockForm
            entity={entity}
            blockedKinds={blockedKinds}
            stepUpHref={`/auth/step-up?next=${encodeURIComponent(here)}`}
          />
        ) : null
      }
    />
  );
}
