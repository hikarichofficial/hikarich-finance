-- P8 part 4 (Step 07 §11, Step 08 §11, Step 04 §7): the asset lifecycle - activation, the depreciation schedule and its
-- posting, re-planning, operational changes, disposal and its reversal.
--
-- Principles
--   * A draft asset posts nothing: its cost is already in the ledger from the purchase (Step 07 §11).
--   * Activation fixes the depreciation setup and generates the schedule; the schedule is a plan, the ledger moves only
--     when a month is posted. One journal per asset and month, dated the last day of the month (full-month convention:
--     the month of acquisition is depreciated, the month of disposal is not).
--   * Changing the method, life or residual is a prospective change of estimate: past months are never rewritten.
--   * Operational events (transfer, condition) post nothing (Step 08 §11 "asset status changes alone do not fabricate
--     accounting entries"). Damage or loss is recognised only by an explicit disposal.
--   * A disposal removes cost and accumulated depreciation, records the proceeds (cash, or a receivable) and books the
--     balancing gain or loss. Depreciation is never deleted; the disposal can be reversed and the asset reinstated.

-- ------------------------------------------------------------ the disposal record
create table public.asset_disposals (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  asset_id uuid not null,
  disposal_type text not null check (disposal_type in ('sale', 'scrapped', 'lost', 'damaged', 'donated')),
  disposal_date date not null,
  proceeds public.money_amount not null default 0 check (proceeds >= 0),
  proceeds_method text not null check (proceeds_method in ('cash', 'receivable', 'none')),
  financial_account_id uuid,
  obligation_id uuid,
  cost_removed public.money_amount not null check (cost_removed > 0),
  accumulated_removed public.money_amount not null check (accumulated_removed >= 0),
  net_book_value public.money_amount not null,
  -- Positive: gain; negative: loss. The balancing economic result (Step 04 §7).
  gain_loss numeric(20, 4) not null,
  reason text not null check (length(btrim(reason)) between 3 and 1000),
  status text not null default 'posted' check (status in ('posted', 'reversed')),
  journal_id uuid not null,
  reversal_journal_id uuid,
  reversed_at timestamptz,
  reversed_date date,
  reversed_by uuid,
  reverse_reason text check (reverse_reason is null or length(reverse_reason) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, asset_id) references public.fixed_assets (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, obligation_id) references public.other_obligations (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint asset_disposal_proceeds_shape check (
    case proceeds_method
      when 'none' then proceeds = 0 and financial_account_id is null and obligation_id is null
      when 'cash' then proceeds > 0 and financial_account_id is not null and obligation_id is null
      else proceeds > 0 and financial_account_id is null and obligation_id is not null end),
  constraint asset_disposal_type_shape check (disposal_type = 'sale' or proceeds_method = 'none'),
  constraint asset_disposal_result check (
    net_book_value = cost_removed - accumulated_removed and gain_loss = proceeds - net_book_value),
  constraint asset_disposal_state check (
    (status = 'posted' and reversal_journal_id is null and reversed_at is null)
    or (status = 'reversed' and reversal_journal_id is not null and reversed_at is not null and reversed_date is not null
        and reverse_reason is not null))
);
create unique index asset_disposals_live_uq on public.asset_disposals (asset_id) where status = 'posted';
create index asset_disposals_entity_idx on public.asset_disposals (entity_id, disposal_date);

create function app_private.tg_asset_disposals_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by',
                                   'reverse_reason', 'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' then
    raise exception 'A reversed disposal cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a disposal cannot be changed; reverse it instead' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.asset_disposals
  for each row execute function app_private.tg_asset_disposals_guard();
create trigger tg_forbid_delete before delete on public.asset_disposals
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.asset_disposals
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.asset_disposals');
call app_private.secure_table('public.asset_disposals');
create trigger tg_audit after insert or update or delete on public.asset_disposals
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ figures
-- Accumulated depreciation of an asset: the opening figure plus the depreciation journals posted (as of a date: by the
-- journal date, counting a reversed month until the day it was reversed).
create function app_private.asset_accumulated(p_asset uuid, p_as_of date default null) returns numeric
language sql stable as $$
  select f.opening_accumulated + coalesce((
    select sum(l.amount) from public.asset_depreciation_lines l
    where l.asset_id = f.id and l.journal_id is not null
      and (case when p_as_of is null then l.status = 'posted'
                else app_private.month_end(l.period_month) <= p_as_of and (l.status = 'posted' or l.reversed_date > p_as_of) end)), 0)
  from public.fixed_assets f where f.id = p_asset
$$;

create function app_private.asset_disposed_as_of(p_asset uuid, p_as_of date) returns boolean
language sql stable as $$
  select exists (select 1 from public.asset_disposals d
                 where d.asset_id = p_asset and d.disposal_date <= p_as_of and (d.status = 'posted' or d.reversed_date > p_as_of))
$$;

-- The fiscal class (a memo, Step 05): the class object of the rule in force on a date, or null.
create function app_private.fiscal_class(p_key text, p_date date) returns jsonb
language sql stable as $$
  select c from jsonb_array_elements(
    coalesce((app_private.tax_rule_at('FISCAL_DEP_CLASSES', p_date)).params -> 'classes', '[]'::jsonb)) c
  where c ->> 'key' = p_key
$$;

-- ------------------------------------------------------------ the schedule
-- (Re)creates the scheduled months of an active asset from where the posted depreciation stops:
--   * from = the month after the latest posted month; with nothing posted, the in-service month (an opening asset:
--     the month after its cut-over);
--   * the months left = the useful life less the months already elapsed, unless a number is given;
--   * the value to write off = cost - opening accumulated - posted, down to the residual.
-- Existing scheduled lines must have been cancelled by the caller. A gap (a scheduled month before a posted month)
-- stops the re-plan: that month is posted or dealt with first.
create function app_private.asset_generate_schedule(p_asset uuid, p_remaining integer default null) returns integer
language plpgsql as $$
declare
  a public.fixed_assets%rowtype;
  v_last date;
  v_from date;
  v_elapsed integer;
  v_remaining integer;
  v_nbv numeric;
  v_n integer;
  v_scale integer;
begin
  select * into a from public.fixed_assets where id = p_asset;
  if a.status <> 'active' or a.depreciation_method = 'none' then
    return 0;
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(a.entity_id));
  select max(l.period_month) into v_last from public.asset_depreciation_lines l where l.asset_id = a.id and l.status = 'posted';
  if v_last is not null and exists (
       select 1 from public.asset_depreciation_lines l where l.asset_id = a.id and l.status = 'scheduled' and l.period_month < v_last) then
    raise exception 'CONFLICT: a month before the latest posted depreciation of % is still unposted; post it first', a.asset_code
      using errcode = 'integrity_constraint_violation';
  end if;
  if v_last is not null then
    v_from := (v_last + interval '1 month')::date;
  elsif a.source_type = 'opening' then
    v_from := (date_trunc('month', a.opening_cutover) + interval '1 month')::date;
  else
    v_from := date_trunc('month', a.in_service_date)::date;
  end if;
  v_elapsed := (extract(year from v_from)::integer - extract(year from a.in_service_date)::integer) * 12
             + extract(month from v_from)::integer - extract(month from a.in_service_date)::integer;
  v_remaining := coalesce(p_remaining, a.useful_life_months - v_elapsed);
  v_nbv := a.acquisition_cost - app_private.asset_accumulated(a.id);
  if v_remaining < 1 then
    if v_nbv > a.residual_value then
      raise exception 'INVALID: the useful life of % is used up but a value above the residual remains; give more remaining months',
        a.asset_code using errcode = 'invalid_parameter_value';
    end if;
    return 0;
  end if;
  insert into public.asset_depreciation_lines (entity_id, asset_id, period_month, amount, plan_version, created_by)
  select a.entity_id, a.id, p.period_month, p.amount, a.plan_version, auth.uid()
  from app_private.asset_plan(a.depreciation_method, v_nbv, a.residual_value, v_remaining, a.useful_life_months, v_from, v_scale) p;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- Posts one scheduled month: Dr Depreciation Expense, Cr Accumulated Depreciation, dated the last day of the month.
create function app_private.asset_post_line(p_line uuid) returns uuid
language plpgsql as $$
declare
  l public.asset_depreciation_lines%rowtype;
  a public.fixed_assets%rowtype;
  v_date date;
  v_desc text;
  v_journal uuid;
begin
  select * into l from public.asset_depreciation_lines where id = p_line for update;
  if l.status <> 'scheduled' then
    raise exception 'CONFLICT: only a scheduled month can be posted (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  select * into a from public.fixed_assets where id = l.asset_id;
  if a.status <> 'active' then
    raise exception 'CONFLICT: depreciation is posted for an active asset only (% is %)', a.asset_code, a.status
      using errcode = 'integrity_constraint_violation';
  end if;
  v_date := app_private.month_end(l.period_month);
  perform app_private.assert_period_postable(a.entity_id, v_date);
  v_desc := format('Depreciation %s - %s', a.asset_code, to_char(l.period_month, 'YYYY-MM'));
  v_journal := app_private.post_system_journal(a.entity_id, 'asset_depreciation', l.id, 'asset.depreciate', 'asset.v1', v_date, v_desc,
    jsonb_build_array(
      jsonb_build_object('account_id', app_private.role_account(a.entity_id, 'depreciation_expense'),
                         'debit', l.amount, 'credit', 0, 'description', v_desc),
      jsonb_build_object('account_id', app_private.role_account(a.entity_id, 'accumulated_depreciation'),
                         'debit', 0, 'credit', l.amount, 'description', v_desc)));
  update public.asset_depreciation_lines
  set status = 'posted', journal_id = v_journal, posted_at = now(), posted_by = auth.uid()
  where id = l.id;
  return v_journal;
end
$$;

-- ------------------------------------------------------------ small commands: details, transfer, condition
create function public.asset_update_details(
  p_asset uuid, p_name text, p_description text default null, p_serial text default null)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: changing an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 1 and 200 or length(coalesce(p_description, '')) > 2000
     or length(coalesce(p_serial, '')) > 100 then
    raise exception 'INVALID: a name (up to 200 characters), a description (2000) and a serial number (100)'
      using errcode = 'invalid_parameter_value';
  end if;
  select * into a from public.fixed_assets where id = p_asset for update;
  if a.status = 'cancelled' then
    raise exception 'CONFLICT: a cancelled asset cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  update public.fixed_assets
  set name = btrim(p_name), description = nullif(btrim(coalesce(p_description, '')), ''),
      serial_number = nullif(btrim(coalesce(p_serial, '')), '')
  where id = a.id;
  perform app_private.asset_event(a.id, 'details_changed', app_private.entity_today(a.entity_id),
    jsonb_build_object('name', btrim(p_name)));
end
$$;

create function public.asset_transfer(p_asset uuid, p_location text, p_custodian text, p_date date, p_note text default null)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: transferring an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  if length(coalesce(p_location, '')) > 200 or length(coalesce(p_custodian, '')) > 200
     or (nullif(btrim(coalesce(p_location, '')), '') is null and nullif(btrim(coalesce(p_custodian, '')), '') is null) then
    raise exception 'INVALID: give the new location or custodian (up to 200 characters each)' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  select * into a from public.fixed_assets where id = p_asset for update;
  if a.status in ('cancelled', 'sold', 'disposed') then
    raise exception 'CONFLICT: a % asset cannot be transferred', a.status using errcode = 'integrity_constraint_violation';
  end if;
  update public.fixed_assets
  set location = coalesce(nullif(btrim(coalesce(p_location, '')), ''), location),
      custodian = coalesce(nullif(btrim(coalesce(p_custodian, '')), ''), custodian)
  where id = a.id;
  -- Operational only: no journal (Step 07 §11 "accounting only if an economic event requires").
  perform app_private.asset_event(a.id, 'transferred', p_date,
    jsonb_build_object('from_location', a.location, 'to_location', coalesce(nullif(btrim(coalesce(p_location, '')), ''), a.location),
                       'from_custodian', a.custodian, 'to_custodian', coalesce(nullif(btrim(coalesce(p_custodian, '')), ''), a.custodian)),
    p_note);
end
$$;

create function public.asset_set_condition(p_asset uuid, p_condition text, p_date date, p_note text default null)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: changing an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  if p_condition is null or p_condition not in ('in_use', 'in_storage', 'under_repair', 'damaged', 'lost') then
    raise exception 'INVALID: the condition is in_use, in_storage, under_repair, damaged or lost' using errcode = 'invalid_parameter_value';
  end if;
  if p_condition in ('damaged', 'lost') and length(btrim(coalesce(p_note, ''))) < 5 then
    raise exception 'INVALID: damage or loss needs a note that describes what happened' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  select * into a from public.fixed_assets where id = p_asset for update;
  if a.status in ('cancelled', 'sold', 'disposed') then
    raise exception 'CONFLICT: a % asset cannot change condition', a.status using errcode = 'integrity_constraint_violation';
  end if;
  update public.fixed_assets set condition = p_condition where id = a.id;
  -- Operational status only. Recognising a loss or write-off is a separate, explicit disposal (Step 07 §11).
  perform app_private.asset_event(a.id, 'condition_changed', p_date,
    jsonb_build_object('from', a.condition, 'to', p_condition), p_note);
end
$$;

-- ------------------------------------------------------------ splitting a draft into parts
-- One purchase line can be several physical assets. Splitting a draft keeps the cost of the line intact: the parts add
-- up to exactly what the ledger holds.
create function public.asset_split(p_asset uuid, p_key text, p_parts jsonb) returns uuid[]
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
  v_replay uuid;
  v_scale integer;
  v_part jsonb;
  v_costs numeric[] := array[]::numeric[];
  v_names text[] := array[]::text[];
  v_cost numeric;
  v_sum numeric := 0;
  v_ids uuid[] := array[]::uuid[];
  v_new uuid;
  v_code text;
  i integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: splitting an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('asset.split', a.entity_id, p_key, md5(jsonb_build_object('a', p_asset, 'p', p_parts)::text));
  if v_replay is not null then
    return (select array_agg(f.id order by f.asset_code) from public.fixed_assets f
            where f.entity_id = a.entity_id and (f.id = v_replay or f.split_from_asset_id = v_replay));
  end if;
  select * into a from public.fixed_assets where id = p_asset for update;
  if a.status <> 'draft' or a.source_type = 'opening' then
    raise exception 'CONFLICT: only a draft asset that came from a purchase line can be split' using errcode = 'integrity_constraint_violation';
  end if;
  if jsonb_typeof(p_parts) <> 'array' or jsonb_array_length(p_parts) not between 2 and 50 then
    raise exception 'INVALID: give 2 to 50 parts, each with a name and a cost' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(a.entity_id));
  for v_part in select * from jsonb_array_elements(p_parts) loop
    if jsonb_typeof(v_part) <> 'object' or length(btrim(coalesce(v_part ->> 'name', ''))) not between 1 and 200 then
      raise exception 'INVALID: every part needs a name of up to 200 characters' using errcode = 'invalid_parameter_value';
    end if;
    v_cost := app_private.money_arg(v_part ->> 'cost', 'the cost of a part', v_scale);
    v_costs := v_costs || v_cost;
    v_names := v_names || btrim(v_part ->> 'name');
    v_sum := v_sum + v_cost;
  end loop;
  if v_sum <> a.acquisition_cost then
    raise exception 'INVALID: the parts add up to % but the asset cost is %; they must be equal', trim_scale(v_sum),
      trim_scale(a.acquisition_cost) using errcode = 'invalid_parameter_value';
  end if;
  -- The first part stays the original asset; the others are new drafts from the same purchase line.
  update public.fixed_assets set name = v_names[1], acquisition_cost = v_costs[1] where id = a.id;
  v_ids := v_ids || a.id;
  perform app_private.ensure_asset_numbering(a.entity_id);
  for i in 2..array_length(v_costs, 1) loop
    v_new := gen_random_uuid();
    v_code := app_private.allocate_document_number(a.entity_id, 'asset', a.acquisition_date);
    insert into public.fixed_assets
      (id, entity_id, asset_code, name, source_type, bill_line_id, expense_line_id, cost_account_id, acquisition_date,
       acquisition_cost, split_from_asset_id, location, custodian, created_by)
    values
      (v_new, a.entity_id, v_code, v_names[i], a.source_type, a.bill_line_id, a.expense_line_id, a.cost_account_id,
       a.acquisition_date, v_costs[i], a.id, a.location, a.custodian, auth.uid());
    perform app_private.asset_event(v_new, 'split', app_private.entity_today(a.entity_id),
      jsonb_build_object('from', a.id, 'cost', v_costs[i]::text));
    v_ids := v_ids || v_new;
  end loop;
  perform app_private.asset_event(a.id, 'split', app_private.entity_today(a.entity_id),
    jsonb_build_object('parts', v_ids, 'cost', v_costs[1]::text));
  perform app_private.idem_complete('asset.split', a.entity_id, p_key, 'fixed_assets', a.id);
  return v_ids;
