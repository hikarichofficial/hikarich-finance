-- P14 decision 250 (OWNER answer to decision 139): the forecast methodology.
--
-- OWNER: "based on the last 3 months, and it must be adjustable through the budget".
--   * Baseline: for a category (or, for revenue targets, total issued revenue) the forecast of a month is
--     the average actual of the 3 complete calendar months before the Entity's current month (Entity
--     timezone, decision 248). Months with no activity count as zero; the average is rounded half-up to
--     the base currency's scale. Only the current and future months get a forecast; a past month already
--     has its actual.
--   * Adjustment: when a budget is chosen on the Forecasts screen, a category-month that the budget plans
--     uses the budgeted amount instead (source 'budget'); the budget itself is edited on the Budgets
--     screen, so the forecast follows any change made there.
--   * `get_budget_report`/`get_revenue_target_report` now fill `forecast_amount` with the baseline (it
--     was always null, decision 139). Every other column is computed exactly as before.
-- "Actual" is the same definition the budget report already uses: issued invoice lines (revenue),
-- approved bill lines plus confirmed expense lines (expense), by category and document month, in base
-- currency.

-- Actual per category per month, in base currency (the budget report's own definition).
create function app_private.planning_category_actuals(p_entity uuid, p_from date, p_to date)
returns table (category_id uuid, period_month date, amount numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_base public.currency_code := app_private.entity_base_currency(p_entity);
  v_scale integer := app_private.currency_scale(v_base);
begin
  return query
    select u.cid, u.pm, sum(u.amt)::numeric from (
      select il.category_id as cid, date_trunc('month', i.issue_date)::date as pm,
             case when i.currency = v_base then il.line_total
                  else app_private.round_amount(il.line_total * i.exchange_rate, v_scale, 'half_up') end as amt
      from public.invoice_lines il join public.invoices i on i.id = il.invoice_id and i.entity_id = il.entity_id
      where il.entity_id = p_entity and i.status = 'issued' and il.category_id is not null
        and i.issue_date >= p_from and i.issue_date < p_to
      union all
      select bl.category_id, date_trunc('month', bi.bill_date)::date,
             case when bi.currency = v_base then bl.line_total
                  else app_private.round_amount(bl.line_total * bi.exchange_rate, v_scale, 'half_up') end
      from public.bill_lines bl join public.bills bi on bi.id = bl.bill_id and bi.entity_id = bl.entity_id
      where bl.entity_id = p_entity and bi.status = 'approved' and bl.category_id is not null
        and bi.bill_date >= p_from and bi.bill_date < p_to
      union all
      select el.category_id, date_trunc('month', e.expense_date)::date,
             case when e.currency = v_base then el.line_total
                  else app_private.round_amount(el.line_total * e.exchange_rate, v_scale, 'half_up') end
      from public.expense_lines el join public.expenses e on e.id = el.expense_id and e.entity_id = el.entity_id
      where el.entity_id = p_entity and e.status = 'confirmed' and el.category_id is not null
        and e.expense_date >= p_from and e.expense_date < p_to
    ) u
    group by 1, 2;
end
$$;

-- The Entity's current month (its own timezone) and the start of the 3-month baseline window.
create function app_private.planning_forecast_anchor(p_entity uuid, out anchor date, out window_start date)
language sql stable security definer set search_path = pg_catalog, public as $$
  select date_trunc('month', app_private.entity_today(p_entity))::date,
         (date_trunc('month', app_private.entity_today(p_entity)) - interval '3 months')::date
$$;

-- 3-month average actual per category (only categories with activity in the window).
create function app_private.planning_category_baseline(p_entity uuid)
returns table (category_id uuid, avg_amount numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  a record;
  v_scale integer := app_private.currency_scale(app_private.entity_base_currency(p_entity));
begin
  select * into a from app_private.planning_forecast_anchor(p_entity);
  return query
    select x.category_id, app_private.round_amount(sum(x.amount) / 3, v_scale, 'half_up')
    from app_private.planning_category_actuals(p_entity, a.window_start, a.anchor) x
    group by x.category_id;
end
$$;

-- ------------------------------------------------------------ budget report (forecast filled)
create or replace function public.get_budget_report(p_budget uuid)
returns table (
  category_id uuid, category_name text, period_month date, budgeted_amount numeric,
  actual_amount numeric, committed_amount numeric, remaining_amount numeric, pct_used numeric,
  variance_amount numeric, forecast_amount numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  b public.budgets%rowtype;
  v_base public.currency_code;
  v_scale integer;
  v_anchor date;
begin
  select * into b from public.budgets where id = p_budget;
  if not found then raise exception 'NOT_FOUND: budget' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(b.entity_id, 'planning.view', 'the budget report');
  v_base := app_private.entity_base_currency(b.entity_id);
  v_scale := app_private.currency_scale(v_base);
  select f.anchor into v_anchor from app_private.planning_forecast_anchor(b.entity_id) f;

  return query
    with actual_rev as (
      select il.category_id as cid, date_trunc('month', i.issue_date)::date as pm,
             sum(case when i.currency = v_base then il.line_total
                      else app_private.round_amount(il.line_total * i.exchange_rate, v_scale, 'half_up') end) as amt
      from public.invoice_lines il join public.invoices i on i.id = il.invoice_id and i.entity_id = il.entity_id
      where il.entity_id = b.entity_id and i.status = 'issued' and il.category_id is not null
      group by 1, 2
    ),
    committed_rev as (
      select il.category_id as cid, date_trunc('month', i.issue_date)::date as pm,
             sum(case when i.currency = v_base then il.line_total
                      else app_private.round_amount(il.line_total * i.exchange_rate, v_scale, 'half_up') end) as amt
      from public.invoice_lines il join public.invoices i on i.id = il.invoice_id and i.entity_id = il.entity_id
      where il.entity_id = b.entity_id and i.status = 'draft' and il.category_id is not null
      group by 1, 2
    ),
    actual_exp as (
      select cid, pm, sum(amt) as amt from (
        select bl.category_id as cid, date_trunc('month', bi.bill_date)::date as pm,
               case when bi.currency = v_base then bl.line_total
                    else app_private.round_amount(bl.line_total * bi.exchange_rate, v_scale, 'half_up') end as amt
        from public.bill_lines bl join public.bills bi on bi.id = bl.bill_id and bi.entity_id = bl.entity_id
        where bl.entity_id = b.entity_id and bi.status = 'approved' and bl.category_id is not null
        union all
        select el.category_id as cid, date_trunc('month', e.expense_date)::date as pm,
               case when e.currency = v_base then el.line_total
                    else app_private.round_amount(el.line_total * e.exchange_rate, v_scale, 'half_up') end as amt
        from public.expense_lines el join public.expenses e on e.id = el.expense_id and e.entity_id = el.entity_id
        where el.entity_id = b.entity_id and e.status = 'confirmed' and el.category_id is not null
      ) u
      group by 1, 2
    ),
    committed_exp as (
      select bl.category_id as cid, date_trunc('month', bi.bill_date)::date as pm,
             sum(case when bi.currency = v_base then bl.line_total
                      else app_private.round_amount(bl.line_total * bi.exchange_rate, v_scale, 'half_up') end) as amt
      from public.bill_lines bl join public.bills bi on bi.id = bl.bill_id and bi.entity_id = bl.entity_id
      where bl.entity_id = b.entity_id and bi.status = 'submitted' and bl.category_id is not null
      group by 1, 2
    ),
    baseline as (
      select * from app_private.planning_category_baseline(b.entity_id)
    )
  select bg.category_id, c.name, bg.period_month, bg.budgeted_amount::numeric,
         (coalesce(ar.amt, 0) + coalesce(ae.amt, 0))::numeric as actual_amount,
         (coalesce(cr.amt, 0) + coalesce(ce.amt, 0))::numeric as committed_amount,
         (bg.budgeted_amount - (coalesce(ar.amt, 0) + coalesce(ae.amt, 0))
            - (coalesce(cr.amt, 0) + coalesce(ce.amt, 0)))::numeric as remaining_amount,
         case when bg.budgeted_amount = 0 then null
              else app_private.round_amount(
                     100 * (coalesce(ar.amt, 0) + coalesce(ae.amt, 0)) / bg.budgeted_amount, 2, 'half_up') end as pct_used,
         ((coalesce(ar.amt, 0) + coalesce(ae.amt, 0)) - bg.budgeted_amount)::numeric as variance_amount,
         case when bg.period_month >= v_anchor then coalesce(bl.avg_amount, 0) else null end::numeric as forecast_amount
  from public.budget_lines bg
  join public.categories c on c.id = bg.category_id and c.entity_id = bg.entity_id
  left join actual_rev ar on ar.cid = bg.category_id and ar.pm = bg.period_month
  left join actual_exp ae on ae.cid = bg.category_id and ae.pm = bg.period_month
  left join committed_rev cr on cr.cid = bg.category_id and cr.pm = bg.period_month
  left join committed_exp ce on ce.cid = bg.category_id and ce.pm = bg.period_month
  left join baseline bl on bl.category_id = bg.category_id
  where bg.budget_id = p_budget
  order by bg.period_month, c.sort_order, c.name;
end
$$;

-- ------------------------------------------------------------ revenue target report (forecast filled)
create or replace function public.get_revenue_target_report(p_target uuid)
returns table (
  period_month date, target_amount numeric, actual_amount numeric, ar_outstanding_amount numeric,
  variance_amount numeric, forecast_amount numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  t public.revenue_targets%rowtype;
  a record;
  v_scale integer;
  v_avg numeric;
begin
  select * into t from public.revenue_targets where id = p_target;
  if not found then raise exception 'NOT_FOUND: revenue target' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(t.entity_id, 'planning.view', 'the revenue target report');
  select * into a from app_private.planning_forecast_anchor(t.entity_id);
  v_scale := app_private.currency_scale(app_private.entity_base_currency(t.entity_id));
  -- Baseline: average issued revenue (base_total, as `actual` below) over the 3 months before this month.
  select app_private.round_amount(coalesce(sum(i.base_total), 0) / 3, v_scale, 'half_up') into v_avg
  from public.invoices i
  where i.entity_id = t.entity_id and i.status = 'issued'
    and i.issue_date >= a.window_start and i.issue_date < a.anchor;

  return query
    with actual as (
      -- base_total is already the base-currency amount booked at issue (Step 08 §3); using it directly
      -- avoids re-deriving it from total * exchange_rate and risking a different rounding.
      select date_trunc('month', i.issue_date)::date as pm, sum(i.base_total) as amt
      from public.invoices i
      where i.entity_id = t.entity_id and i.status = 'issued'
      group by 1
    ),
    ar_open as (
      -- Open receivable (base currency) for that month's issued invoices: booked base_total less
      -- whatever has actively been allocated against them since (Step 07 §3's derived AR balance).
      select date_trunc('month', i.issue_date)::date as pm,
             sum(i.base_total - coalesce((
                     select sum(pa.base_ar_amount) from public.payment_allocations pa
                     where pa.entity_id = i.entity_id and pa.invoice_id = i.id and pa.status = 'active'
                   ), 0)) as amt
      from public.invoices i
      where i.entity_id = t.entity_id and i.status = 'issued'
      group by 1
    )
  select rt.period_month, rt.target_amount::numeric, coalesce(ac.amt, 0)::numeric as actual_amount,
         greatest(coalesce(ar.amt, 0), 0)::numeric as ar_outstanding_amount,
         (coalesce(ac.amt, 0) - rt.target_amount)::numeric as variance_amount,
         case when rt.period_month >= a.anchor then v_avg else null end::numeric as forecast_amount
  from public.revenue_target_lines rt
  left join actual ac on ac.pm = rt.period_month
  left join ar_open ar on ar.pm = rt.period_month
  where rt.target_id = p_target
  order by rt.period_month;
end
$$;

-- ------------------------------------------------------------ Forecasts screen
-- Per active revenue/expense category and month, from the Entity's current month for p_months months:
-- the 3-month baseline, the chosen budget's amount when it plans that category-month, and the forecast
-- (budget when present, otherwise the baseline). Categories appear when they have baseline activity or a
-- line in the chosen budget.
create function public.get_planning_forecast(p_entity uuid, p_months integer default 6, p_budget uuid default null)
returns table (
  category_id uuid, category_name text, category_kind text, period_month date,
  baseline_amount numeric, budget_amount numeric, forecast_amount numeric, source text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  a record;
begin
  perform app_private.planning_authorize(p_entity, 'planning.view', 'the forecast');
  if p_months is null or p_months not between 1 and 24 then
    raise exception 'INVALID: months must be 1 to 24' using errcode = 'invalid_parameter_value';
  end if;
  if p_budget is not null and not exists (select 1 from public.budgets where id = p_budget and entity_id = p_entity) then
    raise exception 'INVALID: the budget belongs to another Entity' using errcode = 'invalid_parameter_value';
  end if;
  select * into a from app_private.planning_forecast_anchor(p_entity);

  return query
    with months as (
      select (a.anchor + make_interval(months => g))::date as pm from generate_series(0, p_months - 1) g
    ),
    baseline as (
      select * from app_private.planning_category_baseline(p_entity)
    ),
    planned as (
      select bl.category_id, bl.period_month, bl.budgeted_amount
      from public.budget_lines bl
      where p_budget is not null and bl.budget_id = p_budget
    ),
    cats as (
      select c.id, c.name, c.kind, c.sort_order
      from public.categories c
      where c.entity_id = p_entity and c.is_active and c.kind in ('revenue', 'expense')
        and (exists (select 1 from baseline b where b.category_id = c.id)
             or exists (select 1 from planned p where p.category_id = c.id))
    )
  select c.id, c.name, c.kind, m.pm,
         coalesce(b.avg_amount, 0)::numeric,
         p.budgeted_amount::numeric,
         coalesce(p.budgeted_amount, b.avg_amount, 0)::numeric,
         case when p.budgeted_amount is not null then 'budget' else 'average_3m' end
  from cats c
  cross join months m
  left join baseline b on b.category_id = c.id
  left join planned p on p.category_id = c.id and p.period_month = m.pm
  order by c.kind desc, c.sort_order, c.name, m.pm;
end
$$;

revoke all on function app_private.planning_category_actuals(uuid, date, date),
  app_private.planning_forecast_anchor(uuid), app_private.planning_category_baseline(uuid) from public;
revoke all on function public.get_planning_forecast(uuid, integer, uuid) from public;
grant execute on function public.get_planning_forecast(uuid, integer, uuid) to authenticated;
