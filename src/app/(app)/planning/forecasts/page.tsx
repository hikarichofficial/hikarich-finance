import { requirePermission } from "@/services/identity/access";
import {
  getEntityBaseCurrency,
  getPlanningForecast,
  listBudgets,
} from "@/services/planning/planning";
import { buildForecastGrid, parseForecastMonths } from "@/domain/planning/forecast";
import { ForecastScreen } from "@/features/planning/ForecastScreen";

/** Forecasts (Step 09 §18, decision 250). `?months=` 3/6/12 (default 6); `?budget=` adjusts the forecast
 * with that budget where it plans. Gated `planning.view`, the permission `get_planning_forecast` checks. */
export default async function ForecastsPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; months?: string; budget?: string }>;
}) {
  const { entity, months: monthsParam, budget } = await searchParams;
  const { membership } = await requirePermission("planning.view", { entityCode: entity });
  const entityId = membership.entity_id;
  const months = parseForecastMonths(monthsParam);

  const budgets = await listBudgets({ entity_id: entityId });
  const budgetId = budgets.some((b) => b.id === budget) ? (budget ?? null) : null;
  const [rows, currency] = await Promise.all([
    getPlanningForecast({ entity_id: entityId, months, budget_id: budgetId }),
    getEntityBaseCurrency(entityId),
  ]);

  return (
    <ForecastScreen
      grid={buildForecastGrid(rows)}
      currency={currency}
      months={months}
      budgets={budgets}
      budgetId={budgetId}
      entity={entity}
    />
  );
}