end
$$;

-- ------------------------------------------------------------ activation
create function public.asset_activate(
  p_asset uuid, p_key text, p_in_service date, p_method text, p_life_months integer, p_residual text default '0',
  p_fiscal_class text default null, p_fiscal_method text default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
  e public.entities%rowtype;
  v_replay uuid;
  v_scale integer;
  v_residual numeric;
  v_today date;
  v_class jsonb;
  v_fmethod text;
  m date;
  v_n integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: activating an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('asset.activate', a.entity_id, p_key,
    md5(jsonb_build_object('a', p_asset, 'd', p_in_service, 'm', p_method, 'l', p_life_months, 'r', p_residual,
                           'fc', p_fiscal_class, 'fm', p_fiscal_method)::text));
  if v_replay is not null then
    return (select count(*)::integer from public.asset_depreciation_lines where asset_id = p_asset and status <> 'cancelled');
  end if;
  select * into a from public.fixed_assets where id = p_asset for update;
  select * into e from public.entities where id = a.entity_id;
  if a.status <> 'draft' then
    raise exception 'CONFLICT: only a draft asset can be activated (now %)', a.status using errcode = 'integrity_constraint_violation';
  end if;
  v_today := app_private.entity_today(a.entity_id);
  v_scale := app_private.currency_scale(e.base_currency);
  if p_method is null or p_method not in ('none', 'straight_line', 'declining_balance') then
    raise exception 'INVALID: the method is none, straight_line or declining_balance' using errcode = 'invalid_parameter_value';
  end if;
  if e.entity_type = 'personal' and p_method <> 'none' then
    raise exception 'INVALID: personal assets are tracked at cost; they are not depreciated' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_in_service);
  if p_in_service < a.acquisition_date or p_in_service > v_today then
    raise exception 'INVALID: the in-service date is not before the acquisition (%) and not in the future', a.acquisition_date
      using errcode = 'invalid_parameter_value';
  end if;
  v_residual := app_private.money_arg(coalesce(nullif(btrim(p_residual), ''), '0'), 'the residual value', v_scale, true);
  if p_method = 'none' then
    if p_life_months is not null or v_residual <> 0 then
      raise exception 'INVALID: an asset that is not depreciated has no useful life and no residual value'
        using errcode = 'invalid_parameter_value';
    end if;
  else
    if p_life_months is null or p_life_months not between 1 and 1200 then
      raise exception 'INVALID: the useful life is 1 to 1200 months' using errcode = 'invalid_parameter_value';
    end if;
    if v_residual > a.acquisition_cost then
      raise exception 'INVALID: the residual value cannot exceed the cost' using errcode = 'invalid_parameter_value';
    end if;
    -- Every complete month up to now must be in a period that still accepts postings, or the schedule could never be
    -- posted (a backdated in-service date must not reach into closed months).
    m := date_trunc('month', p_in_service)::date;
    while app_private.month_end(m) < v_today loop
      if not app_private.period_postable(a.entity_id, app_private.month_end(m)) then
        raise exception 'CONFLICT: the period of % no longer accepts postings; choose an in-service date from an open period',
          to_char(m, 'YYYY-MM') using errcode = 'integrity_constraint_violation';
      end if;
      m := (m + interval '1 month')::date;
    end loop;
  end if;
  if p_fiscal_class is not null then
    v_class := app_private.fiscal_class(p_fiscal_class, p_in_service);
    if v_class is null then
      raise exception 'INVALID: unknown fiscal class % for that date', p_fiscal_class using errcode = 'invalid_parameter_value';
    end if;
    v_fmethod := coalesce(p_fiscal_method, 'straight_line');
    if v_fmethod not in ('straight_line', 'declining_balance')
       or (v_fmethod = 'declining_balance' and (v_class ->> 'db_rate') is null) then
      raise exception 'INVALID: that fiscal class allows straight-line only' using errcode = 'invalid_parameter_value';
    end if;
  elsif p_fiscal_method is not null then
    raise exception 'INVALID: a fiscal method needs a fiscal class' using errcode = 'invalid_parameter_value';
  end if;

  update public.fixed_assets
  set status = 'active', in_service_date = p_in_service, depreciation_method = p_method, useful_life_months = p_life_months,
      residual_value = v_residual, plan_version = 1, fiscal_class_key = p_fiscal_class,
      fiscal_method = case when p_fiscal_class is not null then v_fmethod end,
      activated_at = now(), activated_by = auth.uid()
  where id = a.id;
  v_n := app_private.asset_generate_schedule(a.id);
  perform app_private.asset_event(a.id, 'activated', p_in_service,
    jsonb_build_object('method', p_method, 'life_months', p_life_months, 'residual', v_residual::text, 'lines', v_n,
                       'fiscal_class', p_fiscal_class));
  perform app_private.idem_complete('asset.activate', a.entity_id, p_key, 'fixed_assets', a.id);
  return v_n;
