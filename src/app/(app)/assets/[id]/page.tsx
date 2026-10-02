import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getAsset, getEntityBaseCurrency } from "@/services/assets/assets";
import { getMoneyControl } from "@/services/money/money";
import { AssetDetailScreen } from "@/features/assets/AssetDetailScreen";
import {
  ActivateAssetForm,
  AssetConditionForm,
  AssetFiscalClassForm,
  CancelAssetForm,
  DisposeAssetForm,
  ReplanAssetForm,
  ReverseDepreciationForm,
  ReverseDisposalForm,
  TransferAssetForm,
  UpdateAssetDetailsForm,
} from "@/features/assets/AssetForms";
import { formatMonth } from "@/features/assets/format";

/** Asset Detail (P13 Part 3f, first increment, Step 09 §10, §16). The write forms are shown with
 * `assets.manage` -- the permission every P8 asset command checks -- and only in the statuses where the
 * command accepts the asset (`20260926100300_p8_asset_lifecycle.sql`); the database checks both again. */
export default async function AssetDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("assets.view", { entityCode: entity });

  const detail = await getAsset({ asset_id: id }).catch(() => null);
  if (!detail) notFound();

  const currency = await getEntityBaseCurrency(membership.entity_id);
  const backHref = entity ? `/assets?entity=${encodeURIComponent(entity)}` : "/assets";

  const { asset, schedule, disposal } = detail;
  const canManage = can(access, membership.entity_id, "assets.manage");
  const next = entity ? `/assets/${id}?entity=${encodeURIComponent(entity)}` : `/assets/${id}`;
  const today = new Date().toISOString().slice(0, 10);
  const isDraft = asset.status === "draft";
  const isActive = asset.status === "active";
  const inHand = isDraft || isActive;
  const postedLines = schedule
    .filter((line) => line.status === "posted")
    .map((line) => ({ id: line.id, label: formatMonth(line.month) }));
  const accounts =
    canManage && isActive ? await getMoneyControl(membership.entity_id).catch(() => []) : [];

  return (
    <AssetDetailScreen
      detail={detail}
      currency={currency}
      entity={entity}
      backHref={backHref}
      actionsPanel={
        canManage && asset.status !== "cancelled" ? (
          <>
            {isDraft ? (
              <ActivateAssetForm
                assetId={id}
                next={next}
                today={today}
                depreciable={membership.entity_type !== "personal"}
                name={asset.name}
                cost={asset.acquisition_cost}
                currency={currency}
              />
            ) : null}
            <UpdateAssetDetailsForm
              assetId={id}
              next={next}
              name={asset.name}
              description={asset.description}
              serialNumber={asset.serial_number}
            />
            {inHand ? (
              <AssetConditionForm
                assetId={id}
                next={next}
                today={today}
                condition={asset.condition}
              />
            ) : null}
            {inHand ? <TransferAssetForm assetId={id} next={next} today={today} /> : null}
            {!isDraft ? (
              <AssetFiscalClassForm
                assetId={id}
                next={next}
                fiscalClass={asset.fiscal_class_key}
                fiscalMethod={asset.fiscal_method}
              />
            ) : null}
            {isActive && asset.depreciation_method !== "none" ? (
              <ReplanAssetForm
                assetId={id}
                next={next}
                method={asset.depreciation_method}
                residual={asset.residual_value}
              />
            ) : null}
            {isActive && postedLines.length > 0 ? (
              <ReverseDepreciationForm assetId={id} next={next} today={today} lines={postedLines} />
            ) : null}
            {isActive ? (
              <DisposeAssetForm
                assetId={id}
                next={next}
                today={today}
                accounts={accounts
                  .filter((a) => a.is_active)
                  .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` }))}
              />
            ) : null}
            {disposal && disposal.status === "posted" ? (
              <ReverseDisposalForm
                assetId={id}
                disposalId={disposal.id}
                next={next}
                today={today}
              />
            ) : null}
            {inHand && postedLines.length === 0 ? (
              <CancelAssetForm assetId={id} next={next} />
            ) : null}
          </>
        ) : undefined
      }
    />
  );
}
