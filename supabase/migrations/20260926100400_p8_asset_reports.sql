-- P8 part 5 (Step 12 §8, Step 08 §19, Step 15 §12): opening assets, the register and depreciation reports, the fiscal
-- memo schedule and the asset control against the General Ledger.
--
-- The fiscal schedule is a MEMO (Step 05 "accounting and fiscal depreciation remain separately identifiable"): it is
-- computed from the fiscal group rule in force on the in-service date and never posts anything.

-- ------------------------------------------------------------ opening assets (data cut-over)
-- Assets that existed before the system: their cost and the depreciation accumulated up to the cut-over date. No journal
-- is posted here - the opening balances of the ledger are posted by the opening balance batch, and the control
-- compares the two. The schedule continues from the month after the cut-over.
create function public.asset_load_opening(p_entity uuid, p_key text, p_assets jsonb) returns uuid[]
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  v_replay uuid;
  v_scale integer;
  v_today date;
  v_item jsonb;
  v_ids uuid[] := array[]::uuid[];
  v_id uuid;
  v_code text;
  v_cost numeric;
  v_accum numeric;
  v_residual numeric;
  v_method text;
  v_life integer;
  v_acq date;
  v_svc date;
  v_cut date;
  v_account uuid;
  v_class jsonb;
  v_fclass text;
  v_fmethod text;
  v_n integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'system.import') then
    raise exception 'FORBIDDEN: loading opening assets needs system.import' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('asset.load_opening', p_entity, p_key, md5(coalesce(p_assets::text, '')));
  if v_replay is not null then
    return (select array_agg(f.id order by f.asset_code) from public.fixed_assets f
            where f.entity_id = p_entity and f.source_type = 'opening'
              and f.created_at = (select x.created_at from public.fixed_assets x where x.id = v_replay));
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_typeof(p_assets) <> 'array' or jsonb_array_length(p_assets) not between 1 and 500 then
    raise exception 'INVALID: give 1 to 500 assets' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(e.base_currency);
  v_today := app_private.entity_today(p_entity);
  perform app_private.ensure_asset_numbering(p_entity);
  for v_item in select * from jsonb_array_elements(p_assets) loop
    if jsonb_typeof(v_item) <> 'object' or length(btrim(coalesce(v_item ->> 'name', ''))) not between 1 and 200 then
      raise exception 'INVALID: every asset needs a name of up to 200 characters' using errcode = 'invalid_parameter_value';
    end if;
    begin
      v_account := (v_item ->> 'cost_account')::uuid;
      v_acq := (v_item ->> 'acquisition_date')::date;
      v_svc := (v_item ->> 'in_service_date')::date;
      v_cut := (v_item ->> 'cutover_date')::date;
      v_life := (v_item ->> 'life_months')::integer;
    exception when others then
      raise exception 'INVALID: an asset has an unreadable account, date or life' using errcode = 'invalid_parameter_value';
    end;
    if v_account is null or not app_private.is_fixed_asset_account(p_entity, v_account) then
      raise exception 'INVALID: the cost account of % is not a fixed-asset account of this Entity', v_item ->> 'name'
        using errcode = 'invalid_parameter_value';
    end if;
    if v_acq is null or v_svc is null or v_cut is null or v_svc < v_acq or v_cut < v_svc or v_cut > v_today then
      raise exception 'INVALID: % needs acquisition <= in-service <= cut-over <= today', v_item ->> 'name'
        using errcode = 'invalid_parameter_value';
    end if;
    perform app_private.assert_business_date(v_acq);
    v_method := coalesce(v_item ->> 'method', 'none');
    if v_method not in ('none', 'straight_line', 'declining_balance') or (e.entity_type = 'personal' and v_method <> 'none') then
      raise exception 'INVALID: the method of % is not allowed for this Entity', v_item ->> 'name' using errcode = 'invalid_parameter_value';
    end if;
    v_cost := app_private.money_arg(v_item ->> 'cost', 'the cost', v_scale);
    v_accum := app_private.money_arg(coalesce(v_item ->> 'accumulated', '0'), 'the accumulated depreciation', v_scale, true);
    v_residual := app_private.money_arg(coalesce(v_item ->> 'residual', '0'), 'the residual value', v_scale, true);
    if v_method = 'none' and (v_accum <> 0 or v_residual <> 0 or v_life is not null) then
      raise exception 'INVALID: % is not depreciated, so it has no life, residual or accumulated depreciation', v_item ->> 'name'
        using errcode = 'invalid_parameter_value';
    end if;
    if v_method <> 'none' and (v_life is null or v_life not between 1 and 1200 or v_residual > v_cost or v_accum > v_cost - v_residual) then
      raise exception 'INVALID: the life, residual or accumulated depreciation of % does not fit its cost', v_item ->> 'name'
        using errcode = 'invalid_parameter_value';
    end if;
    v_fclass := nullif(v_item ->> 'fiscal_class', '');
    v_fmethod := null;
    if v_fclass is not null then
      v_class := app_private.fiscal_class(v_fclass, v_svc);
      v_fmethod := coalesce(v_item ->> 'fiscal_method', 'straight_line');
      if v_class is null or v_fmethod not in ('straight_line', 'declining_balance')
         or (v_fmethod = 'declining_balance' and (v_class ->> 'db_rate') is null) then
        raise exception 'INVALID: the fiscal class of % is unknown or does not allow that method', v_item ->> 'name'
          using errcode = 'invalid_parameter_value';
      end if;
    end if;
    v_id := gen_random_uuid();
    v_code := app_private.allocate_document_number(p_entity, 'asset', v_acq);
    insert into public.fixed_assets
      (id, entity_id, asset_code, name, description, serial_number, status, location, custodian, source_type, cost_account_id,
       acquisition_date, acquisition_cost, in_service_date, depreciation_method, useful_life_months, residual_value,
       opening_accumulated, opening_cutover, plan_version, fiscal_class_key, fiscal_method, activated_at, activated_by, created_by)
    values
      (v_id, p_entity, v_code, btrim(v_item ->> 'name'), nullif(btrim(coalesce(v_item ->> 'description', '')), ''),
       nullif(btrim(coalesce(v_item ->> 'serial_number', '')), ''), 'active',
       nullif(btrim(coalesce(v_item ->> 'location', '')), ''), nullif(btrim(coalesce(v_item ->> 'custodian', '')), ''),
       'opening', v_account, v_acq, v_cost, v_svc, v_method, v_life, v_residual, v_accum, v_cut, 1, v_fclass, v_fmethod,
       now(), auth.uid(), auth.uid());
    v_n := app_private.asset_generate_schedule(v_id);
    perform app_private.asset_event(v_id, 'opening_loaded', v_cut,
      jsonb_build_object('cost', v_cost::text, 'accumulated', v_accum::text, 'lines', v_n));
    v_ids := v_ids || v_id;
  end loop;
  perform app_private.idem_complete('asset.load_opening', p_entity, p_key, 'fixed_assets', v_ids[1]);
  return v_ids;
