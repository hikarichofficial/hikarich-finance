-- P10 (Step 01 #22 Advanced Budgeting, #23 Revenue Targets & Forecast) part 3: budgets and revenue
-- targets. Authority: Step 01 #22/#23, Step 15 Phase 10 gate ("Budget, targets and forecasts remain
-- separate from Actual/posted data").
--
-- Design
--   * Budgets and revenue targets are pure planning data: neither table is ever written to by, or writes
--     to, the posting engine, invoices, bills or expenses. "Actual" and "Committed" are never stored —
--     they are computed on read by get_budget_report/get_revenue_target_report from the existing
--     transactional line tables, exactly the way AR/AP/payroll status is always DERIVED rather than
--     cached (see e.g. the P5 invoices/P6 bills status comments). This is what makes the Phase 10 gate
--     ("remain separate from Actual/posted data") true structurally, not just by convention.
--   * Engineering decisions (not OWNER decisions — no economic/tax/workflow meaning changes, but the two
--     spec items name "Committed" and "Forecast" without defining them, so this is recorded like
--     DECISIONS #5's permission-naming gap):
--       - Budget lines may reference a revenue OR expense/asset category (Step 01 #22 says "Category",
--         without restricting kind); Actual for a revenue-kind category line is issued invoice lines,
--         for an expense/asset-kind category line it is approved bill lines + confirmed expense lines.
--       - "Committed" = amounts already entered but not yet recognized: draft invoice lines for revenue
--         categories, submitted (awaiting approval) bill lines for expense categories.
--       - Revenue targets are entity-wide totals by month (Step 01 #23 names no category breakdown,
--         unlike #22's explicit "Category -> Subcategory"), so revenue_target_lines has no category_id.
--       - FORECAST IS NOT COMPUTED HERE: both #22 and #23 require a "Forecast" column/figure but neither
--         spec, nor Step 12 (Reports), defines a projection methodology, and a wrong number here could
--         mislead a real business decision (AGENTS.md: economically-meaningful gaps go to the OWNER, not
--         a guess). get_budget_report/get_revenue_target_report always return forecast_amount = null;
--         this is filed as an open OWNER question in docs/DECISIONS.md rather than invented.
--   * Money: budget_lines/revenue_target_lines amounts are always in the Entity's base currency. Actual/
--     Committed computed from foreign-currency documents are converted with that document's own
--     exchange_rate (the same rate already booked into its base_total), never re-priced at report time.

-- ------------------------------------------------------------ budgets
create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  name text not null check (length(btrim(name)) between 2 and 200),
  fiscal_year integer check (fiscal_year between 2000 and 2100),
  period_type text not null check (period_type in ('annual', 'monthly', 'custom')),
  start_date date not null,
  end_date date not null,
  status text not null default 'draft' check (status in ('draft', 'active', 'closed')),
  note text check (note is null or length(note) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  constraint budget_end_after_start check (end_date >= start_date)
);
create index budgets_entity_status_idx on public.budgets (entity_id, status);
call app_private.apply_standard_triggers('public.budgets');
call app_private.secure_table('public.budgets');
create trigger tg_audit after insert or update or delete on public.budgets
  for each row execute function app_private.tg_audit('entity_id');

create table public.budget_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  budget_id uuid not null,
  category_id uuid not null,
  -- Always the first of the month; a budget with period_type = 'annual' still stores one row per
  -- month (Step 01 #22's tracked figures are monthly-comparable even for an annual budget).
  period_month date not null check (period_month = date_trunc('month', period_month)::date),
  budgeted_amount public.money_amount not null default 0 check (budgeted_amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entity_id, id),
  unique (budget_id, category_id, period_month),
  foreign key (entity_id, budget_id) references public.budgets (entity_id, id) on delete restrict,
  foreign key (entity_id, category_id) references public.categories (entity_id, id) on delete restrict
);
create index budget_lines_budget_idx on public.budget_lines (budget_id, period_month);
call app_private.secure_table('public.budget_lines');
create trigger tg_forbid_delete before delete on public.budget_lines
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.budget_lines
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_audit after insert or update or delete on public.budget_lines
  for each row execute function app_private.tg_audit('entity_id');
-- set_budget_lines below replaces rows wholesale (delete + insert) rather than updating them in place,
-- so budget_lines itself only ever needs insert/delete, never update.
create trigger tg_forbid_update before update on public.budget_lines
  for each row execute function app_private.tg_forbid_update();

-- ------------------------------------------------------------ revenue targets
create table public.revenue_targets (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  name text not null check (length(btrim(name)) between 2 and 200),
  fiscal_year integer check (fiscal_year between 2000 and 2100),
  period_type text not null check (period_type in ('annual', 'monthly', 'custom')),
  start_date date not null,
  end_date date not null,
  status text not null default 'draft' check (status in ('draft', 'active', 'closed')),
  note text check (note is null or length(note) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  constraint revenue_target_end_after_start check (end_date >= start_date)
);
create index revenue_targets_entity_status_idx on public.revenue_targets (entity_id, status);
call app_private.apply_standard_triggers('public.revenue_targets');
call app_private.secure_table('public.revenue_targets');
create trigger tg_audit after insert or update or delete on public.revenue_targets
  for each row execute function app_private.tg_audit('entity_id');

create table public.revenue_target_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  target_id uuid not null,
  period_month date not null check (period_month = date_trunc('month', period_month)::date),
  target_amount public.money_amount not null default 0 check (target_amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entity_id, id),
  unique (target_id, period_month),
  foreign key (entity_id, target_id) references public.revenue_targets (entity_id, id) on delete restrict
);
create index revenue_target_lines_target_idx on public.revenue_target_lines (target_id, period_month);
call app_private.secure_table('public.revenue_target_lines');
create trigger tg_forbid_delete before delete on public.revenue_target_lines
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.revenue_target_lines
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_forbid_update before update on public.revenue_target_lines
  for each row execute function app_private.tg_forbid_update();
create trigger tg_audit after insert or update or delete on public.revenue_target_lines
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ commands: budgets
create function public.create_budget(
  p_entity uuid, p_key text, p_name text, p_period_type text, p_start_date date, p_end_date date,
  p_fiscal_year integer default null, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
begin
  perform app_private.planning_authorize(p_entity, 'planning.budget_edit', 'creating a budget');
  v_replay := app_private.idem_begin('budget.create', p_entity, p_key,
    md5(jsonb_build_object('name', p_name, 'period_type', p_period_type, 'start', p_start_date,
                           'end', p_end_date, 'fy', p_fiscal_year, 'note', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_period_type not in ('annual', 'monthly', 'custom') then
    raise exception 'INVALID: unknown budget period type' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_start_date);
  perform app_private.assert_business_date(p_end_date);
  if p_end_date < p_start_date then
    raise exception 'INVALID: the end date cannot be before the start date' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.budgets (entity_id, name, fiscal_year, period_type, start_date, end_date, note)
  values (p_entity, btrim(p_name), p_fiscal_year, p_period_type, p_start_date, p_end_date,
          nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  perform app_private.idem_complete('budget.create', p_entity, p_key, 'budgets', v_id);
  return v_id;
end
$$;

-- Replaces the whole set of lines (delete + insert), the same "editable breakdown" shape as recurring
-- rules' template edits: simpler and safer than per-cell CRUD for a monthly grid.
create function public.set_budget_lines(p_budget uuid, p_lines jsonb, p_expected_version integer default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.budgets%rowtype;
  v_elem jsonb;
  v_cid uuid;
  v_month date;
  v_amount numeric;
  v_new_version integer;
begin
  select * into b from public.budgets where id = p_budget for update;
  if not found then
    raise exception 'NOT_FOUND: budget' using errcode = 'no_data_found';
  end if;
  perform app_private.planning_authorize(b.entity_id, 'planning.budget_edit', 'editing a budget');
  if b.status = 'closed' then
    raise exception 'INVALID: a closed budget cannot be edited' using errcode = 'invalid_parameter_value';
  end if;
  if p_expected_version is not null and p_expected_version <> b.version then
    raise exception 'CONFLICT: the budget changed since it was loaded' using errcode = 'integrity_constraint_violation';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception 'INVALID: lines must be a list' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_lines) > 2000 then
    raise exception 'INVALID: a budget can have at most 2000 lines' using errcode = 'invalid_parameter_value';
  end if;

  for v_elem in select value from jsonb_array_elements(p_lines) loop
    begin
      v_cid := (v_elem ->> 'category_id')::uuid;
      v_month := date_trunc('month', (v_elem ->> 'period_month')::date)::date;
    exception when others then
      raise exception 'INVALID: each budget line needs a valid category_id and period_month'
        using errcode = 'invalid_parameter_value';
    end;
    v_amount := app_private.parse_amount(v_elem ->> 'budgeted_amount', 'budgeted amount');
    if v_amount < 0 then
      raise exception 'INVALID: a budgeted amount cannot be negative' using errcode = 'invalid_parameter_value';
    end if;
    if v_month < date_trunc('month', b.start_date)::date or v_month > date_trunc('month', b.end_date)::date then
      raise exception 'INVALID: % is outside the budget''s date range', v_month using errcode = 'invalid_parameter_value';
    end if;
    if not exists (select 1 from public.categories c where c.id = v_cid and c.entity_id = b.entity_id and c.is_active) then
      raise exception 'INVALID: unknown or inactive category' using errcode = 'invalid_parameter_value';
    end if;
  end loop;

  delete from public.budget_lines where budget_id = p_budget;
  insert into public.budget_lines (entity_id, budget_id, category_id, period_month, budgeted_amount)
  select b.entity_id, p_budget, (l ->> 'category_id')::uuid, date_trunc('month', (l ->> 'period_month')::date)::date,
         (l ->> 'budgeted_amount')::numeric
  from jsonb_array_elements(p_lines) l;

  update public.budgets set version = version where id = p_budget returning version into v_new_version;
  return v_new_version;
end
$$;

create function public.activate_budget(p_budget uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare b public.budgets%rowtype;
begin
  select * into b from public.budgets where id = p_budget for update;
  if not found then raise exception 'NOT_FOUND: budget' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(b.entity_id, 'planning.budget_edit', 'activating a budget');
  if b.status <> 'draft' then
    raise exception 'INVALID: only a draft budget can be activated' using errcode = 'invalid_parameter_value';
  end if;
  update public.budgets set status = 'active' where id = p_budget;
end
$$;

create function public.close_budget(p_budget uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare b public.budgets%rowtype;
begin
  select * into b from public.budgets where id = p_budget for update;
  if not found then raise exception 'NOT_FOUND: budget' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(b.entity_id, 'planning.budget_edit', 'closing a budget');
  if b.status = 'closed' then
    raise exception 'INVALID: the budget is already closed' using errcode = 'invalid_parameter_value';
  end if;
  update public.budgets set status = 'closed' where id = p_budget;
end
$$;

create function public.list_budgets(p_entity uuid, p_status text default null)
returns setof public.budgets
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.planning_authorize(p_entity, 'planning.view', 'the budget list');
  return query
    select * from public.budgets bg
    where bg.entity_id = p_entity and (p_status is null or bg.status = p_status)
    order by bg.start_date desc, bg.name;
end
$$;

-- The stored (budgeted-amount-only) grid, for editing. get_budget_report below is the computed
-- Budget/Actual/Committed/Remaining/%Used/Variance view.
create function public.get_budget_lines(p_budget uuid)
returns setof public.budget_lines
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_entity uuid;
begin
  select entity_id into v_entity from public.budgets where id = p_budget;
  if v_entity is null then raise exception 'NOT_FOUND: budget' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(v_entity, 'planning.view', 'the budget lines');
  return query select * from public.budget_lines where budget_id = p_budget order by period_month;
end
$$;

-- Budget vs Actual vs Committed, per category per month (Step 01 #22). forecast_amount is always null
-- (see the file header: the projection methodology is an open OWNER question, not guessed here).
create function public.get_budget_report(p_budget uuid)
returns table (
  category_id uuid, category_name text, period_month date, budgeted_amount numeric,
  actual_amount numeric, committed_amount numeric, remaining_amount numeric, pct_used numeric,
  variance_amount numeric, forecast_amount numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  b public.budgets%rowtype;
  v_base public.currency_code;
  v_scale integer;
begin
  select * into b from public.budgets where id = p_budget;
  if not found then raise exception 'NOT_FOUND: budget' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(b.entity_id, 'planning.view', 'the budget report');
  v_base := app_private.entity_base_currency(b.entity_id);
  v_scale := app_private.currency_scale(v_base);

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
         null::numeric as forecast_amount
  from public.budget_lines bg
  join public.categories c on c.id = bg.category_id and c.entity_id = bg.entity_id
  left join actual_rev ar on ar.cid = bg.category_id and ar.pm = bg.period_month
  left join actual_exp ae on ae.cid = bg.category_id and ae.pm = bg.period_month
  left join committed_rev cr on cr.cid = bg.category_id and cr.pm = bg.period_month
  left join committed_exp ce on ce.cid = bg.category_id and ce.pm = bg.period_month
  where bg.budget_id = p_budget
  order by bg.period_month, c.sort_order, c.name;
end
$$;

-- ------------------------------------------------------------ commands: revenue targets
create function public.create_revenue_target(
  p_entity uuid, p_key text, p_name text, p_period_type text, p_start_date date, p_end_date date,
  p_fiscal_year integer default null, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
begin
  perform app_private.planning_authorize(p_entity, 'planning.budget_edit', 'creating a revenue target');
  v_replay := app_private.idem_begin('revenue_target.create', p_entity, p_key,
    md5(jsonb_build_object('name', p_name, 'period_type', p_period_type, 'start', p_start_date,
                           'end', p_end_date, 'fy', p_fiscal_year, 'note', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_period_type not in ('annual', 'monthly', 'custom') then
    raise exception 'INVALID: unknown revenue target period type' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_start_date);
  perform app_private.assert_business_date(p_end_date);
  if p_end_date < p_start_date then
    raise exception 'INVALID: the end date cannot be before the start date' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.revenue_targets (entity_id, name, fiscal_year, period_type, start_date, end_date, note)
  values (p_entity, btrim(p_name), p_fiscal_year, p_period_type, p_start_date, p_end_date,
          nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  perform app_private.idem_complete('revenue_target.create', p_entity, p_key, 'revenue_targets', v_id);
  return v_id;
end
$$;

create function public.set_revenue_target_lines(p_target uuid, p_lines jsonb, p_expected_version integer default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  t public.revenue_targets%rowtype;
  v_elem jsonb;
  v_month date;
  v_amount numeric;
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
  if jsonb_array_length(p_lines) > 120 then
    raise exception 'INVALID: a revenue target can have at most 120 monthly lines' using errcode = 'invalid_parameter_value';
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
  end loop;

  delete from public.revenue_target_lines where target_id = p_target;
  insert into public.revenue_target_lines (entity_id, target_id, period_month, target_amount)
  select t.entity_id, p_target, date_trunc('month', (l ->> 'period_month')::date)::date, (l ->> 'target_amount')::numeric
  from jsonb_array_elements(p_lines) l;

  update public.revenue_targets set version = version where id = p_target returning version into v_new_version;
  return v_new_version;
end
$$;

create function public.activate_revenue_target(p_target uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare t public.revenue_targets%rowtype;
begin
  select * into t from public.revenue_targets where id = p_target for update;
  if not found then raise exception 'NOT_FOUND: revenue target' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(t.entity_id, 'planning.budget_edit', 'activating a revenue target');
  if t.status <> 'draft' then
    raise exception 'INVALID: only a draft revenue target can be activated' using errcode = 'invalid_parameter_value';
  end if;
  update public.revenue_targets set status = 'active' where id = p_target;
end
$$;

create function public.close_revenue_target(p_target uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare t public.revenue_targets%rowtype;
begin
  select * into t from public.revenue_targets where id = p_target for update;
  if not found then raise exception 'NOT_FOUND: revenue target' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(t.entity_id, 'planning.budget_edit', 'closing a revenue target');
  if t.status = 'closed' then
    raise exception 'INVALID: the revenue target is already closed' using errcode = 'invalid_parameter_value';
  end if;
  update public.revenue_targets set status = 'closed' where id = p_target;
end
$$;

create function public.list_revenue_targets(p_entity uuid, p_status text default null)
returns setof public.revenue_targets
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.planning_authorize(p_entity, 'planning.view', 'the revenue target list');
  return query
    select * from public.revenue_targets rt
    where rt.entity_id = p_entity and (p_status is null or rt.status = p_status)
    order by rt.start_date desc, rt.name;
end
$$;

create function public.get_revenue_target_lines(p_target uuid)
returns setof public.revenue_target_lines
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_entity uuid;
begin
  select entity_id into v_entity from public.revenue_targets where id = p_target;
  if v_entity is null then raise exception 'NOT_FOUND: revenue target' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(v_entity, 'planning.view', 'the revenue target lines');
  return query select * from public.revenue_target_lines where target_id = p_target order by period_month;
end
$$;

-- Target vs Actual (issued invoice revenue) vs open AR, per month (Step 01 #23). forecast_amount is
-- always null for the same reason as get_budget_report above.
create function public.get_revenue_target_report(p_target uuid)
returns table (
  period_month date, target_amount numeric, actual_amount numeric, ar_outstanding_amount numeric,
  variance_amount numeric, forecast_amount numeric)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  t public.revenue_targets%rowtype;
begin
  select * into t from public.revenue_targets where id = p_target;
  if not found then raise exception 'NOT_FOUND: revenue target' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(t.entity_id, 'planning.view', 'the revenue target report');

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
  select rt.period_month, rt.target_amount::numeric, coalesce(a.amt, 0)::numeric as actual_amount,
         greatest(coalesce(ar.amt, 0), 0)::numeric as ar_outstanding_amount,
         (coalesce(a.amt, 0) - rt.target_amount)::numeric as variance_amount,
         null::numeric as forecast_amount
  from public.revenue_target_lines rt
  left join actual a on a.pm = rt.period_month
  left join ar_open ar on ar.pm = rt.period_month
  where rt.target_id = p_target
  order by rt.period_month;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.budgets');
create policy budgets_select on public.budgets for select to authenticated
  using (app_authz.has_permission(entity_id, 'planning.view'));
call app_private.expose_select('public.budget_lines');
create policy budget_lines_select on public.budget_lines for select to authenticated
  using (app_authz.has_permission(entity_id, 'planning.view'));
call app_private.expose_select('public.revenue_targets');
create policy revenue_targets_select on public.revenue_targets for select to authenticated
  using (app_authz.has_permission(entity_id, 'planning.view'));
call app_private.expose_select('public.revenue_target_lines');
create policy revenue_target_lines_select on public.revenue_target_lines for select to authenticated
  using (app_authz.has_permission(entity_id, 'planning.view'));

grant execute on function public.create_budget(uuid, text, text, text, date, date, integer, text) to authenticated;
grant execute on function public.set_budget_lines(uuid, jsonb, integer) to authenticated;
grant execute on function public.activate_budget(uuid) to authenticated;
grant execute on function public.close_budget(uuid) to authenticated;
grant execute on function public.list_budgets(uuid, text) to authenticated;
grant execute on function public.get_budget_lines(uuid) to authenticated;
grant execute on function public.get_budget_report(uuid) to authenticated;
grant execute on function public.create_revenue_target(uuid, text, text, text, date, date, integer, text) to authenticated;
grant execute on function public.set_revenue_target_lines(uuid, jsonb, integer) to authenticated;
grant execute on function public.activate_revenue_target(uuid) to authenticated;
grant execute on function public.close_revenue_target(uuid) to authenticated;
grant execute on function public.list_revenue_targets(uuid, text) to authenticated;
grant execute on function public.get_revenue_target_lines(uuid) to authenticated;
grant execute on function public.get_revenue_target_report(uuid) to authenticated;
