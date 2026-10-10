-- Decision 399 (OWNER, 10 October 2026): a Revenue Target may be split per revenue category.
--
-- The OWNER asked whether Target Pendapatan should be broken down per category and what I would recommend.
-- It should, for the same reason a Budget is: "we are behind on the target" is only actionable once you can
-- see which line of business is behind. A Budget has carried a category since P10 (Step 01 #22); a Revenue
-- Target carried only a month, so the screen could say the month missed and nothing more.
--
-- Step 01 #23 names no dimension for a Revenue Target, so the dimension is added, not assumed: the category
-- is OPTIONAL. A line with no category is what every existing target already has -- the whole Entity's
-- revenue for that month -- and keeps meaning exactly that. A target can be written either way:
--   * one line per month, no category: the Entity's total, compared against issued invoice revenue;
--   * one line per month per category: each category's own target, compared against the issued invoice LINES
--     that carry that category.
-- Mixing the two in one target is allowed and is not a contradiction: the uncategorised line is the total,
-- the category lines are the parts, and the report prints both rather than silently adding them together.
-- It is deliberately not enforced that the parts sum to the total -- a target is a plan, and a plan that
-- covers two product lines out of five is a normal thing to write.
--
-- The two kinds of actual are different sums and the report says which is which, rather than pretending they
-- are the same figure. The Entity total is `invoices.base_total`, the amount actually booked at issue
-- (unchanged). A category's actual is the sum of `invoice_lines.base_amount` less
-- `base_discount_amount` for that category, which is the revenue side of the same booking; it excludes tax
-- and anything booked outside an invoice line, so the category rows of a month do not have to add up to the
-- month's total row. Open AR is reported for the Entity row only: a receivable is owed on a document, not on
-- a category, and splitting one across its lines would invent a figure.

-- ------------------------------------------------------------ the dimension
alter table public.revenue_target_lines add column category_id uuid;
alter table public.revenue_target_lines
  add constraint revenue_target_lines_category_fk
  foreign key (entity_id, category_id) references public.categories (entity_id, id) on delete restrict;

-- `unique (target_id, period_month)` cannot stay: it would allow only one category per month. Two partial
-- unique indexes keep both shapes exact -- one total per month, and one line per category per month -- where
-- a single index over a nullable column would let duplicate uncategorised rows through.
alter table public.revenue_target_lines drop constraint revenue_target_lines_target_id_period_month_key;
create unique index revenue_target_lines_total_uq on public.revenue_target_lines (target_id, period_month)
  where category_id is null;
create unique index revenue_target_lines_category_uq
  on public.revenue_target_lines (target_id, category_id, period_month)
  where category_id is not null;
create index revenue_target_lines_category_idx on public.revenue_target_lines (entity_id, category_id);

-- ------------------------------------------------------------ writing the lines
create or replace function public.set_revenue_target_lines(p_target uuid, p_lines jsonb, p_expected_version integer default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  t public.revenue_targets%rowtype;
  v_elem jsonb;
  v_month date;
  v_amount numeric;
  v_category uuid;
  v_new_version integer;
begin
  select * into t from public.revenue_targets where id = p_target for update;
  if not found then
    raise exception 'NOT_FOUND: revenue target' using errcode = 'no_data_found';
  end if;
  perform app_private.planning_authorize(t.entity_id, 'planning.budget_edit', 'editing a revenue target');
  if t.status = 'closed' then
    raise exception 'INVALID: a closed revenue target cannot be edited' using errcode = 'invalid_parameter_value';
  end if;
  if p_expected_version is not null and p_expected_version <> t.version then
    raise exception 'CONFLICT: the revenue target changed since it was loaded' using errcode = 'integrity_constraint_violation';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception 'INVALID: lines must be a list' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_lines) > 1200 then
    raise exception 'INVALID: a revenue target can have at most 1200 lines' using errcode = 'invalid_parameter_value';
  end if;

  for v_elem in select value from jsonb_array_elements(p_lines) loop
    begin
      v_month := date_trunc('month', (v_elem ->> 'period_month')::date)::date;
    exception when others then
      raise exception 'INVALID: each revenue target line needs a valid period_month' using errcode = 'invalid_parameter_value';
    end;
    v_amount := app_private.parse_amount(v_elem ->> 'target_amount', 'target amount');
    if v_amount < 0 then
      raise exception 'INVALID: a target amount cannot be negative' using errcode = 'invalid_parameter_value';
    end if;
    if v_month < date_trunc('month', t.start_date)::date or v_month > date_trunc('month', t.end_date)::date then
      raise exception 'INVALID: % is outside the revenue target''s date range', v_month using errcode = 'invalid_parameter_value';
    end if;
    -- A category is optional; one that is given must be this Entity's own, and must be a revenue category --
    -- a revenue target split by an expense category would be meaningless.
    v_category := nullif(v_elem ->> 'category_id', '')::uuid;
    if v_category is not null then
      if not exists (select 1 from public.categories c
                     where c.id = v_category and c.entity_id = t.entity_id and c.kind = 'revenue') then
        raise exception 'INVALID: a revenue target line needs a revenue category of this Entity'
          using errcode = 'invalid_parameter_value';
      end if;
    end if;
  end loop;

  delete from public.revenue_target_lines where target_id = p_target;
  insert into public.revenue_target_lines (entity_id, target_id, period_month, target_amount, category_id)
  select t.entity_id, p_target, date_trunc('month', (l ->> 'period_month')::date)::date,
         (l ->> 'target_amount')::numeric, nullif(l ->> 'category_id', '')::uuid
  from jsonb_array_elements(p_lines) l;

  update public.revenue_targets set version = version where id = p_target returning version into v_new_version;
  return v_new_version;
end
$$;

-- ------------------------------------------------------------ the report
-- Target vs Actual (issued invoice revenue) vs open AR, per month and -- where the target names one -- per
-- revenue category (Step 01 #23, decision 399). `forecast_amount` keeps the baseline meaning decision 2xx
-- (P14) gave it: the Entity row carries it, a category row does not, because the baseline is an Entity-wide
-- average of issued revenue and dividing it between categories would invent the split.
drop function if exists public.get_revenue_target_report(uuid);
create function public.get_revenue_target_report(p_target uuid)
returns table (
  period_month date, category_id uuid, category_name text, target_amount numeric, actual_amount numeric,
  ar_outstanding_amount numeric, variance_amount numeric, forecast_amount numeric)
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
    actual_cat as (
      -- The revenue side of the same booking, per category: the line's base amount net of its discount.
      select date_trunc('month', i.issue_date)::date as pm, il.category_id as cid,
             sum(coalesce(il.base_amount, 0) - coalesce(il.base_discount_amount, 0)) as amt
      from public.invoice_lines il
      join public.invoices i on i.id = il.invoice_id and i.entity_id = il.entity_id
      where i.entity_id = t.entity_id and i.status = 'issued' and il.category_id is not null
      group by 1, 2
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
  select rt.period_month, rt.category_id, c.name,
         rt.target_amount::numeric,
         case when rt.category_id is null then coalesce(ac.amt, 0) else coalesce(acc.amt, 0) end::numeric,
         case when rt.category_id is null then greatest(coalesce(ar.amt, 0), 0) else 0 end::numeric,
         (case when rt.category_id is null then coalesce(ac.amt, 0) else coalesce(acc.amt, 0) end
          - rt.target_amount)::numeric,
         case when rt.category_id is null and rt.period_month >= a.anchor then v_avg else null end::numeric
  from public.revenue_target_lines rt
  left join public.categories c on c.id = rt.category_id and c.entity_id = rt.entity_id
  left join actual ac on ac.pm = rt.period_month and rt.category_id is null
  left join actual_cat acc on acc.pm = rt.period_month and acc.cid = rt.category_id
  left join ar_open ar on ar.pm = rt.period_month and rt.category_id is null
  where rt.target_id = p_target
  order by rt.period_month, c.name nulls first;
end
$$;

revoke all on function public.get_revenue_target_report(uuid) from public, anon;
grant execute on function public.get_revenue_target_report(uuid) to authenticated;