end
$$;

-- ------------------------------------------------------------ re-planning (change of estimate, prospective)
create function public.asset_replan(
  p_asset uuid, p_key text, p_method text, p_remaining_months integer, p_residual text, p_reason text)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
  v_replay uuid;
  v_scale integer;
  v_residual numeric;
  v_last date;
  v_from date;
  v_elapsed integer;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_n integer;
  v_nbv numeric;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: re-planning an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('asset.replan', a.entity_id, p_key,
    md5(jsonb_build_object('a', p_asset, 'm', p_method, 'r', p_remaining_months, 'res', p_residual, 'why', p_reason)::text));
  if v_replay is not null then
    return (select count(*)::integer from public.asset_depreciation_lines where asset_id = p_asset and status = 'scheduled');
  end if;
  select * into a from public.fixed_assets where id = p_asset for update;
  if a.status <> 'active' or a.depreciation_method = 'none' then
    raise exception 'CONFLICT: only an active, depreciated asset can be re-planned' using errcode = 'integrity_constraint_violation';
  end if;
  if length(v_reason) < 5 or length(v_reason) > 1000 then
    raise exception 'INVALID: a change of estimate needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  if p_method not in ('straight_line', 'declining_balance') or p_remaining_months is null or p_remaining_months not between 1 and 1200 then
    raise exception 'INVALID: the method is straight_line or declining_balance and 1 to 1200 months remain'
      using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(a.entity_id));
  v_residual := app_private.money_arg(coalesce(nullif(btrim(p_residual), ''), '0'), 'the residual value', v_scale, true);
  v_nbv := a.acquisition_cost - app_private.asset_accumulated(a.id);
  if v_residual > v_nbv then
    raise exception 'INVALID: the residual value cannot exceed the current book value (%)', trim_scale(v_nbv)
      using errcode = 'invalid_parameter_value';
  end if;
  select max(l.period_month) into v_last from public.asset_depreciation_lines l where l.asset_id = a.id and l.status = 'posted';
  if v_last is not null and exists (
       select 1 from public.asset_depreciation_lines l where l.asset_id = a.id and l.status = 'scheduled' and l.period_month < v_last) then
    raise exception 'CONFLICT: a month before the latest posted depreciation of % is still unposted; post it first', a.asset_code
      using errcode = 'integrity_constraint_violation';
  end if;
  if v_last is not null then
    v_from := (v_last + interval '1 month')::date;
  elsif a.source_type = 'opening' then
    v_from := (date_trunc('month', a.opening_cutover) + interval '1 month')::date;
  else
    v_from := date_trunc('month', a.in_service_date)::date;
  end if;
  v_elapsed := (extract(year from v_from)::integer - extract(year from a.in_service_date)::integer) * 12
             + extract(month from v_from)::integer - extract(month from a.in_service_date)::integer;
  update public.asset_depreciation_lines set status = 'cancelled', cancelled_at = now()
  where asset_id = a.id and status = 'scheduled';
  update public.fixed_assets
  set depreciation_method = p_method, residual_value = v_residual, useful_life_months = v_elapsed + p_remaining_months,
      plan_version = a.plan_version + 1
  where id = a.id;
  v_n := app_private.asset_generate_schedule(a.id);
  perform app_private.asset_event(a.id, 'replanned', app_private.entity_today(a.entity_id),
    jsonb_build_object('from_method', a.depreciation_method, 'to_method', p_method, 'from_life', a.useful_life_months,
                       'to_life', v_elapsed + p_remaining_months, 'from_residual', a.residual_value::text,
                       'to_residual', v_residual::text, 'from_month', v_from, 'lines', v_n), v_reason);
  perform app_private.idem_complete('asset.replan', a.entity_id, p_key, 'fixed_assets', a.id);
  return v_n;
