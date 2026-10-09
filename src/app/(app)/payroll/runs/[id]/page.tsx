import { formatMoney } from "@/domain/money/format";
import { PAYROLL_PAYMENT_KIND_LABELS } from "@/domain/payroll/payroll";
import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { AuthzError } from "@/domain/authz/errors";
import { requireAccess } from "@/services/identity/access";
import {
  getEntityBaseCurrency,
  getPayrollLines,
  getPayrollRun,
  listEmployees,
  listPayrollAdjustments,
  listPayrollPayments,
} from "@/services/payroll/payroll";
import { getMoneyControl } from "@/services/money/money";
import { PayrollRunDetailScreen } from "@/features/payroll/PayrollRunDetailScreen";
import {
  AdjustmentForm,
  PayrollPaymentForm,
  RemoveAdjustmentForm,
  ReversePayrollPaymentForm,
  RunCommandForm,
} from "@/features/payroll/PayrollRunForms";
import { todayInBusinessZone } from "@/lib/time";
import { prorataFor } from "@/domain/payroll/prorata";
import { formatShortDate } from "@/features/payroll/format";
import type { AdjustmentEmployee } from "@/features/payroll/PayrollRunForms";

/**
 * Payroll Run Detail (P13 Part 3g, second increment, Step 09 §17). Same compound-permission rule as the
 * Register page (`payroll.compensation_view` AND at least one of `payroll.run`/`payroll.approve`/`payroll.pay`,
 * confirmed against `20260927100700_p9_payroll_reports.sql`'s own `app_private.payroll_read_authorize`), so
 * `requireAccess` + a manual `can()` check stands in for `requirePermission` here too. `getPayrollRun` is
 * caught rather than let through: a nonexistent run id reaches the database as a null-entity row, which
 * `payroll_read_authorize` itself turns into `FORBIDDEN` (not a distinct not-found signal) -- the same
 * forgiving catch-all `.catch(() => null)` + `notFound()` every other Detail page already uses (Equity Detail,
 * Loan Detail, Account Detail) means a cross-Entity or missing id reads identically as "not found" either way.
 *
 * The command forms follow the status rules and permissions of the RPCs themselves
 * (`20260927100500_p9_payroll_workflow.sql`, `20260927100600_p9_payroll_payments.sql`): `payroll.run` for
 * calculate / adjust / submit / discard, `payroll.approve` for approve / post / close / reopen / correct,
 * either of the two for return, `payroll.pay` for paying and reversing a payment. The database still decides.
 */
