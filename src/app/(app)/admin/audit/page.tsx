import { requirePermission } from "@/services/identity/access";
import { getProfileNames, listAuditEvents } from "@/services/audit/audit";
import { parseAuditOffset, parseAuditOperation } from "@/domain/audit/audit";
import { AuditLogScreen } from "@/features/audit/AuditLogScreen";

/** Audit Log (unbuilt-screens backlog, decision 242). Gated on `audit.view`, the same permission
 * `audit_events_select` RLS checks for the row's Entity and `navigation.ts` declares for this item. */
export default async function AuditLogPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; op?: string; offset?: string }>;
}) {
  const { entity, op, offset: offsetParam } = await searchParams;
  const { membership } = await requirePermission("audit.view", { entityCode: entity });
  const operation = parseAuditOperation(op);
  const offset = parseAuditOffset(offsetParam);

  const page = await listAuditEvents({ entityId: membership.entity_id, operation, offset });
  const actorNames = await getProfileNames(
    page.rows.flatMap((row) => (row.actor_id ? [row.actor_id] : [])),
  );

  return (
    <AuditLogScreen
      rows={page.rows}
      actorNames={actorNames}
      activeOperation={operation}
      offset={offset}
      hasMore={page.hasMore}
      entity={entity}
    />
  );
}