end
$$;

-- ------------------------------------------------------------ reading the register
create function public.asset_register(
  p_entity uuid, p_status text default null, p_as_of date default null, p_limit integer default 200)
returns table (asset_id uuid, asset_code text, name text, status text, condition text, location text, custodian text,
               source_type text, acquisition_date date, in_service_date date, acquisition_cost text, accumulated text,
               net_book_value text, depreciation_method text, useful_life_months integer, residual_value text,
               fiscal_class_key text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_asof date;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'assets.view') then
    raise exception 'FORBIDDEN: missing assets.view' using errcode = 'insufficient_privilege';
  end if;
  v_asof := coalesce(p_as_of, app_private.entity_today(p_entity));
  return query
  select f.id, f.asset_code, f.name, f.status, f.condition, f.location, f.custodian, f.source_type, f.acquisition_date,
         f.in_service_date, f.acquisition_cost::text,
         (case when f.status = 'draft' then 0::numeric else app_private.asset_accumulated(f.id, v_asof) end)::text,
         (f.acquisition_cost - case when f.status = 'draft' then 0::numeric else app_private.asset_accumulated(f.id, v_asof) end)::text,
         f.depreciation_method, f.useful_life_months, f.residual_value::text, f.fiscal_class_key
  from public.fixed_assets f
  where f.entity_id = p_entity and (p_status is null or f.status = p_status)
  order by f.asset_code
  limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end