export default async function PayrollRunDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });
  const entityId = membership.entity_id;

  const canRead =
    can(access, entityId, "payroll.compensation_view") &&
    (can(access, entityId, "payroll.run") ||
      can(access, entityId, "payroll.approve") ||
      can(access, entityId, "payroll.pay"));
  if (!canRead) throw new AuthzError("FORBIDDEN");

  const run = await getPayrollRun(id).catch(() => null);
  if (!run) notFound();

  const [lines, adjustments, payments, currency] = await Promise.all([
    getPayrollLines(id),
    listPayrollAdjustments(id),
    listPayrollPayments(id),
    getEntityBaseCurrency(entityId),
  ]);

  const canRun = can(access, entityId, "payroll.run");
  const canApprove = can(access, entityId, "payroll.approve");
  const canPay = can(access, entityId, "payroll.pay");
  const status = run.status;
  const editable = status === "draft" || status === "calculated";
  const payable = status === "posted" || status === "partially_paid" || status === "paid";
  const today = todayInBusinessZone();

  const showCalculate = canRun && editable;
  const showSubmit = canRun && status === "calculated";
  const showApprove = canApprove && status === "submitted";
  const showReturn = (canRun || canApprove) && (status === "submitted" || status === "approved");
  const showPost = canApprove && status === "approved";
  const showPay = canPay && payable;
  const showClose =
    canApprove && (status === "paid" || (status === "posted" && Number(run.net_pay_total) === 0));
  const showReopen = canApprove && status === "closed";
  const showCorrect = canApprove && payable;
  const showDiscard = canRun && (editable || status === "submitted" || status === "approved");

  // An adjustment needs an employee of this payroll month: the calculated lines when there are any,
  // otherwise the active employees (only for a viewer who may list them).
  const activeEmployees =
    showCalculate && lines.length === 0 && can(access, entityId, "payroll.employee_view")
      ? await listEmployees({ entity_id: entityId, include_ended: false }).catch(() => [])
      : [];
  // The pro-rata offer needs each employee's join/exit dates, which the payroll lines do not carry, so the
  // register is read once more when there are lines to match it against (decision 388). Without
  // `payroll.employee_view` there are no dates and so no offer -- the adjustment is simply typed by hand.
  const dated =
    lines.length > 0 && can(access, entityId, "payroll.employee_view")
      ? await listEmployees({ entity_id: entityId, include_ended: true }).catch(() => [])
      : [];
  const datesById = new Map(dated.map((e) => [e.id, e]));

  const adjustmentEmployees: AdjustmentEmployee[] =
    lines.length > 0
      ? lines.map((l) => {
          const who = datesById.get(l.employee_id);
          const figures = who
            ? prorataFor(
                {
                  periodStart: run.period_start,
                  periodEnd: run.period_end,
                  joinDate: who.join_date,
                  exitDate: who.exit_date,
                  grossPay: l.gross_pay,
                },
                currency,
              )
            : null;
          const startsLate = who ? who.join_date > run.period_start : false;
          return {
            id: l.employee_id,
            label: `${l.employee_code} — ${l.employee_name}`,
            prorata: figures
              ? {
                  ...figures,
                  grossPay: l.gross_pay,
                  reason: startsLate
                    ? `Mulai bekerja ${formatShortDate(who!.join_date)}`
                    : `Berhenti ${formatShortDate(who!.exit_date ?? run.period_end)}`,
                }
              : null,
          };
        })
      : activeEmployees.map((e) => ({
          id: e.id,
          label: `${e.employee_code} — ${e.full_name}`,
          prorata: null,
        }));
  const accounts = showPay ? await getMoneyControl(entityId).catch(() => []) : [];
  const confirmedPayments = payments.filter((p) => p.status === "confirmed");
  const hasActions =
    showCalculate ||
    showSubmit ||
    showApprove ||
    showReturn ||
    showPost ||
    showPay ||
    showClose ||
    showReopen ||
    showCorrect ||
    showDiscard;

  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const backHref = `/payroll/runs${qs}`;

  return (
    <PayrollRunDetailScreen
      run={run}
      lines={lines}
      adjustments={adjustments}
      payments={payments}
      currency={currency}
      backHref={backHref}
      qs={qs}
      actionsPanel={
        hasActions ? (
          <div
            style={{ display: "flex", flexWrap: "wrap", gap: "0.75rem", alignItems: "flex-start" }}
          >
            {showCalculate ? <RunCommandForm runId={id} command="calculate" today={today} /> : null}
            {showCalculate && adjustmentEmployees.length > 0 ? (
              <AdjustmentForm runId={id} employees={adjustmentEmployees} currency={currency} />
            ) : null}
            {showCalculate && adjustments.length > 0 ? (
              <RemoveAdjustmentForm
                runId={id}
                adjustments={adjustments.map((a) => ({
                  id: a.adjustment_id,
                  label: `${a.employee_code} — ${a.label} (${a.amount})`,
                }))}
              />
            ) : null}
            {showSubmit ? <RunCommandForm runId={id} command="submit" today={today} /> : null}
            {showApprove ? <RunCommandForm runId={id} command="approve" today={today} /> : null}
            {showPost ? <RunCommandForm runId={id} command="post" today={today} /> : null}
            {showReturn ? <RunCommandForm runId={id} command="return" today={today} /> : null}
            {showPay ? (
              <PayrollPaymentForm
                runId={id}
                accounts={accounts
                  .filter((a) => a.is_active && a.currency === currency)
                  .map((a) => ({ id: a.financial_account_id, label: a.name }))}
                today={today}
                bpjsOutstanding={{
                  kes: formatMoney(
                    String(Math.max(Number(run.bpjs_kes_due) - Number(run.bpjs_kes_paid), 0)),
                    currency,
                  ),
                  tk: formatMoney(
                    String(Math.max(Number(run.bpjs_tk_due) - Number(run.bpjs_tk_paid), 0)),
                    currency,
                  ),
                }}
              />
            ) : null}
            {showPay && confirmedPayments.length > 0 ? (
              <ReversePayrollPaymentForm
                runId={id}
                payments={confirmedPayments.map((p) => ({
                  id: p.payment_id,
                  label: `${p.payment_number} — ${PAYROLL_PAYMENT_KIND_LABELS[p.kind]} (${p.amount})`,
                }))}
                today={today}
              />
            ) : null}
            {showClose ? <RunCommandForm runId={id} command="close" today={today} /> : null}
            {showReopen ? <RunCommandForm runId={id} command="reopen" today={today} /> : null}
            {showCorrect ? <RunCommandForm runId={id} command="correct" today={today} /> : null}
            {showDiscard ? <RunCommandForm runId={id} command="discard" today={today} /> : null}
          </div>
        ) : undefined
      }
    />
  );
}
