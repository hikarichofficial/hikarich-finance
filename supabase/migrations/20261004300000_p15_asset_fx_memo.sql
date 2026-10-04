-- P15: the fixed-asset half of the OWNER's foreign-currency confirmation (2026-10-04, see docs/DECISIONS.md,
-- the "Open items for later phases" bullet and decision 281 for the loans half that shipped first).
--
-- "Hanya catat & tampilkan dalam mata uang asal" (only record & display in the original currency): a fixed asset
-- registered from a foreign-currency purchase line, or loaded as an opening asset with its original figures given,
-- carries a memo of what it cost in that currency and at what rate -- historical-rate only, no revaluation, no
-- posting. `acquisition_cost` stays exactly what it always was (base currency, Step 08's own figure); the memo is
-- purely additional, read-only information set once at registration and never touched again, unlike the Loan FX
-- revaluation of decision 281, which has an ongoing monthly workflow because a loan balance still moves.

-- ------------------------------------------------------------ the memo columns
alter table public.fixed_assets
  add column fx_currency public.currency_code,
  add column fx_cost public.money_amount,
  add column fx_rate public.fx_rate;
alter table public.fixed_assets add constraint fixed_asset_fx_shape check (
  (fx_currency is null and fx_cost is null and fx_rate is null)
  or (fx_currency is not null and fx_cost is not null and fx_cost > 0 and fx_rate is not null));

-- The FX memo is a registration-time fact: it follows exactly the same "locked once the asset leaves draft" rule
-- the acquisition cost and date already follow (Step 08 lets a draft be corrected; nothing after that).
create or replace function app_private.tg_fixed_assets_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.status not in ('draft', 'active') then
      raise exception 'An asset starts as a draft or (opening) active' using errcode = 'integrity_constraint_violation';
    end if;
    if new.status = 'active' and new.source_type <> 'opening' then
      raise exception 'Only an opening asset is created active' using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;
  if (new.entity_id, new.asset_code, new.source_type, new.bill_line_id, new.expense_line_id, new.cost_account_id,
      new.split_from_asset_id, new.created_at, new.created_by)
     is distinct from
     (old.entity_id, old.asset_code, old.source_type, old.bill_line_id, old.expense_line_id, old.cost_account_id,
      old.split_from_asset_id, old.created_at, old.created_by) then
    raise exception 'The identity of an asset (code, source, cost account) cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  if old.status = 'cancelled' then
    raise exception 'A cancelled asset cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status
     and (old.status, new.status) not in
         (('draft', 'active'), ('draft', 'cancelled'), ('active', 'cancelled'), ('active', 'sold'),
          ('active', 'disposed'), ('sold', 'active'), ('disposed', 'active')) then
    raise exception 'An asset cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  -- Cost and acquisition facts (the FX memo included) are fixed once the asset leaves the draft.
  if old.status <> 'draft'
     and (new.acquisition_cost, new.acquisition_date, new.opening_accumulated, new.opening_cutover, new.fx_currency,
          new.fx_cost, new.fx_rate)
         is distinct from
         (old.acquisition_cost, old.acquisition_date, old.opening_accumulated, old.opening_cutover, old.fx_currency,
          old.fx_cost, old.fx_rate) then
    raise exception 'The cost of an asset that has left the draft cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  if old.status in ('sold', 'disposed') and new.status = old.status
     and (new.in_service_date, new.depreciation_method, new.useful_life_months, new.residual_value)
         is distinct from (old.in_service_date, old.depreciation_method, old.useful_life_months, old.residual_value) then
    raise exception 'A sold or disposed asset keeps its depreciation facts' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;

-- ------------------------------------------------------------ registering a purchase line as a draft asset: capture
-- the originating document's own currency and rate, when it was a foreign-currency bill or expense.
create or replace function app_private.asset_register_line(p_kind text, p_line uuid) returns uuid
language plpgsql as $$
declare
  v_entity uuid;
  v_desc text;
  v_date date;
  v_account uuid;
  v_cost numeric;
  v_doc text;
  v_id uuid := gen_random_uuid();
  v_code text;
  v_doc_currency public.currency_code;
  v_doc_rate public.fx_rate;
  v_doc_amount numeric;
  v_base public.currency_code;
  v_fx_currency public.currency_code;
  v_fx_cost numeric;
  v_fx_rate numeric;
begin
  if p_kind = 'bill_line' then
    select l.entity_id, l.description, b.bill_date, l.posted_account_id, l.base_amount, b.bill_number,
           b.currency, b.exchange_rate, l.line_total
      into v_entity, v_desc, v_date, v_account, v_cost, v_doc, v_doc_currency, v_doc_rate, v_doc_amount
    from public.bill_lines l join public.bills b on b.id = l.bill_id and b.entity_id = l.entity_id
    where l.id = p_line and l.treatment = 'asset';
  else
    select l.entity_id, l.description, x.expense_date, l.posted_account_id, l.base_amount, x.expense_number,
           x.currency, x.exchange_rate, l.line_total
      into v_entity, v_desc, v_date, v_account, v_cost, v_doc, v_doc_currency, v_doc_rate, v_doc_amount
    from public.expense_lines l join public.expenses x on x.id = l.expense_id and x.entity_id = l.entity_id
    where l.id = p_line and l.treatment = 'asset';
  end if;
  if v_entity is null then
    raise exception 'INVALID: unknown asset line' using errcode = 'invalid_parameter_value';
  end if;
  if v_account is null or coalesce(v_cost, 0) <= 0 then
    raise exception 'INVALID: an asset line needs a booked account and a positive cost' using errcode = 'invalid_parameter_value';
  end if;
  v_base := app_private.entity_base_currency(v_entity);
  if v_doc_currency is not null and v_doc_currency <> v_base then
    v_fx_currency := v_doc_currency;
    v_fx_cost := v_doc_amount;
    v_fx_rate := v_doc_rate;
  end if;
  perform app_private.ensure_asset_numbering(v_entity);
  v_code := app_private.allocate_document_number(v_entity, 'asset', v_date);
  insert into public.fixed_assets
    (id, entity_id, asset_code, name, source_type, bill_line_id, expense_line_id, cost_account_id, acquisition_date,
     acquisition_cost, fx_currency, fx_cost, fx_rate, created_by)
  values
    (v_id, v_entity, v_code, left(btrim(v_desc), 200), p_kind,
     case p_kind when 'bill_line' then p_line end, case p_kind when 'expense_line' then p_line end,
     v_account, v_date, v_cost, v_fx_currency, v_fx_cost, v_fx_rate, auth.uid());
  perform app_private.asset_event(v_id, 'registered', v_date,
    jsonb_build_object('source', p_kind, 'line', p_line, 'document', v_doc, 'cost', v_cost::text,
      'fx_currency', v_fx_currency, 'fx_cost', v_fx_cost::text, 'fx_rate', v_fx_rate::text));
  if p_kind = 'bill_line' then
    update public.bill_lines set asset_link_status = 'linked' where id = p_line;
  else
    update public.expense_lines set asset_link_status = 'linked' where id = p_line;
  end if;
  return v_id;
end
$$;

-- ------------------------------------------------------------ opening assets: the memo must be given explicitly,
-- since an opening asset has no originating foreign-currency document to read it from.
create or replace function public.asset_load_opening(p_entity uuid, p_key text, p_assets jsonb) returns uuid[]
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
  v_fx_currency public.currency_code;
  v_fx_cost numeric;
  v_fx_rate numeric;
  v_fx_scale integer;
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
    -- Optional FX memo: the original currency, cost and rate this asset was actually bought in (historical only).
    v_fx_currency := nullif(upper(btrim(coalesce(v_item ->> 'fx_currency', ''))), '');
    v_fx_cost := null;
    v_fx_rate := null;
    if v_fx_currency is not null then
      if v_fx_currency = e.base_currency then
        raise exception 'INVALID: the FX memo currency of % must differ from the base currency', v_item ->> 'name'
          using errcode = 'invalid_parameter_value';
      end if;
      if not exists (select 1 from public.currencies where code = v_fx_currency and is_active) then
        raise exception 'INVALID: the FX memo currency of % is unknown', v_item ->> 'name' using errcode = 'invalid_parameter_value';
      end if;
      v_fx_rate := (v_item ->> 'fx_rate')::numeric;
      if v_fx_rate is null or not app_private.is_finite(v_fx_rate) or v_fx_rate <= 0 or v_fx_rate >= 10::numeric ^ 10
         or app_private.round_amount(v_fx_rate, 10, 'down') <> v_fx_rate then
        raise exception 'INVALID: the FX memo rate of % must be a positive number with at most 10 decimals', v_item ->> 'name'
          using errcode = 'invalid_parameter_value';
      end if;
      v_fx_scale := app_private.currency_scale(v_fx_currency);
      v_fx_cost := app_private.money_arg(v_item ->> 'fx_cost', format('the FX memo cost of %s', v_item ->> 'name'), v_fx_scale);
      -- The same mistyped-rate sanity guard every FX feature in this codebase uses (transfers, decision 281 loans):
      -- the memo cost converted at the memo rate must land within 20% of the base cost already given.
      if abs(app_private.round_amount(v_fx_cost * v_fx_rate, v_scale, 'half_up') - v_cost) > 0.20 * v_cost then
        raise exception 'INVALID: the FX memo of % does not convert anywhere near its base cost -- check the rate', v_item ->> 'name'
          using errcode = 'invalid_parameter_value';
      end if;
    end if;
    v_id := gen_random_uuid();
    v_code := app_private.allocate_document_number(p_entity, 'asset', v_acq);
    insert into public.fixed_assets
      (id, entity_id, asset_code, name, description, serial_number, status, location, custodian, source_type, cost_account_id,
       acquisition_date, acquisition_cost, in_service_date, depreciation_method, useful_life_months, residual_value,
       opening_accumulated, opening_cutover, plan_version, fiscal_class_key, fiscal_method, fx_currency, fx_cost, fx_rate,
       activated_at, activated_by, created_by)
    values
      (v_id, p_entity, v_code, btrim(v_item ->> 'name'), nullif(btrim(coalesce(v_item ->> 'description', '')), ''),
       nullif(btrim(coalesce(v_item ->> 'serial_number', '')), ''), 'active',
       nullif(btrim(coalesce(v_item ->> 'location', '')), ''), nullif(btrim(coalesce(v_item ->> 'custodian', '')), ''),
       'opening', v_account, v_acq, v_cost, v_svc, v_method, v_life, v_residual, v_accum, v_cut, 1, v_fclass, v_fmethod,
       v_fx_currency, v_fx_cost, v_fx_rate, now(), auth.uid(), auth.uid());
    v_n := app_private.asset_generate_schedule(v_id);
    perform app_private.asset_event(v_id, 'opening_loaded', v_cut,
      jsonb_build_object('cost', v_cost::text, 'accumulated', v_accum::text, 'lines', v_n,
        'fx_currency', v_fx_currency, 'fx_cost', v_fx_cost::text, 'fx_rate', v_fx_rate::text));
    v_ids := v_ids || v_id;
  end loop;
  perform app_private.idem_complete('asset.load_opening', p_entity, p_key, 'fixed_assets', v_ids[1]);
  return v_ids;
end
$$;

-- ------------------------------------------------------------ surfacing the memo on the asset detail
create or replace function public.asset_detail(p_asset uuid) returns jsonb
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
      'fx_currency', a.fx_currency, 'fx_cost', a.fx_cost::text, 'fx_rate', a.fx_rate::text,
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