$$;

create function public.asset_detail(p_asset uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.view') then
    raise exception 'FORBIDDEN: missing assets.view' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'asset', jsonb_build_object(
      'id', a.id, 'code', a.asset_code, 'name', a.name, 'description', a.description, 'serial_number', a.serial_number,
      'status', a.status, 'condition', a.condition, 'location', a.location, 'custodian', a.custodian,
      'source_type', a.source_type, 'bill_line_id', a.bill_line_id, 'expense_line_id', a.expense_line_id,
      'cost_account_id', a.cost_account_id, 'acquisition_date', a.acquisition_date, 'in_service_date', a.in_service_date,
      'acquisition_cost', a.acquisition_cost::text, 'depreciation_method', a.depreciation_method,
      'useful_life_months', a.useful_life_months, 'residual_value', a.residual_value::text,
      'opening_accumulated', a.opening_accumulated::text, 'opening_cutover', a.opening_cutover,
      'plan_version', a.plan_version, 'fiscal_class_key', a.fiscal_class_key, 'fiscal_method', a.fiscal_method,
      'accumulated', (case when a.status = 'draft' then 0::numeric else app_private.asset_accumulated(a.id) end)::text,
      'net_book_value', (a.acquisition_cost - case when a.status = 'draft' then 0::numeric else app_private.asset_accumulated(a.id) end)::text,
      'split_from_asset_id', a.split_from_asset_id, 'cancelled_date', a.cancelled_date, 'cancel_reason', a.cancel_reason,
      'version', a.version),
    'schedule', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'month', to_char(l.period_month, 'YYYY-MM'), 'amount', l.amount::text, 'status', l.status,
        'plan_version', l.plan_version, 'journal_id', l.journal_id, 'reversal_journal_id', l.reversal_journal_id)
        order by l.period_month, l.created_at)
      from public.asset_depreciation_lines l where l.asset_id = a.id), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', ev.event_type, 'date', ev.event_date, 'details', ev.details, 'note', ev.note, 'at', ev.created_at)
        order by ev.created_at)
      from public.asset_events ev where ev.asset_id = a.id), '[]'::jsonb),
    'disposal', (
      select jsonb_build_object(
        'id', d.id, 'type', d.disposal_type, 'date', d.disposal_date, 'status', d.status, 'proceeds', d.proceeds::text,
        'proceeds_method', d.proceeds_method, 'cost_removed', d.cost_removed::text,
        'accumulated_removed', d.accumulated_removed::text, 'net_book_value', d.net_book_value::text,
        'gain_loss', d.gain_loss::text, 'journal_id', d.journal_id, 'obligation_id', d.obligation_id)
      from public.asset_disposals d where d.asset_id = a.id order by d.created_at desc limit 1));
end
$$;

-- The accounting depreciation schedule by asset and month (Step 12 §8), including what was posted, cancelled and reversed.
create function public.asset_depreciation_report(
  p_entity uuid, p_from date default null, p_to date default null, p_limit integer default 500)
