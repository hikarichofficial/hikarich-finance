import { requirePermission } from "@/services/identity/access";
import { ImportWizardForm } from "@/features/imports/ImportWizardForm";
import { BackLink } from "@/features/shell/BackLink";

/** Import Wizard (Step 15 §15, decision 275): stage and validate a pasted or uploaded table. */
export default async function NewImportPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  await requirePermission("system.import", { entityCode: entity });
  const backHref = entity
    ? `/admin/imports?entity=${encodeURIComponent(entity)}`
    : "/admin/imports";
  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke riwayat impor</BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <h1>Impor Data</h1>
        </div>
      </header>
      <ImportWizardForm entity={entity} />
    </div>
  );
}
