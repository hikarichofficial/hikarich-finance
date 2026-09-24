import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  getEntityBaseCurrency,
  getJournalEntry,
  getJournalLines,
  getReversingJournal,
  listLedgerAccounts,
} from "@/services/accounting/ledger";
import { JournalDetailScreen } from "@/features/accounting/JournalDetailScreen";

/** Journal Detail (P13 Part 3d, Step 09 §10, §14). Permission to act is read off the currently active Entity
 * (`?entity=`), the same per-page pattern every other screen uses (decision 158); the database still
 * re-checks every action against the journal's own actual Entity regardless of what is active here. The
 * permission-to-action mapping mirrors each RPC's own check exactly (`post_journal`/`reverse_journal` ->
 * `accounting.journal_post`, `discard_journal_draft` -> `accounting.journal_create` -- see each RPC's body in
 * `20260921100100_p3_posting_engine.sql`). */
export default async function JournalDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("accounting.view", { entityCode: entity });

  const journal = await getJournalEntry(id).catch(() => null);
  if (!journal) notFound();

  const [lines, accounts, reversingJournal, baseCurrency] = await Promise.all([
    getJournalLines(id),
    listLedgerAccounts(membership.entity_id),
    getReversingJournal(id),
    getEntityBaseCurrency(membership.entity_id),
  ]);

  const entityId = membership.entity_id;
  const backHref = entity
    ? `/accounting/journal?entity=${encodeURIComponent(entity)}`
    : "/accounting/journal";

  return (
    <JournalDetailScreen
      journal={journal}
      lines={lines}
      accounts={accounts}
      reversingJournal={reversingJournal}
      baseCurrency={baseCurrency}
      entity={entity}
      backHref={backHref}
      permissions={{
        canPost: can(access, entityId, "accounting.journal_post"),
        canDiscard: can(access, entityId, "accounting.journal_create"),
        canReverse: can(access, entityId, "accounting.journal_post"),
      }}
    />
  );
}