returns table (asset_id uuid, asset_code text, asset_name text, period_month date, amount text, status text,
               plan_version integer, journal_id uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'assets.view') then
    raise exception 'FORBIDDEN: missing assets.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select f.id, f.asset_code, f.name, l.period_month, l.amount::text, l.status, l.plan_version, l.journal_id
  from public.asset_depreciation_lines l
  join public.fixed_assets f on f.id = l.asset_id and f.entity_id = l.entity_id
  where l.entity_id = p_entity and (p_from is null or l.period_month >= date_trunc('month', p_from)::date)
    and (p_to is null or l.period_month <= p_to)
  order by l.period_month, f.asset_code, l.created_at
  limit least(greatest(coalesce(p_limit, 500), 1), 5000);
end
$$;

create function public.asset_depreciation_due(p_entity uuid, p_through date default null)
returns table (asset_id uuid, asset_code text, period_month date, amount text, journal_date date, postable boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_through date;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'assets.view') then
    raise exception 'FORBIDDEN: missing assets.view' using errcode = 'insufficient_privilege';
  end if;
  -- Default: everything up to the end of the last complete month.
  v_through := coalesce(p_through, (date_trunc('month', app_private.entity_today(p_entity)) - interval '1 day')::date);
  return query
  select f.id, f.asset_code, l.period_month, l.amount::text, app_private.month_end(l.period_month),
         app_private.period_postable(p_entity, app_private.month_end(l.period_month))
  from public.asset_depreciation_lines l
  join public.fixed_assets f on f.id = l.asset_id and f.entity_id = l.entity_id
  where l.entity_id = p_entity and l.status = 'scheduled' and f.status = 'active'
    and app_private.month_end(l.period_month) <= v_through
  order by l.period_month, f.asset_code;
end
$$;

create function public.asset_pending_lines(p_entity uuid)
returns table (source_type text, line_id uuid, document_id uuid, document_number text, description text, base_amount text,
               posted_account_id uuid, document_date date)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'assets.view') then
    raise exception 'FORBIDDEN: missing assets.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select 'bill_line'::text, l.id, b.id, b.bill_number, l.description, l.base_amount::text, l.posted_account_id, b.bill_date
  from public.bill_lines l join public.bills b on b.id = l.bill_id and b.entity_id = l.entity_id
  where l.entity_id = p_entity and l.asset_link_status = 'pending' and b.status = 'approved'
  union all
  select 'expense_line'::text, l.id, x.id, x.expense_number, l.description, l.base_amount::text, l.posted_account_id, x.expense_date
  from public.expense_lines l join public.expenses x on x.id = l.expense_id and x.entity_id = l.entity_id
  where l.entity_id = p_entity and l.asset_link_status = 'pending' and x.status = 'confirmed'
  order by 8, 4;
end
$$;