end
$$;

-- ------------------------------------------------------------ cancelling an asset
-- Cancels a draft or an active asset that carries no posted depreciation. The parts of one purchase line go together:
-- the cost of the line must stay registered as a whole, so a line whose assets are cancelled returns to `pending`.
create function public.asset_cancel(p_asset uuid, p_key text, p_reason text) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
  s public.fixed_assets%rowtype;
  v_replay uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_n integer := 0;
  v_today date;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: cancelling an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('asset.cancel', a.entity_id, p_key, md5(jsonb_build_object('a', p_asset, 'r', p_reason)::text));
  if v_replay is not null then
    return 0;
  end if;
  if length(v_reason) < 5 or length(v_reason) > 1000 then
    raise exception 'INVALID: cancelling an asset needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_today := app_private.entity_today(a.entity_id);
  for s in
    select f.* from public.fixed_assets f
    where f.entity_id = a.entity_id and f.status <> 'cancelled'
      and (f.id = a.id
           or (a.bill_line_id is not null and f.bill_line_id = a.bill_line_id)
           or (a.expense_line_id is not null and f.expense_line_id = a.expense_line_id))
    order by f.asset_code
    for update
  loop
    if s.status in ('sold', 'disposed')
       or exists (select 1 from public.asset_depreciation_lines d where d.asset_id = s.id and d.status = 'posted') then
      raise exception 'CONFLICT: asset % carries depreciation or a disposal and cannot be cancelled', s.asset_code
        using errcode = 'integrity_constraint_violation';
    end if;
    update public.asset_depreciation_lines set status = 'cancelled', cancelled_at = now()
    where asset_id = s.id and status = 'scheduled';
    update public.fixed_assets
    set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancelled_date = v_today, cancel_reason = v_reason
    where id = s.id;
    perform app_private.asset_event(s.id, 'cancelled', v_today, '{}'::jsonb, v_reason);
    v_n := v_n + 1;
  end loop;
  if a.bill_line_id is not null then
    update public.bill_lines set asset_link_status = 'pending' where id = a.bill_line_id and asset_link_status = 'linked';
  elsif a.expense_line_id is not null then
    update public.expense_lines set asset_link_status = 'pending' where id = a.expense_line_id and asset_link_status = 'linked';
  end if;
  perform app_private.idem_complete('asset.cancel', a.entity_id, p_key, 'fixed_assets', a.id);
  return v_n;
