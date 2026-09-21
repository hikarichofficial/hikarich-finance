-- P8 part 3: the link between a purchase line and the Asset Register (Step 01 #29, Step 08 §11, DECISIONS 79).
--
-- A bill or expense line whose treatment is "asset" is booked to a fixed-asset account when the document is approved.
-- P6/P7 marked it `pending`; from P8 on, approving the document registers the cost as a DRAFT asset in the same
-- transaction and marks the line `linked`. Nothing is posted by the registration itself: the purchase journal already
-- holds the cost. Voiding the document releases the assets it created, unless they already carry depreciation or a
-- disposal - then the asset has to be dealt with first.

-- ------------------------------------------------------------ the lines of an approved document may change their link status only
create or replace function app_private.tg_bill_lines_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
  v_resolved constant text[] := array['posted_account_id', 'base_amount', 'asset_link_status', 'wht_object',
                                       'tax_confirmed_by', 'tax_confirmed_at', 'updated_at', 'updated_by', 'version'];
  v_link constant text[] := array['asset_link_status', 'updated_at', 'updated_by', 'version'];
begin
  select b.status into v_status from public.bills b
  where b.id = coalesce(new.bill_id, old.bill_id) and b.entity_id = coalesce(new.entity_id, old.entity_id)
  for share;
  if v_status = 'draft' then
    null;
  elsif v_status = 'submitted' and tg_op = 'UPDATE'
        and (to_jsonb(new) - v_resolved) is not distinct from (to_jsonb(old) - v_resolved) then
    null;
  -- The Asset Register registers, releases and re-registers the cost of an asset line; nothing else on it changes.
  elsif v_status = 'approved' and tg_op = 'UPDATE' and old.treatment = 'asset'
        and (to_jsonb(new) - v_link) is not distinct from (to_jsonb(old) - v_link) then
    null;
  else
    raise exception 'The lines of a % bill are frozen', coalesce(v_status, 'missing')
      using errcode = 'integrity_constraint_violation';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;

create or replace function app_private.tg_expense_lines_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
  v_resolved constant text[] := array['posted_account_id', 'base_amount', 'asset_link_status', 'wht_object',
                                       'tax_confirmed_by', 'tax_confirmed_at', 'updated_at', 'updated_by', 'version'];
  v_link constant text[] := array['asset_link_status', 'updated_at', 'updated_by', 'version'];
begin
  select x.status into v_status from public.expenses x
  where x.id = coalesce(new.expense_id, old.expense_id) and x.entity_id = coalesce(new.entity_id, old.entity_id)
  for share;
  if v_status = 'draft' then
    null;
  elsif v_status = 'submitted' and tg_op = 'UPDATE'
        and (to_jsonb(new) - v_resolved) is not distinct from (to_jsonb(old) - v_resolved) then
    null;
  elsif v_status = 'confirmed' and tg_op = 'UPDATE' and old.treatment = 'asset'
        and (to_jsonb(new) - v_link) is not distinct from (to_jsonb(old) - v_link) then
    null;
  else
    raise exception 'The lines of a % expense are frozen', coalesce(v_status, 'missing')
      using errcode = 'integrity_constraint_violation';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;

-- ------------------------------------------------------------ the operational history helper
create function app_private.asset_event(p_asset uuid, p_type text, p_date date, p_details jsonb, p_note text default null)
returns void
language plpgsql as $$
begin
  insert into public.asset_events (entity_id, asset_id, event_type, event_date, details, note, created_by)
  select f.entity_id, f.id, p_type, p_date, coalesce(p_details, '{}'::jsonb), left(p_note, 1000), auth.uid()
  from public.fixed_assets f where f.id = p_asset;
end
$$;

-- ------------------------------------------------------------ registering a purchase line as a draft asset
create function app_private.asset_register_line(p_kind text, p_line uuid) returns uuid
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
begin
  if p_kind = 'bill_line' then
    select l.entity_id, l.description, b.bill_date, l.posted_account_id, l.base_amount, b.bill_number
      into v_entity, v_desc, v_date, v_account, v_cost, v_doc
    from public.bill_lines l join public.bills b on b.id = l.bill_id and b.entity_id = l.entity_id
    where l.id = p_line and l.treatment = 'asset';
  else
    select l.entity_id, l.description, x.expense_date, l.posted_account_id, l.base_amount, x.expense_number
      into v_entity, v_desc, v_date, v_account, v_cost, v_doc
    from public.expense_lines l join public.expenses x on x.id = l.expense_id and x.entity_id = l.entity_id
    where l.id = p_line and l.treatment = 'asset';
  end if;
  if v_entity is null then
    raise exception 'INVALID: unknown asset line' using errcode = 'invalid_parameter_value';
  end if;
  if v_account is null or coalesce(v_cost, 0) <= 0 then
    raise exception 'INVALID: an asset line needs a booked account and a positive cost' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.ensure_asset_numbering(v_entity);
  v_code := app_private.allocate_document_number(v_entity, 'asset', v_date);
  insert into public.fixed_assets
    (id, entity_id, asset_code, name, source_type, bill_line_id, expense_line_id, cost_account_id, acquisition_date,
     acquisition_cost, created_by)
  values
    (v_id, v_entity, v_code, left(btrim(v_desc), 200), p_kind,
     case p_kind when 'bill_line' then p_line end, case p_kind when 'expense_line' then p_line end,
     v_account, v_date, v_cost, auth.uid());
  perform app_private.asset_event(v_id, 'registered', v_date,
    jsonb_build_object('source', p_kind, 'line', p_line, 'document', v_doc, 'cost', v_cost::text));
  if p_kind = 'bill_line' then
    update public.bill_lines set asset_link_status = 'linked' where id = p_line;
  else
    update public.expense_lines set asset_link_status = 'linked' where id = p_line;
  end if;
  return v_id;
end
$$;

-- Approving a document sets its asset lines to `pending`; the register takes them over in the same transaction. A
-- line that goes back to `pending` later (its asset was cancelled) is re-registered by hand, never automatically.
create function app_private.tg_asset_line_register() returns trigger
language plpgsql as $$
declare
  v_status text;
begin
  if tg_argv[0] = 'bill_line' then
    select b.status into v_status from public.bills b where b.id = new.bill_id and b.entity_id = new.entity_id;
  else
    select x.status into v_status from public.expenses x where x.id = new.expense_id and x.entity_id = new.entity_id;
  end if;
  if v_status in ('draft', 'submitted') then
    perform app_private.asset_register_line(tg_argv[0], new.id);
  end if;
  return null;
end
$$;
create trigger tg_asset_register after update of asset_link_status on public.bill_lines
  for each row when (new.asset_link_status = 'pending' and old.asset_link_status is distinct from 'pending')
  execute function app_private.tg_asset_line_register('bill_line');
create trigger tg_asset_register after update of asset_link_status on public.expense_lines
  for each row when (new.asset_link_status = 'pending' and old.asset_link_status is distinct from 'pending')
  execute function app_private.tg_asset_line_register('expense_line');

-- ------------------------------------------------------------ releasing the assets of a voided document
create function app_private.assets_release_source(p_kind text, p_doc uuid, p_date date, p_reason text) returns void
language plpgsql as $$
declare
  a public.fixed_assets%rowtype;
begin
  for a in
    select f.* from public.fixed_assets f
    where f.status <> 'cancelled'
      and ((p_kind = 'bill' and f.bill_line_id in (select l.id from public.bill_lines l where l.bill_id = p_doc))
           or (p_kind = 'expense' and f.expense_line_id in (select l.id from public.expense_lines l where l.expense_id = p_doc)))
    order by f.asset_code
    for update
  loop
    if a.status in ('sold', 'disposed')
       or exists (select 1 from public.asset_depreciation_lines d where d.asset_id = a.id and d.status = 'posted') then
      raise exception 'CONFLICT: asset % of this document already carries depreciation or a disposal; deal with the asset first',
        a.asset_code using errcode = 'integrity_constraint_violation';
    end if;
    update public.asset_depreciation_lines set status = 'cancelled', cancelled_at = now()
    where asset_id = a.id and status = 'scheduled';
    update public.fixed_assets
    set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancelled_date = p_date,
        cancel_reason = left('The source document was voided: ' || p_reason, 1000)
    where id = a.id;
    perform app_private.asset_event(a.id, 'cancelled', p_date, jsonb_build_object('why', 'source document voided'), p_reason);
  end loop;
  if p_kind = 'bill' then
    update public.bill_lines set asset_link_status = 'none' where bill_id = p_doc and asset_link_status <> 'none';
  else
    update public.expense_lines set asset_link_status = 'none' where expense_id = p_doc and asset_link_status <> 'none';
  end if;
end
$$;

-- The void paths of P6/P7 with the release in place of the P6 refusal.
create or replace function app_private.close_bill_core(
  p_bill uuid, p_target text, p_reason text, p_date date, p_replacement uuid default null)
returns void
language plpgsql as $$
declare
  b public.bills%rowtype;
  v_today date;
  v_date date;
  v_rev uuid;
  v_n bigint;
  v_min date;
begin
  select * into b from public.bills where id = p_bill;
  v_today := app_private.entity_today(b.entity_id);
  v_date := coalesce(p_date, v_today);
  perform set_config('app.audit_reason', p_reason, true);

  if b.status in ('draft', 'submitted') then
    if p_target <> 'cancelled' then
      raise exception 'INVALID: a bill that is not approved is cancelled, not voided' using errcode = 'invalid_parameter_value';
    end if;
    update public.bills
    set status = 'cancelled', closed_at = now(), closed_by = auth.uid(), closed_date = v_today, closed_reason = p_reason,
        replaced_by_bill_id = p_replacement
    where id = b.id;
    return;
  end if;

  if b.status <> 'approved' then
    raise exception 'CONFLICT: the bill is already %', b.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_target <> 'void' then
    raise exception 'INVALID: an approved bill is voided, not cancelled' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(v_date);
  if v_date > v_today then
    raise exception 'INVALID: the date cannot be in the future' using errcode = 'invalid_parameter_value';
  end if;
  select count(*) into v_n from public.vendor_payment_allocations a where a.bill_id = b.id and a.status = 'active';
  if v_n > 0 then
    raise exception 'CONFLICT: this bill has % active payment allocation(s); reverse those payments first', v_n
      using errcode = 'integrity_constraint_violation';
  end if;
  -- Assets registered from this bill are released with it, unless they already carry depreciation or a disposal.
  perform app_private.assets_release_source('bill', b.id, v_date, p_reason);
  -- Voiding is dated after every payment and reversal on the bill, so the payable never goes negative on any day
  -- in between (the sub-ledger and the ledger agree as of every date).
  select greatest(b.bill_date, coalesce(max(a.allocation_date), b.bill_date), coalesce(max(a.reversed_date), b.bill_date))
    into v_min from public.vendor_payment_allocations a where a.bill_id = b.id;
  if v_date < v_min then
    raise exception 'INVALID: the date cannot be before the last payment activity on this bill (%)', v_min
      using errcode = 'invalid_parameter_value';
  end if;

  v_rev := app_private.reverse_journal_core(b.journal_id, v_date, p_reason);
  perform app_private.tax_reverse_source('bill', b.id, v_rev, v_date, p_reason);
  update public.bills
  set status = 'void', reversal_journal_id = v_rev, closed_at = now(), closed_by = auth.uid(), closed_date = v_date,
      closed_reason = p_reason, replaced_by_bill_id = p_replacement
  where id = b.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (b.entity_id, 'BillVoided', 'bill', b.id, jsonb_build_object('bill_number', b.bill_number));
end
$$;

create or replace function app_private.close_expense_core(
  p_expense uuid, p_target text, p_reason text, p_date date, p_replacement uuid default null)
returns void
language plpgsql as $$
declare
  x public.expenses%rowtype;
  m public.money_movements%rowtype;
  v_today date;
  v_date date;
  v_rev uuid;
begin
  select * into x from public.expenses where id = p_expense;
  v_today := app_private.entity_today(x.entity_id);
  v_date := coalesce(p_date, v_today);
  perform set_config('app.audit_reason', p_reason, true);

  if x.status in ('draft', 'submitted') then
    if p_target <> 'cancelled' then
      raise exception 'INVALID: an expense that is not confirmed is cancelled, not reversed' using errcode = 'invalid_parameter_value';
    end if;
    update public.expenses
    set status = 'cancelled', closed_at = now(), closed_by = auth.uid(), closed_date = v_today, closed_reason = p_reason,
        replaced_by_expense_id = p_replacement
    where id = x.id;
    return;
  end if;

  if x.status <> 'confirmed' then
    raise exception 'CONFLICT: the expense is already %', x.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_target <> 'reversed' then
    raise exception 'INVALID: a confirmed expense is reversed, not cancelled' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(v_date);
  if v_date > v_today then
    raise exception 'INVALID: the date cannot be in the future' using errcode = 'invalid_parameter_value';
  end if;
  if v_date < x.expense_date then
    raise exception 'INVALID: a reversal cannot be dated before the expense' using errcode = 'invalid_parameter_value';
  end if;
  -- Assets registered from this expense are released with it, unless they already carry depreciation or a disposal.
  perform app_private.assets_release_source('expense', x.id, v_date, p_reason);
  perform 1 from public.financial_accounts where id = x.financial_account_id and entity_id = x.entity_id for no key update;

  v_rev := app_private.reverse_journal_core(x.journal_id, v_date, p_reason);
  perform app_private.tax_reverse_source('expense', x.id, v_rev, v_date, p_reason);
  for m in
    select * from public.money_movements
    where entity_id = x.entity_id and source_type = 'expense' and source_id = x.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(
      x.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, v_date, 'expense', x.id, m.component, v_rev,
      'Reversal: ' || p_reason, m.id);
  end loop;
  update public.expenses
  set status = 'reversed', reversal_journal_id = v_rev, closed_at = now(), closed_by = auth.uid(), closed_date = v_date,
      closed_reason = p_reason, replaced_by_expense_id = p_replacement
  where id = x.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (x.entity_id, 'ExpenseReversed', 'expense', x.id, jsonb_build_object('expense_number', x.expense_number));
end
$$;

-- ------------------------------------------------------------ registering the assets that were already pending
do $$
declare
  r record;
begin
  for r in select 'bill_line'::text as k, l.id from public.bill_lines l where l.asset_link_status = 'pending' loop
    perform app_private.asset_register_line(r.k, r.id);
  end loop;
  for r in select 'expense_line'::text as k, l.id from public.expense_lines l where l.asset_link_status = 'pending' loop
    perform app_private.asset_register_line(r.k, r.id);
  end loop;
end
$$;

revoke all on function app_private.tg_bill_lines_guard() from public;
revoke all on function app_private.tg_expense_lines_guard() from public;
revoke all on function app_private.asset_event(uuid, text, date, jsonb, text) from public;
revoke all on function app_private.asset_register_line(text, uuid) from public;
revoke all on function app_private.tg_asset_line_register() from public;
revoke all on function app_private.assets_release_source(text, uuid, date, text) from public;
revoke all on function app_private.close_bill_core(uuid, text, text, date, uuid) from public;
revoke all on function app_private.close_expense_core(uuid, text, text, date, uuid) from public;