-- ------------------------------------------------------------ the fiscal memo schedule
-- Year by year from the fiscal group rule in force on the in-service date. The first year is prorated by the months from
-- the acquisition month; a declining-balance schedule writes the whole remaining value off in the last year of the
-- useful life. Never posted, never compared with the ledger.
create function public.asset_fiscal_schedule(p_asset uuid)
returns table (fiscal_year integer, opening_value text, depreciation text, closing_value text, rule_version integer)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  a public.fixed_assets%rowtype;
  r public.tax_rule_versions%rowtype;
  v_class jsonb;
  v_scale integer;
  v_rate numeric;
  v_life integer;
  v_m0 integer;
  v_y0 integer;
  v_last integer;
  v_nbv numeric;
  v_dep numeric;
  v_f numeric;
  y integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.fixed_assets where id = p_asset;
  if not found or not app_authz.has_permission(a.entity_id, 'assets.view') or not app_authz.has_permission(a.entity_id, 'tax.view') then
    raise exception 'FORBIDDEN: the fiscal schedule needs assets.view and tax.view' using errcode = 'insufficient_privilege';
  end if;
  if a.status in ('draft', 'cancelled') or a.fiscal_class_key is null then
    return;
  end if;
  r := app_private.tax_rule_at('FISCAL_DEP_CLASSES', a.in_service_date);
  if r.id is null then
    return;
  end if;
  v_class := app_private.fiscal_class(a.fiscal_class_key, a.in_service_date);
  if v_class is null or not (v_class ->> 'depreciable')::boolean then
    return;
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(a.entity_id));
  v_life := (v_class ->> 'life_years')::integer;
  v_rate := case when a.fiscal_method = 'declining_balance' and (v_class ->> 'db_rate') is not null
                 then (v_class ->> 'db_rate')::numeric else (v_class ->> 'sl_rate')::numeric end;
  v_m0 := extract(month from a.in_service_date)::integer;
  v_y0 := extract(year from a.in_service_date)::integer;
  v_last := v_y0 + (v_m0 - 1 + v_life * 12 - 1) / 12;
  v_nbv := a.acquisition_cost;
  for y in v_y0..v_last loop
    v_f := case when y = v_y0 then (13 - v_m0)::numeric / 12 else 1 end;
    if y = v_last then
      v_dep := v_nbv;
    elsif a.fiscal_method = 'declining_balance' and (v_class ->> 'db_rate') is not null then
      v_dep := app_private.round_amount(v_nbv * v_rate * v_f, v_scale, 'half_up');
    else
      v_dep := least(v_nbv, app_private.round_amount(a.acquisition_cost * v_rate * v_f, v_scale, 'half_up'));
    end if;
    fiscal_year := y;
    opening_value := v_nbv::text;
    depreciation := v_dep::text;
    closing_value := (v_nbv - v_dep)::text;
    rule_version := r.rule_version;
    return next;
    v_nbv := v_nbv - v_dep;
  end loop;
end
$$;

-- ------------------------------------------------------------ the asset control against the General Ledger
-- Register (registered assets plus purchase lines still waiting for registration) against the fixed-asset accounts and
-- Accumulated Depreciation, as of a date (Step 08 §19: "asset register accounting balances reconcile to GL"). Journals
-- the asset workflow produced are shown apart from the rest (opening balances, closing entries) so an unexplained
-- difference is visible; the comparison itself is the register against the whole ledger balance.
create function app_private.is_asset_journal(p_journal uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.journal_entries j
    where j.id = p_journal
      and (j.source_type in ('bill', 'expense', 'asset_disposal', 'asset_depreciation')
           or exists (select 1 from public.journal_entries o
                      where o.id = j.reverses_journal_id
                        and o.source_type in ('bill', 'expense', 'asset_disposal', 'asset_depreciation'))))
$$;

create function app_private.asset_control(p_entity uuid, p_as_of date default null)
returns table (account_key text, sub_ledger numeric, ledger_workflow numeric, ledger_other numeric, ledger_total numeric)
language plpgsql stable as $$
declare
  v_asof date := coalesce(p_as_of, app_private.entity_today(p_entity));
  v_cost_reg numeric;
  v_cost_pending numeric;
  v_acc_reg numeric;
  v_cost_tot numeric;
  v_cost_wf numeric;
  v_acc_tot numeric;
  v_acc_wf numeric;