end
$$;

-- Registers a line that went back to `pending` (its asset was cancelled) as a new draft asset.
create function public.asset_register_pending(p_kind text, p_line uuid) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_kind = 'bill_line' then
    select l.entity_id, l.asset_link_status into v_entity, v_status from public.bill_lines l where l.id = p_line;
  elsif p_kind = 'expense_line' then
    select l.entity_id, l.asset_link_status into v_entity, v_status from public.expense_lines l where l.id = p_line;
  else
    raise exception 'INVALID: the line kind is bill_line or expense_line' using errcode = 'invalid_parameter_value';
  end if;
  if v_entity is null or not app_authz.has_permission(v_entity, 'assets.manage') then
    raise exception 'FORBIDDEN: registering an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  if v_status <> 'pending' then
    raise exception 'CONFLICT: only a pending asset line can be registered (now %)', v_status using errcode = 'integrity_constraint_violation';
  end if;
  return app_private.asset_register_line(p_kind, p_line);
end
$$;

-- ------------------------------------------------------------ posting the depreciation
create function public.asset_post_depreciation(p_entity uuid, p_through date) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l record;
  v_n integer := 0;
  v_total numeric := 0;
  v_today date;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'assets.manage') then
    raise exception 'FORBIDDEN: posting depreciation needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  v_today := app_private.entity_today(p_entity);
  if p_through is null or p_through <> app_private.month_end(p_through) or p_through > v_today then
    raise exception 'INVALID: post through the last day of a month that is not in the future' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_through);
  -- One batch at a time per Entity: two runs can never post the same month twice, and a run is naturally repeatable.
  perform pg_advisory_xact_lock(hashtextextended('asset_depreciation:' || p_entity::text, 0));
  for l in
    select d.id, d.amount from public.asset_depreciation_lines d
    join public.fixed_assets f on f.id = d.asset_id and f.entity_id = d.entity_id
    where d.entity_id = p_entity and d.status = 'scheduled' and f.status = 'active'
      and app_private.month_end(d.period_month) <= p_through
    order by d.period_month, f.asset_code
  loop
    perform app_private.asset_post_line(l.id);
    v_n := v_n + 1;
    v_total := v_total + l.amount;
  end loop;
  return jsonb_build_object('posted', v_n, 'total', v_total::text, 'through', p_through);
