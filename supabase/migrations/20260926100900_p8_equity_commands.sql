-- P8 part 4b (Step 07 §13, Step 04 §6): equity commands and readers.
--
-- Postings                                        Dr                              Cr
--   contribution (company)                        cash / bank                     owner capital / additional equity
--   capital return (company)                      owner capital / additional      cash / bank
--   dividend declaration (company)                retained earnings               dividend payable
--   dividend payment (company)                    dividend payable                cash / bank
--   investment contribution (Personal)            personal investment             cash / bank
--   investment return (Personal)                  cash / bank                     personal investment
--   distribution received (Personal)              cash / bank                     business distribution income
-- Nothing here is revenue or operating expense of the company (Step 01 #20).

create function public.equity_create(
  p_entity uuid, p_key text, p_kind text, p_date date, p_amount text, p_counterparty text, p_contact uuid, p_purpose text,
  p_class text default null, p_resolution text default null, p_related uuid default null, p_basis text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  v_replay uuid;
  v_scale integer;
  v_amount numeric;
  v_class text;
  v_res text := nullif(btrim(coalesce(p_resolution, '')), '');
  v_id uuid := gen_random_uuid();
  v_number text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'equity.manage') then
    raise exception 'FORBIDDEN: recording an equity event needs equity.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('equity.create', p_entity, p_key,
    md5(jsonb_build_object('k', p_kind, 'd', p_date, 'a', p_amount, 'n', p_counterparty, 'c', p_contact, 'p', p_purpose,
                           'cl', p_class, 'r', p_resolution, 're', p_related, 'b', p_basis)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_kind not in ('contribution', 'capital_return', 'dividend', 'investment_contribution', 'investment_return', 'distribution_received')
     or (e.entity_type = 'company') <> (p_kind in ('contribution', 'capital_return', 'dividend')) then
    raise exception 'INVALID: this Entity records contributions, capital returns and dividends (company) or investment contributions, investment returns and distributions received (Personal)'
      using errcode = 'invalid_parameter_value';
  end if;
  if length(btrim(coalesce(p_counterparty, ''))) not between 1 and 200 or length(btrim(coalesce(p_purpose, ''))) not between 3 and 500 then
    raise exception 'INVALID: name the counterparty (up to 200 characters) and the purpose (3 to 500)' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(p_entity) then
    raise exception 'INVALID: an equity event cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_contact is not null and not exists (select 1 from public.contacts where id = p_contact and entity_id = p_entity) then
    raise exception 'INVALID: unknown contact' using errcode = 'invalid_parameter_value';
  end if;
  if p_kind in ('contribution', 'capital_return') then
    v_class := coalesce(nullif(btrim(p_class), ''), 'capital');
    if v_class not in ('capital', 'additional') then
      raise exception 'INVALID: the equity class is capital or additional' using errcode = 'invalid_parameter_value';
    end if;
  elsif p_class is not null then
    raise exception 'INVALID: only a contribution or a capital return has an equity class' using errcode = 'invalid_parameter_value';
  end if;
  if p_kind in ('capital_return', 'dividend') and (v_res is null or length(v_res) not between 3 and 200) then
    raise exception 'INVALID: a capital return or a dividend needs its resolution reference (3 to 200 characters)' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.check_related_entity(p_entity, p_related, p_basis);
  v_scale := app_private.currency_scale(e.base_currency);
  v_amount := app_private.money_arg(p_amount, 'the amount', v_scale);

  perform app_private.ensure_equity_numbering(p_entity);
  v_number := app_private.allocate_document_number(p_entity, 'equity', p_date);
  insert into public.equity_events
    (id, entity_id, event_number, kind, event_date, amount, equity_class, counterparty_name, contact_id, purpose,
     resolution_reference, related_entity_id, relationship_basis, created_by)
  values
    (v_id, p_entity, v_number, p_kind, p_date, v_amount, v_class, btrim(p_counterparty), p_contact, btrim(p_purpose), v_res,
     p_related, nullif(btrim(coalesce(p_basis, '')), ''), auth.uid());
  perform app_private.idem_complete('equity.create', p_entity, p_key, 'equity_events', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ confirm: the posting
create function public.equity_confirm(p_event uuid, p_key text, p_account uuid default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  ev public.equity_events%rowtype;
  fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_eq uuid;
  v_desc text;
  v_lines jsonb;
  v_journal uuid;
  v_available numeric;
  v_dir text;
  v_tax text := 'not_applicable';
  v_cash boolean;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into ev from public.equity_events where id = p_event;
  if not found or not app_authz.has_permission(ev.entity_id, 'equity.manage') then
    raise exception 'FORBIDDEN: confirming an equity event needs equity.manage' using errcode = 'insufficient_privilege';
  end if;
  if ev.kind in ('capital_return', 'dividend') then
    if not app_authz.has_permission(ev.entity_id, 'equity.approve') then
      raise exception 'FORBIDDEN: a capital return or a dividend needs equity.approve' using errcode = 'insufficient_privilege';
    end if;
    if not app_authz.recent_step_up() then
      raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
    end if;
  end if;
  v_replay := app_private.idem_begin('equity.confirm', ev.entity_id, p_key, md5(jsonb_build_object('e', p_event, 'a', p_account)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('equity:' || ev.id::text, 0));
  select * into ev from public.equity_events where id = p_event for update;
  if ev.status <> 'draft' then
    raise exception 'CONFLICT: only a draft equity event can be confirmed (now %)', ev.status using errcode = 'integrity_constraint_violation';
  end if;
  if ev.event_date > app_private.entity_today(ev.entity_id) then
    raise exception 'INVALID: an equity event cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  v_cash := ev.kind <> 'dividend';
  if v_cash then
    fa := app_private.base_cash_account(ev.entity_id, p_account);
  elsif p_account is not null then
    raise exception 'INVALID: a dividend declaration moves no cash; name the account when it is paid' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_maker_checker(ev.entity_id, 'equity', 'confirm', ev.amount, auth.uid(), 'confirm this equity event');

  v_desc := format('%s %s - %s', case ev.kind
      when 'contribution' then 'Capital contribution' when 'capital_return' then 'Capital return'
      when 'dividend' then 'Dividend declared' when 'investment_contribution' then 'Investment contribution'
      when 'investment_return' then 'Investment return' else 'Distribution received' end,
    ev.event_number, left(ev.counterparty_name, 100));
  case ev.kind
    when 'contribution' then
      v_eq := app_private.role_account(ev.entity_id, case ev.equity_class when 'capital' then 'equity_capital' else 'equity_additional' end);
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', fa.ledger_account_id, 'debit', ev.amount, 'credit', 0, 'description', v_desc),
        jsonb_build_object('account_id', v_eq, 'debit', 0, 'credit', ev.amount, 'description', v_desc));
      v_dir := 'in';
    when 'capital_return' then
      v_eq := app_private.role_account(ev.entity_id, case ev.equity_class when 'capital' then 'equity_capital' else 'equity_additional' end);
      if app_private.account_balance(ev.entity_id, v_eq) < ev.amount then
        raise exception 'INVALID: the capital returned exceeds the balance of that equity account' using errcode = 'invalid_parameter_value';
      end if;
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_eq, 'debit', ev.amount, 'credit', 0, 'description', v_desc),
        jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', ev.amount, 'description', v_desc));
      v_dir := 'out';
      v_tax := 'needs_review';
    when 'dividend' then
      v_available := app_private.retained_available(ev.entity_id, ev.event_date);
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', app_private.role_account(ev.entity_id, 'retained_earnings'), 'debit', ev.amount, 'credit', 0, 'description', v_desc),
        jsonb_build_object('account_id', app_private.role_account(ev.entity_id, 'dividend_payable'), 'debit', 0, 'credit', ev.amount, 'description', v_desc));
      v_tax := 'needs_review';
    when 'investment_contribution' then
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', app_private.role_account(ev.entity_id, 'personal_investment'), 'debit', ev.amount, 'credit', 0, 'description', v_desc),
        jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', ev.amount, 'description', v_desc));
      v_dir := 'out';
    when 'investment_return' then
      v_eq := app_private.role_account(ev.entity_id, 'personal_investment');
      if app_private.account_balance(ev.entity_id, v_eq) < ev.amount then
        raise exception 'INVALID: the return exceeds the investment recorded; record a gain as a distribution received' using errcode = 'invalid_parameter_value';
      end if;
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', fa.ledger_account_id, 'debit', ev.amount, 'credit', 0, 'description', v_desc),
        jsonb_build_object('account_id', v_eq, 'debit', 0, 'credit', ev.amount, 'description', v_desc));
      v_dir := 'in';
    else
      v_lines := jsonb_build_array(
        jsonb_build_object('account_id', fa.ledger_account_id, 'debit', ev.amount, 'credit', 0, 'description', v_desc),
        jsonb_build_object('account_id', app_private.role_account(ev.entity_id, 'distribution_income'), 'debit', 0, 'credit', ev.amount, 'description', v_desc));
      v_dir := 'in';
      v_tax := 'needs_review';
  end case;
  if v_cash then
    perform 1 from public.financial_accounts where id = p_account and entity_id = ev.entity_id for no key update;
  end if;
  v_journal := app_private.post_system_journal(ev.entity_id, 'equity_event', ev.id, 'equity.confirm', 'equity.v1', ev.event_date, v_desc, v_lines);
  if v_cash then
    perform app_private.record_movement(ev.entity_id, p_account, v_dir, ev.amount, ev.amount, null, ev.event_date, 'equity_event', ev.id,
                                        'principal', v_journal, v_desc);
  end if;
  update public.equity_events
  set status = 'confirmed', confirmed_at = now(), confirmed_by = auth.uid(), journal_id = v_journal,
      financial_account_id = case when v_cash then p_account end, tax_status = v_tax,
      retained_available = v_available, exceeds_retained_earnings = coalesce(ev.amount > v_available, false)
  where id = ev.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (ev.entity_id, 'EquityEventConfirmed', 'equity_event', ev.id, jsonb_build_object('number', ev.event_number, 'kind', ev.kind));
  perform app_private.idem_complete('equity.confirm', ev.entity_id, p_key, 'journal_entries', v_journal);
  return v_journal;
end
$$;

-- ------------------------------------------------------------ pay a declared dividend (in parts)
create function public.equity_pay_dividend(p_event uuid, p_key text, p_date date, p_account uuid, p_amount text, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  ev public.equity_events%rowtype;
  fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_scale integer;
  v_amount numeric;
  v_outstanding numeric;
  v_last date;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_journal uuid;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into ev from public.equity_events where id = p_event;
  if not found or not app_authz.has_permission(ev.entity_id, 'equity.manage') then
    raise exception 'FORBIDDEN: paying a dividend needs equity.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('equity.pay_dividend', ev.entity_id, p_key,
    md5(jsonb_build_object('e', p_event, 'd', p_date, 'a', p_account, 'm', p_amount, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('equity:' || ev.id::text, 0));
  select * into ev from public.equity_events where id = p_event for update;
  if ev.kind <> 'dividend' or ev.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed dividend can be paid' using errcode = 'integrity_constraint_violation';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(ev.entity_id));
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(ev.entity_id) then
    raise exception 'INVALID: a payment cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  select greatest(ev.event_date, coalesce(max(p.payment_date), ev.event_date), coalesce(max(p.reversed_date), ev.event_date))
    into v_last from public.equity_dividend_payments p where p.event_id = ev.id;
  if p_date < v_last then
    raise exception 'INVALID: the date cannot be before the last activity on this dividend (%)', v_last using errcode = 'invalid_parameter_value';
  end if;
  v_amount := app_private.money_arg(p_amount, 'the amount paid', v_scale);
  v_outstanding := app_private.dividend_outstanding(ev.id);
  if v_amount > v_outstanding then
    raise exception 'INVALID: % of the dividend is unpaid; the payment cannot exceed it', trim_scale(v_outstanding) using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_maker_checker(ev.entity_id, 'equity', 'pay_dividend', v_amount, auth.uid(), 'pay this dividend');
  fa := app_private.base_cash_account(ev.entity_id, p_account);

  perform app_private.ensure_equity_numbering(ev.entity_id);
  v_number := app_private.allocate_document_number(ev.entity_id, 'equity', p_date);
  v_desc := format('Dividend payment %s - %s %s', v_number, ev.event_number, left(ev.counterparty_name, 80));
  perform 1 from public.financial_accounts where id = p_account and entity_id = ev.entity_id for no key update;
  v_journal := app_private.post_system_journal(ev.entity_id, 'dividend_payment', v_id, 'equity.pay_dividend', 'equity.v1', p_date, v_desc,
    jsonb_build_array(
      jsonb_build_object('account_id', app_private.role_account(ev.entity_id, 'dividend_payable'), 'debit', v_amount, 'credit', 0, 'description', v_desc),
      jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', v_amount, 'description', v_desc)));
  perform app_private.record_movement(ev.entity_id, p_account, 'out', v_amount, v_amount, null, p_date, 'dividend_payment', v_id, 'principal', v_journal, v_desc);
  insert into public.equity_dividend_payments
    (id, entity_id, event_id, payment_number, payment_date, amount, financial_account_id, note, journal_id, created_by)
  values (v_id, ev.entity_id, ev.id, v_number, p_date, v_amount, p_account, v_note, v_journal, auth.uid());
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (ev.entity_id, 'DividendPaid', 'equity_event', ev.id, jsonb_build_object('number', ev.event_number, 'payment', v_number));
  perform app_private.idem_complete('equity.pay_dividend', ev.entity_id, p_key, 'equity_dividend_payments', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ reversals
create function public.equity_reverse(p_event uuid, p_key text, p_date date, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  ev public.equity_events%rowtype;
  m public.money_movements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into ev from public.equity_events where id = p_event;
  if not found or not app_authz.has_permission(ev.entity_id, 'equity.manage') then
    raise exception 'FORBIDDEN: reversing an equity event needs equity.manage' using errcode = 'insufficient_privilege';
  end if;
  if ev.kind in ('capital_return', 'dividend') then
    if not app_authz.has_permission(ev.entity_id, 'equity.approve') then
      raise exception 'FORBIDDEN: reversing a capital return or a dividend needs equity.approve' using errcode = 'insufficient_privilege';
    end if;
    if not app_authz.recent_step_up() then
      raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
    end if;
  end if;
  if p_date is null or length(v_reason) not between 5 and 1000 or p_date > app_private.entity_today(ev.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  v_replay := app_private.idem_begin('equity.reverse', ev.entity_id, p_key, md5(jsonb_build_object('e', p_event, 'd', p_date, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('equity:' || ev.id::text, 0));
  select * into ev from public.equity_events where id = p_event for update;
  if ev.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed equity event can be reversed (now %)', ev.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < ev.event_date then
    raise exception 'INVALID: a reversal cannot be dated before the event (%)', ev.event_date using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.equity_dividend_payments p where p.event_id = ev.id and p.status = 'active') then
    raise exception 'CONFLICT: a dividend with payments cannot be reversed; reverse the payments first' using errcode = 'integrity_constraint_violation';
  end if;
  if ev.financial_account_id is not null then
    perform 1 from public.financial_accounts where id = ev.financial_account_id and entity_id = ev.entity_id for no key update;
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(ev.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = ev.entity_id and source_type = 'equity_event' and source_id = ev.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(ev.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'equity_event', ev.id, m.component, v_rev, 'Reversal: ' || v_reason, m.id);
  end loop;
  update public.equity_events
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date, reversed_by = auth.uid(),
      reverse_reason = v_reason
  where id = ev.id;
  perform app_private.idem_complete('equity.reverse', ev.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

create function public.equity_reverse_payment(p_payment uuid, p_key text, p_date date, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p public.equity_dividend_payments%rowtype;
  m public.money_movements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into p from public.equity_dividend_payments where id = p_payment;
  if not found or not app_authz.has_permission(p.entity_id, 'equity.manage') then
    raise exception 'FORBIDDEN: reversing a dividend payment needs equity.manage' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) not between 5 and 1000 or p_date > app_private.entity_today(p.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform pg_advisory_xact_lock(hashtextextended('equity:' || p.event_id::text, 0));
  v_replay := app_private.idem_begin('equity.reverse_payment', p.entity_id, p_key, md5(jsonb_build_object('p', p_payment, 'd', p_date, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into p from public.equity_dividend_payments where id = p_payment for update;
  if p.status <> 'active' then
    raise exception 'CONFLICT: only an active payment can be reversed (now %)', p.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < p.payment_date then
    raise exception 'INVALID: a reversal cannot be dated before the payment' using errcode = 'invalid_parameter_value';
  end if;
  perform 1 from public.financial_accounts where id = p.financial_account_id and entity_id = p.entity_id for no key update;
  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(p.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = p.entity_id and source_type = 'dividend_payment' and source_id = p.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(p.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'dividend_payment', p.id, m.component, v_rev, 'Reversal: ' || v_reason, m.id);
  end loop;
  update public.equity_dividend_payments
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date, reversed_by = auth.uid(),
      reverse_reason = v_reason
  where id = p.id;
  perform app_private.idem_complete('equity.reverse_payment', p.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

create function public.equity_cancel(p_event uuid, p_key text, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  ev public.equity_events%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into ev from public.equity_events where id = p_event;
  if not found or not app_authz.has_permission(ev.entity_id, 'equity.manage') then
    raise exception 'FORBIDDEN: cancelling an equity event needs equity.manage' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a cancellation needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_replay := app_private.idem_begin('equity.cancel', ev.entity_id, p_key, md5(jsonb_build_object('e', p_event, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('equity:' || ev.id::text, 0));
  select * into ev from public.equity_events where id = p_event for update;
  if ev.status <> 'draft' then
    raise exception 'CONFLICT: only a draft equity event can be cancelled; a confirmed one is reversed (now %)', ev.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.equity_events set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = v_reason where id = ev.id;
  perform app_private.idem_complete('equity.cancel', ev.entity_id, p_key, 'equity_events', ev.id);
  return ev.id;
end
$$;

-- ------------------------------------------------------------ readers
create function public.equity_list(p_entity uuid, p_kind text default null, p_status text default null, p_limit integer default 100)
returns table (event_id uuid, event_number text, kind text, status text, event_date date, amount text, counterparty_name text,
               purpose text, equity_class text, resolution_reference text, outstanding text, exceeds_retained_earnings boolean,
               tax_status text, related_entity_id uuid, journal_id uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'equity.view') then
    raise exception 'FORBIDDEN: missing equity.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select e.id, e.event_number, e.kind, e.status, e.event_date, e.amount::text, e.counterparty_name, e.purpose, e.equity_class,
         e.resolution_reference, case when e.kind = 'dividend' then app_private.dividend_outstanding(e.id)::text end,
         e.exceeds_retained_earnings, e.tax_status, e.related_entity_id, e.journal_id
  from public.equity_events e
  where e.entity_id = p_entity and (p_kind is null or e.kind = p_kind) and (p_status is null or e.status = p_status)
  order by e.event_date desc, e.event_number desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end
$$;

create function public.equity_detail(p_event uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.equity_events%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into e from public.equity_events where id = p_event;
  if not found or not app_authz.has_permission(e.entity_id, 'equity.view') then
    raise exception 'FORBIDDEN: missing equity.view' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'id', e.id, 'number', e.event_number, 'kind', e.kind, 'status', e.status, 'date', e.event_date, 'amount', e.amount::text,
    'equity_class', e.equity_class, 'counterparty', e.counterparty_name, 'contact_id', e.contact_id, 'purpose', e.purpose,
    'resolution_reference', e.resolution_reference, 'financial_account_id', e.financial_account_id, 'journal_id', e.journal_id,
    'retained_available', e.retained_available::text, 'exceeds_retained_earnings', e.exceeds_retained_earnings,
    'tax_status', e.tax_status, 'reversal_journal_id', e.reversal_journal_id, 'reverse_reason', e.reverse_reason,
    'cancel_reason', e.cancel_reason, 'related_entity_id', e.related_entity_id, 'relationship_basis', e.relationship_basis,
    'outstanding', case when e.kind = 'dividend' then app_private.dividend_outstanding(e.id)::text end,
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'number', p.payment_number, 'status', p.status, 'date', p.payment_date, 'amount', p.amount::text,
        'financial_account_id', p.financial_account_id, 'tax_status', p.tax_status, 'journal_id', p.journal_id,
        'reversal_journal_id', p.reversal_journal_id, 'note', p.note) order by p.payment_date, p.payment_number)
      from public.equity_dividend_payments p where p.event_id = e.id), '[]'::jsonb));
end
$$;

-- Step 12 §11: contributions, returns and distributions tracked separately.
create function public.equity_summary(p_entity uuid, p_from date, p_to date)
returns table (metric text, events integer, amount text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'equity.view') then
    raise exception 'FORBIDDEN: missing equity.view' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'INVALID: give a period (from, to)' using errcode = 'invalid_parameter_value';
  end if;
  return query
  select m.metric, coalesce(x.n, 0)::integer, coalesce(x.total, 0)::text
  from (values ('contribution'), ('capital_return'), ('dividend'), ('investment_contribution'), ('investment_return'), ('distribution_received')) as m(metric)
  left join lateral (
    select count(*) as n, sum(e.amount) as total from public.equity_events e
    where e.entity_id = p_entity and e.kind = m.metric and e.event_date between p_from and p_to
      and (e.status = 'confirmed' or (e.status = 'reversed' and e.reversed_date > p_to))) x on true
  union all
  select 'dividend_paid', coalesce(y.n, 0)::integer, coalesce(y.total, 0)::text
  from (select count(*) as n, sum(p.amount) as total from public.equity_dividend_payments p
        where p.entity_id = p_entity and p.payment_date between p_from and p_to and (p.status = 'active' or p.reversed_date > p_to)) y
  union all
  select 'dividend_payable', 0, app_private.dividends_payable_total(p_entity, p_to)::text;
end
$$;

revoke all on function public.equity_create(uuid, text, text, date, text, text, uuid, text, text, text, uuid, text) from public, anon;
revoke all on function public.equity_confirm(uuid, text, uuid) from public, anon;
revoke all on function public.equity_pay_dividend(uuid, text, date, uuid, text, text) from public, anon;
revoke all on function public.equity_reverse(uuid, text, date, text) from public, anon;
revoke all on function public.equity_reverse_payment(uuid, text, date, text) from public, anon;
revoke all on function public.equity_cancel(uuid, text, text) from public, anon;
revoke all on function public.equity_list(uuid, text, text, integer) from public, anon;
revoke all on function public.equity_detail(uuid) from public, anon;
revoke all on function public.equity_summary(uuid, date, date) from public, anon;
grant execute on function public.equity_create(uuid, text, text, date, text, text, uuid, text, text, text, uuid, text) to authenticated;
grant execute on function public.equity_confirm(uuid, text, uuid) to authenticated;
grant execute on function public.equity_pay_dividend(uuid, text, date, uuid, text, text) to authenticated;
grant execute on function public.equity_reverse(uuid, text, date, text) to authenticated;
grant execute on function public.equity_reverse_payment(uuid, text, date, text) to authenticated;
grant execute on function public.equity_cancel(uuid, text, text) to authenticated;
grant execute on function public.equity_list(uuid, text, text, integer) to authenticated;
grant execute on function public.equity_detail(uuid) to authenticated;
grant execute on function public.equity_summary(uuid, date, date) to authenticated;
