import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { listTaxRuleVersions } from "@/services/tax/tax";
import { ruleFormDefaults } from "@/domain/tax/ruleAuthoring";
import { TaxRuleForm } from "@/features/tax/TaxRuleForm";
import { todayInBusinessZone } from "@/lib/time";

/** New tax rule draft, or a new version of an existing rule, or editing a draft (decision 249). Gated on
 * `tax.manage_rules`, which `tax_rule_draft_save` itself checks. `?from=<id>` copies a published rule into
 * a new version; `?draft=<id>` edits a draft; neither starts a brand-new rule. */
export default async function NewTaxRulePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; from?: string; draft?: string }>;
}) {
  const { entity, from, draft } = await searchParams;
  await requirePermission("tax.manage_rules", { entityCode: entity });

  const baseId = draft ?? from ?? null;
  const rows = baseId ? await listTaxRuleVersions() : [];
  const base = baseId ? (rows.find((r) => r.id === baseId) ?? null) : null;
  if (baseId && !base) notFound();
  if (draft && base?.status !== "draft") notFound();

  const mode = draft ? "edit_draft" : from ? "new_version" : "new_rule";
  const defaults = ruleFormDefaults(base, mode, todayInBusinessZone());
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const cancelHref = base ? `/tax/rules/${base.id}${qs}` : `/tax/rules${qs}`;
  const here = `/tax/rules/new?${new URLSearchParams({
    ...(entity ? { entity } : {}),
    ...(draft ? { draft } : {}),
    ...(from ? { from } : {}),
  }).toString()}`;
  const title =
    mode === "edit_draft"
      ? `Ubah draf ${base?.code} v${base?.rule_version}`
      : mode === "new_version"
        ? `Versi baru ${base?.code}`
        : "Aturan pajak baru";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={cancelHref}>← Kembali</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pajak · Aturan</p>
          <h1>{title}</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <TaxRuleForm
          defaults={defaults}
          entity={entity}
          stepUpHref={`/auth/step-up?next=${encodeURIComponent(here)}`}
          cancelHref={cancelHref}
        />
      </section>
    </div>
  );
}