end
$$;

create function public.asset_reverse_depreciation(p_line uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.asset_depreciation_lines%rowtype;
  a public.fixed_assets%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.asset_depreciation_lines where id = p_line;
  if not found or not app_authz.has_permission(l.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: reversing depreciation needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 or length(v_reason) > 1000 or p_date > app_private.entity_today(l.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of 5 to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform pg_advisory_xact_lock(hashtextextended('asset_depreciation:' || l.entity_id::text, 0));
  v_replay := app_private.idem_begin('asset.reverse_depreciation', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_line, 'd', p_date, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into l from public.asset_depreciation_lines where id = p_line for update;
  select * into a from public.fixed_assets where id = l.asset_id for update;
  if l.status <> 'posted' then
    raise exception 'CONFLICT: only a posted month can be reversed (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  if a.status <> 'active' then
    raise exception 'CONFLICT: reverse the disposal of % before its depreciation', a.asset_code using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < app_private.month_end(l.period_month) then
    raise exception 'INVALID: a reversal cannot be dated before the month it reverses' using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(l.journal_id, p_date, v_reason);
  update public.asset_depreciation_lines
  set status = 'reversed', reversal_journal_id = v_rev, reversed_date = p_date, reversed_at = now(), reversed_by = auth.uid(),
      reverse_reason = v_reason
  where id = l.id;
  -- The month is due again with the same amount; a re-plan can change it before it is posted.
  insert into public.asset_depreciation_lines (entity_id, asset_id, period_month, amount, plan_version, created_by)
  values (l.entity_id, l.asset_id, l.period_month, l.amount, a.plan_version, auth.uid());
  perform app_private.asset_event(a.id, 'depreciation_reversed', p_date,
    jsonb_build_object('month', to_char(l.period_month, 'YYYY-MM'), 'amount', l.amount::text), v_reason);
  perform app_private.idem_complete('asset.reverse_depreciation', l.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

-- ------------------------------------------------------------ disposal
create function public.asset_dispose(
  p_asset uuid, p_key text, p_type text, p_date date, p_proceeds text, p_method text, p_account uuid,
  p_counterparty text, p_due date, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
  fa public.financial_accounts%rowtype;
  l record;
  v_replay uuid;
  v_scale integer;
  v_today date;
  v_proceeds numeric;
  v_accum numeric;
  v_nbv numeric;
  v_gl numeric;
  v_id uuid := gen_random_uuid();
  v_obl uuid;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_month date;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: disposing of an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('asset.dispose', a.entity_id, p_key,
    md5(jsonb_build_object('a', p_asset, 't', p_type, 'd', p_date, 'p', p_proceeds, 'm', p_method, 'acc', p_account,
                           'c', p_counterparty, 'due', p_due, 'r', p_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('asset_depreciation:' || a.entity_id::text, 0));
  select * into a from public.fixed_assets where id = p_asset for update;
  if a.status <> 'active' then
    raise exception 'CONFLICT: only an active asset can be sold or disposed of (now %)', a.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_type is null or p_type not in ('sale', 'scrapped', 'lost', 'damaged', 'donated')
     or p_method is null or p_method not in ('cash', 'receivable', 'none') then
    raise exception 'INVALID: the type is sale, scrapped, lost, damaged or donated; the proceeds are cash, receivable or none'
      using errcode = 'invalid_parameter_value';
  end if;
  if length(v_reason) < 3 or length(v_reason) > 1000 then
    raise exception 'INVALID: state the reason (3 to 1000 characters)' using errcode = 'invalid_parameter_value';
  end if;
  v_today := app_private.entity_today(a.entity_id);
  v_scale := app_private.currency_scale(app_private.entity_base_currency(a.entity_id));
  perform app_private.assert_business_date(p_date);
  if p_date > v_today or p_date < a.in_service_date then
    raise exception 'INVALID: the disposal date is not in the future and not before the in-service date (%)', a.in_service_date
      using errcode = 'invalid_parameter_value';
  end if;
  v_month := date_trunc('month', p_date)::date;
  if exists (select 1 from public.asset_depreciation_lines d where d.asset_id = a.id and d.status = 'posted' and d.period_month >= v_month) then
    raise exception 'CONFLICT: depreciation is already posted for the month of the disposal or later; reverse it first'
      using errcode = 'integrity_constraint_violation';
  end if;
  v_proceeds := app_private.money_arg(coalesce(nullif(btrim(p_proceeds), ''), '0'), 'the proceeds', v_scale, true);
  if p_type <> 'sale' and (v_proceeds <> 0 or p_method <> 'none') then
    raise exception 'INVALID: only a sale has proceeds' using errcode = 'invalid_parameter_value';
  end if;
  if (v_proceeds = 0) <> (p_method = 'none') then
    raise exception 'INVALID: proceeds need a method (cash or receivable) and no method means no proceeds'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_method = 'cash' then
    fa := app_private.base_cash_account(a.entity_id, p_account);
  elsif p_account is not null then
    raise exception 'INVALID: an account is given only for cash proceeds' using errcode = 'invalid_parameter_value';
  end if;
  if p_method = 'receivable' and length(btrim(coalesce(p_counterparty, ''))) not between 1 and 200 then
    raise exception 'INVALID: a sale on credit needs the name of the buyer' using errcode = 'invalid_parameter_value';
  end if;
  if p_method = 'receivable' and p_due is not null and p_due < p_date then
    raise exception 'INVALID: the due date cannot be before the disposal' using errcode = 'invalid_parameter_value';
  end if;

  -- Depreciation is brought up to the month before the disposal (the month of disposal is not depreciated); what the
  -- schedule still held from the month of disposal on is cancelled, never deleted.
  for l in
    select d.id from public.asset_depreciation_lines d
    where d.asset_id = a.id and d.status = 'scheduled' and d.period_month < v_month
    order by d.period_month
  loop
    perform app_private.asset_post_line(l.id);
  end loop;
  update public.asset_depreciation_lines set status = 'cancelled', cancelled_at = now()
  where asset_id = a.id and status = 'scheduled';

  v_accum := app_private.asset_accumulated(a.id);
  v_nbv := a.acquisition_cost - v_accum;
  v_gl := v_proceeds - v_nbv;
  perform app_private.assert_maker_checker(a.entity_id, 'assets', 'dispose', greatest(v_nbv, v_proceeds), auth.uid(),
    'record this disposal');

  v_desc := format('%s of asset %s - %s', case p_type when 'sale' then 'Sale' else 'Disposal' end, a.asset_code, left(a.name, 100));
  if p_method = 'cash' then
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', v_proceeds, 'credit', 0, 'description', v_desc);
  elsif p_method = 'receivable' then
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(a.entity_id, 'other_receivable'),
                                             'debit', v_proceeds, 'credit', 0, 'description', v_desc);
  end if;
  if v_accum > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(a.entity_id, 'accumulated_depreciation'),
                                             'debit', v_accum, 'credit', 0, 'description', v_desc);
  end if;
  if v_gl < 0 then
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(a.entity_id, 'disposal_result'),
                                             'debit', -v_gl, 'credit', 0, 'description', 'Loss: ' || v_desc);
  end if;
  v_lines := v_lines || jsonb_build_object('account_id', a.cost_account_id, 'debit', 0, 'credit', a.acquisition_cost, 'description', v_desc);
  if v_gl > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(a.entity_id, 'disposal_result'),
                                             'debit', 0, 'credit', v_gl, 'description', 'Gain: ' || v_desc);
  end if;
  v_journal := app_private.post_system_journal(a.entity_id, 'asset_disposal', v_id, 'asset.dispose', 'asset.v1', p_date, v_desc, v_lines);
  if p_method = 'cash' then
    perform app_private.record_movement(a.entity_id, p_account, 'in', v_proceeds, v_proceeds, null, p_date, 'asset_disposal', v_id,
      'principal', v_journal, v_desc);
  elsif p_method = 'receivable' then
    v_obl := gen_random_uuid();
    perform app_private.obligation_insert(a.entity_id, v_obl, 'receivable', p_counterparty, null, p_date, p_due, v_proceeds,
      'asset_disposal', null, null, 'Sale of asset ' || a.asset_code || ' - ' || left(a.name, 100), 'asset_disposal', v_id,
      v_journal, null, null);
  end if;
  insert into public.asset_disposals
    (id, entity_id, asset_id, disposal_type, disposal_date, proceeds, proceeds_method, financial_account_id, obligation_id,
     cost_removed, accumulated_removed, net_book_value, gain_loss, reason, journal_id, created_by)
  values
    (v_id, a.entity_id, a.id, p_type, p_date, v_proceeds, p_method, case p_method when 'cash' then p_account end, v_obl,
     a.acquisition_cost, v_accum, v_nbv, v_gl, v_reason, v_journal, auth.uid());
  update public.fixed_assets
  set status = case p_type when 'sale' then 'sold' else 'disposed' end,
      condition = case p_type when 'lost' then 'lost' when 'damaged' then 'damaged' else condition end
  where id = a.id;
  perform app_private.asset_event(a.id, 'disposed', p_date,
    jsonb_build_object('type', p_type, 'proceeds', v_proceeds::text, 'net_book_value', v_nbv::text, 'gain_loss', v_gl::text,
                       'disposal', v_id), v_reason);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (a.entity_id, 'AssetDisposed', 'fixed_asset', a.id, jsonb_build_object('code', a.asset_code, 'type', p_type));
  perform app_private.idem_complete('asset.dispose', a.entity_id, p_key, 'asset_disposals', v_id);
  return v_id;
end
$$;

create function public.asset_reverse_disposal(p_disposal uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  d public.asset_disposals%rowtype;
  a public.fixed_assets%rowtype;
  o public.other_obligations%rowtype;
  m public.money_movements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
  v_min date;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into d from public.asset_disposals where id = p_disposal;
  if not found or not app_authz.has_permission(d.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: reversing a disposal needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 or length(v_reason) > 1000 or p_date > app_private.entity_today(d.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of 5 to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform pg_advisory_xact_lock(hashtextextended('asset_depreciation:' || d.entity_id::text, 0));
  v_replay := app_private.idem_begin('asset.reverse_disposal', d.entity_id, p_key,
    md5(jsonb_build_object('d', p_disposal, 'date', p_date, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into d from public.asset_disposals where id = p_disposal for update;
  select * into a from public.fixed_assets where id = d.asset_id for update;
  if d.status <> 'posted' then
    raise exception 'CONFLICT: only a posted disposal can be reversed (now %)', d.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < d.disposal_date then
    raise exception 'INVALID: a reversal cannot be dated before the disposal' using errcode = 'invalid_parameter_value';
  end if;
  if d.obligation_id is not null then
    select * into o from public.other_obligations where id = d.obligation_id for update;
    if exists (select 1 from public.other_obligation_settlements s where s.obligation_id = o.id and s.status = 'active') then
      raise exception 'CONFLICT: the buyer has paid part of this sale; reverse those settlements first'
        using errcode = 'integrity_constraint_violation';
    end if;
    select greatest(o.obligation_date, coalesce(max(s.settlement_date), o.obligation_date), coalesce(max(s.reversed_date), o.obligation_date))
      into v_min from public.other_obligation_settlements s where s.obligation_id = o.id;
    if p_date < v_min then
      raise exception 'INVALID: the date cannot be before the last settlement activity on the sale (%)', v_min
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  if d.financial_account_id is not null then
    perform 1 from public.financial_accounts where id = d.financial_account_id and entity_id = d.entity_id for no key update;
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(d.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = d.entity_id and source_type = 'asset_disposal' and source_id = d.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(d.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'asset_disposal', d.id, m.component, v_rev, 'Reversal: ' || v_reason, m.id);
  end loop;
  -- The receivable the sale created was in the disposal journal, which the reversal has just cancelled.
  if d.obligation_id is not null then
    update public.other_obligations
    set status = 'void', reversal_journal_id = v_rev, voided_at = now(), voided_by = auth.uid(), voided_date = p_date,
        void_reason = 'The disposal was reversed: ' || left(v_reason, 900)
    where id = o.id;
  end if;
  update public.asset_disposals
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date, reversed_by = auth.uid(),
      reverse_reason = v_reason
  where id = d.id;
  update public.fixed_assets set status = 'active' where id = a.id;
  perform app_private.asset_generate_schedule(a.id);
  perform app_private.asset_event(a.id, 'disposal_reversed', p_date, jsonb_build_object('disposal', d.id), v_reason);
  perform app_private.idem_complete('asset.reverse_disposal', d.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

-- ------------------------------------------------------------ the fiscal memo
create function public.asset_set_fiscal_class(p_asset uuid, p_class text, p_method text default 'straight_line') returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
  v_class jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.manage') then
    raise exception 'FORBIDDEN: changing an asset needs assets.manage' using errcode = 'insufficient_privilege';
  end if;
  select * into a from public.fixed_assets where id = p_asset for update;
  if a.status in ('draft', 'cancelled') then
    raise exception 'CONFLICT: the fiscal class is set when the asset is activated' using errcode = 'integrity_constraint_violation';
  end if;
  v_class := app_private.fiscal_class(p_class, a.in_service_date);
  if v_class is null then
    raise exception 'INVALID: unknown fiscal class % for the in-service date', p_class using errcode = 'invalid_parameter_value';
  end if;
  if p_method not in ('straight_line', 'declining_balance') or (p_method = 'declining_balance' and (v_class ->> 'db_rate') is null) then
    raise exception 'INVALID: that fiscal class allows straight-line only' using errcode = 'invalid_parameter_value';
  end if;
  update public.fixed_assets set fiscal_class_key = p_class, fiscal_method = p_method where id = a.id;
  perform app_private.asset_event(a.id, 'fiscal_class_set', app_private.entity_today(a.entity_id),
    jsonb_build_object('class', p_class, 'method', p_method));
end
$$;

-- ------------------------------------------------------------ privileges
call app_private.expose_select('public.fixed_assets');
create policy fixed_assets_select on public.fixed_assets for select to authenticated
  using (app_authz.has_permission(entity_id, 'assets.view'));
call app_private.expose_select('public.asset_depreciation_lines');
create policy asset_depreciation_lines_select on public.asset_depreciation_lines for select to authenticated
  using (app_authz.has_permission(entity_id, 'assets.view'));
call app_private.expose_select('public.asset_events');
create policy asset_events_select on public.asset_events for select to authenticated
  using (app_authz.has_permission(entity_id, 'assets.view'));
call app_private.expose_select('public.asset_disposals');
create policy asset_disposals_select on public.asset_disposals for select to authenticated
  using (app_authz.has_permission(entity_id, 'assets.view'));

revoke all on function app_private.tg_asset_disposals_guard() from public;
revoke all on function app_private.asset_accumulated(uuid, date) from public;
revoke all on function app_private.asset_disposed_as_of(uuid, date) from public;
revoke all on function app_private.fiscal_class(text, date) from public;
revoke all on function app_private.asset_generate_schedule(uuid, integer) from public;
revoke all on function app_private.asset_post_line(uuid) from public;

revoke all on function public.asset_update_details(uuid, text, text, text) from public, anon;
revoke all on function public.asset_transfer(uuid, text, text, date, text) from public, anon;
revoke all on function public.asset_set_condition(uuid, text, date, text) from public, anon;
revoke all on function public.asset_split(uuid, text, jsonb) from public, anon;
revoke all on function public.asset_activate(uuid, text, date, text, integer, text, text, text) from public, anon;
revoke all on function public.asset_replan(uuid, text, text, integer, text, text) from public, anon;
revoke all on function public.asset_cancel(uuid, text, text) from public, anon;
revoke all on function public.asset_register_pending(text, uuid) from public, anon;
revoke all on function public.asset_post_depreciation(uuid, date) from public, anon;
revoke all on function public.asset_reverse_depreciation(uuid, text, date, text) from public, anon;
revoke all on function public.asset_dispose(uuid, text, text, date, text, text, uuid, text, date, text) from public, anon;
revoke all on function public.asset_reverse_disposal(uuid, text, date, text) from public, anon;
revoke all on function public.asset_set_fiscal_class(uuid, text, text) from public, anon;
grant execute on function public.asset_update_details(uuid, text, text, text) to authenticated;
grant execute on function public.asset_transfer(uuid, text, text, date, text) to authenticated;
grant execute on function public.asset_set_condition(uuid, text, date, text) to authenticated;
grant execute on function public.asset_split(uuid, text, jsonb) to authenticated;
grant execute on function public.asset_activate(uuid, text, date, text, integer, text, text, text) to authenticated;
grant execute on function public.asset_replan(uuid, text, text, integer, text, text) to authenticated;
grant execute on function public.asset_cancel(uuid, text, text) to authenticated;
grant execute on function public.asset_register_pending(text, uuid) to authenticated;
grant execute on function public.asset_post_depreciation(uuid, date) to authenticated;
grant execute on function public.asset_reverse_depreciation(uuid, text, date, text) to authenticated;
grant execute on function public.asset_dispose(uuid, text, text, date, text, text, uuid, text, date, text) to authenticated;
grant execute on function public.asset_reverse_disposal(uuid, text, date, text) to authenticated;
grant execute on function public.asset_set_fiscal_class(uuid, text, text) to authenticated;