begin
  -- Registered cost: assets acquired by the date that were not cancelled (or cancelled later) and not disposed of yet.
  select coalesce(sum(f.acquisition_cost), 0) into v_cost_reg
  from public.fixed_assets f
  where f.entity_id = p_entity and f.acquisition_date <= v_asof and (f.status <> 'cancelled' or f.cancelled_date > v_asof)
    and not app_private.asset_disposed_as_of(f.id, v_asof);
  -- Cost booked by an approved document but not registered (the line is `pending`), unless its asset was cancelled
  -- after the date (then the cancelled asset above still carries it).
  select coalesce(sum(q.base_amount), 0) into v_cost_pending from (
    select l.id, l.base_amount from public.bill_lines l
    join public.bills b on b.id = l.bill_id and b.entity_id = l.entity_id
    where l.entity_id = p_entity and l.asset_link_status = 'pending' and b.status = 'approved' and b.bill_date <= v_asof
      and not exists (select 1 from public.fixed_assets f where f.bill_line_id = l.id and f.status = 'cancelled' and f.cancelled_date > v_asof)
    union all
    select l.id, l.base_amount from public.expense_lines l
    join public.expenses x on x.id = l.expense_id and x.entity_id = l.entity_id
    where l.entity_id = p_entity and l.asset_link_status = 'pending' and x.status = 'confirmed' and x.expense_date <= v_asof
      and not exists (select 1 from public.fixed_assets f where f.expense_line_id = l.id and f.status = 'cancelled' and f.cancelled_date > v_asof)
  ) q;
  select coalesce(sum(app_private.asset_accumulated(f.id, v_asof)), 0) into v_acc_reg
  from public.fixed_assets f
  where f.entity_id = p_entity and f.status in ('active', 'sold', 'disposed') and f.in_service_date <= v_asof
    and not app_private.asset_disposed_as_of(f.id, v_asof);

  select coalesce(sum(l.debit - l.credit), 0),
         coalesce(sum(l.debit - l.credit) filter (where app_private.is_asset_journal(j.id)), 0)
    into v_cost_tot, v_cost_wf
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  where l.entity_id = p_entity and j.status = 'posted' and j.entry_date <= v_asof
    and app_private.is_fixed_asset_account(p_entity, l.ledger_account_id);
  select coalesce(sum(l.credit - l.debit), 0),
         coalesce(sum(l.credit - l.debit) filter (where app_private.is_asset_journal(j.id)), 0)
    into v_acc_tot, v_acc_wf
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = 'ACCUMULATED_DEPRECIATION' and j.status = 'posted' and j.entry_date <= v_asof;

  return query
  select 'FIXED_ASSET_COST'::text, v_cost_reg + v_cost_pending, v_cost_wf, v_cost_tot - v_cost_wf, v_cost_tot
  union all
  select 'ACCUMULATED_DEPRECIATION'::text, v_acc_reg, v_acc_wf, v_acc_tot - v_acc_wf, v_acc_tot;
end
$$;

create function public.asset_control_report(p_entity uuid, p_as_of date default null)
returns table (account_key text, sub_ledger text, ledger_workflow text, ledger_other text, ledger_total text, difference text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'assets.view') or not app_authz.has_permission(p_entity, 'accounting.view') then
    raise exception 'FORBIDDEN: the asset control needs assets.view and accounting.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select c.account_key, c.sub_ledger::text, c.ledger_workflow::text, c.ledger_other::text, c.ledger_total::text,
         (c.sub_ledger - c.ledger_total)::text
  from app_private.asset_control(p_entity, p_as_of) c;
end
$$;

revoke all on function app_private.is_asset_journal(uuid) from public;
revoke all on function app_private.asset_control(uuid, date) from public;

revoke all on function public.asset_load_opening(uuid, text, jsonb) from public, anon;
revoke all on function public.asset_register(uuid, text, date, integer) from public, anon;
revoke all on function public.asset_detail(uuid) from public, anon;
revoke all on function public.asset_depreciation_report(uuid, date, date, integer) from public, anon;
revoke all on function public.asset_depreciation_due(uuid, date) from public, anon;
revoke all on function public.asset_pending_lines(uuid) from public, anon;
revoke all on function public.asset_fiscal_schedule(uuid) from public, anon;
revoke all on function public.asset_control_report(uuid, date) from public, anon;
grant execute on function public.asset_load_opening(uuid, text, jsonb) to authenticated;
grant execute on function public.asset_register(uuid, text, date, integer) to authenticated;
grant execute on function public.asset_detail(uuid) to authenticated;
grant execute on function public.asset_depreciation_report(uuid, date, date, integer) to authenticated;
grant execute on function public.asset_depreciation_due(uuid, date) to authenticated;
grant execute on function public.asset_pending_lines(uuid) to authenticated;
grant execute on function public.asset_fiscal_schedule(uuid) to authenticated;
grant execute on function public.asset_control_report(uuid, date) to authenticated;
