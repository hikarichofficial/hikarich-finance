import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listBackupHistory } from "@/services/backup/backup";
import { backupReminderMessage, daysSinceLastBackup } from "@/domain/backup/backup";
import { BackupRestoreScreen } from "@/features/backup/BackupRestoreScreen";

/**
 * Backup & Restore Center (P14, Step 01 #36, Step 16 §34, decision 224), Part 1. Gated on
 * `backup.create` -- the same "gate the page on the create RPC's own permission" shape every other
 * `/new` page already establishes -- since export is this screen's primary action; `backup.restore`
 * (checked separately below, via `can`, the same precedent `NewTransferPage`'s own `canConfirmOnCreate`
 * already set for a second permission beyond the page's own gate) only reveals the read-only
 * validate-before-restore section. Today only OWNER holds either permission (the P2 catalog's own
 * `backup.create`/`backup.restore` keys were never granted to any other role template), via
 * `app_authz.has_permission`'s owner-bypass rule -- no migration change was needed to reach that.
 */
export default async function BackupRestorePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("backup.create", { entityCode: entity });
  const entityId = membership.entity_id;

  const history = await listBackupHistory(entityId);
  const reminder = backupReminderMessage(
    daysSinceLastBackup(history[0]?.created_at ?? null, new Date()),
  );

  return (
    <BackupRestoreScreen
      entityId={entityId}
      history={history}
      reminder={reminder}
      canRestore={can(access, entityId, "backup.restore")}
    />
  );
}
