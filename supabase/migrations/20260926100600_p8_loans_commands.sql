-- P8 part 3b (Step 07 §12, Step 08 §12, Step 04 §6): loan commands - create, activate (proceeds), repay with
-- allocation, write off, reverse, restructure, cancel, asset link and the opening loader.
--
-- Postings (Step 04 §6)                          Dr                                   Cr
--   proceeds, borrowed                           cash / bank                          loan liability
--   proceeds, lent                               other receivable                     cash / bank
--   repayment, borrowed                          liability (principal), interest      cash / bank
--                                                expense, other expense (fee)
--   repayment, lent                              cash / bank                          other receivable (principal),
--                                                                                     interest income, other income (fee)
--   write-off, borrowed (forgiven)               liability                            other income
--   write-off, lent (bad debt)                   bad debt expense                     other receivable
-- Principal is never revenue or expense; interest and fees are separate lines.

-- ------------------------------------------------------------ schedule rows and versions
-- The rows of one schedule version: generated from a method, or read from a manual list. The principal always adds up
-- to the basis exactly (Step 08 §12 "schedule totals reconcile to the configured principal").
create function app_private.loan_schedule_rows(
  p_method text, p_basis numeric, p_rate numeric, p_n integer, p_step integer, p_first date, p_items jsonb,
  p_scale integer, p_min_date date)
returns table (seq integer, due_date date, principal numeric, interest numeric, fee numeric)
language plpgsql stable as $$
declare
  v_item jsonb;
  v_n integer := 0;
  v_date date;
  v_prev date;
  v_p numeric;
  v_i numeric;
  v_f numeric;
  v_sum numeric := 0;
  r record;
begin
  if p_method = 'manual' then
    if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 600 then
      raise exception 'INVALID: a manual schedule lists 1 to 600 installments' using errcode = 'invalid_parameter_value';
    end if;
    for v_item in select * from jsonb_array_elements(p_items) loop
      if jsonb_typeof(v_item) <> 'object' then
        raise exception 'INVALID: every installment is an object with a due date and amounts' using errcode = 'invalid_parameter_value';
      end if;
      begin
        v_date := (v_item ->> 'due_date')::date;
      exception when others then
        raise exception 'INVALID: an installment has an unreadable due date' using errcode = 'invalid_parameter_value';
      end;
      if v_date is null or v_date < p_min_date or (v_prev is not null and v_date < v_prev) then
        raise exception 'INVALID: installments are dated in order, none before %', p_min_date using errcode = 'invalid_parameter_value';
      end if;
      v_p := app_private.money_arg(coalesce(v_item ->> 'principal', '0'), 'the installment principal', p_scale, true);
      v_i := app_private.money_arg(coalesce(v_item ->> 'interest', '0'), 'the installment interest', p_scale, true);
      v_f := app_private.money_arg(coalesce(v_item ->> 'fee', '0'), 'the installment fee', p_scale, true);
      if v_p + v_i + v_f = 0 then
        raise exception 'INVALID: an installment needs an amount' using errcode = 'invalid_parameter_value';
      end if;
      v_n := v_n + 1;
      v_sum := v_sum + v_p;
      v_prev := v_date;
      seq := v_n;
      due_date := v_date;
      principal := v_p;
      interest := v_i;
      fee := v_f;
      return next;
    end loop;
    if v_sum <> p_basis then
      raise exception 'INVALID: the installments schedule % of principal, not the % to be scheduled', trim_scale(v_sum), trim_scale(p_basis)
        using errcode = 'invalid_parameter_value';
    end if;
    return;
  end if;
  if p_first is null or p_first < p_min_date then
    raise exception 'INVALID: the first installment cannot fall before %', p_min_date using errcode = 'invalid_parameter_value';
  end if;
  if p_method = 'interest_only' and p_rate = 0 then
    raise exception 'INVALID: an interest-only schedule needs a rate' using errcode = 'invalid_parameter_value';
  end if;
  for r in select * from app_private.loan_plan(p_method, p_basis, p_rate, p_n, p_step, p_first, p_scale) loop
    if r.principal + r.interest = 0 then
      raise exception 'INVALID: this rate and term leave an installment without an amount; change the term or use a manual schedule'
        using errcode = 'invalid_parameter_value';
    end if;
    seq := r.seq;
    due_date := r.due_date;
    principal := r.principal;
    interest := r.interest;
    fee := 0;
    return next;
  end loop;
end
$$;

-- Writes a schedule version and its items. A draft version has no effective date yet; an active one (a restructuring,
-- an opening loan) takes it now.
create function app_private.loan_write_version(
  p_loan uuid, p_version_no integer, p_status text, p_method text, p_rate numeric, p_n integer, p_step integer,
  p_first date, p_items jsonb, p_basis numeric, p_effective date, p_min_date date, p_reason text)
returns uuid
language plpgsql as $$
declare
  l public.loans%rowtype;
  v_scale integer;
  v_id uuid := gen_random_uuid();
  v_count integer;
  v_last date;
  v_rows jsonb;
begin
  select * into l from public.loans where id = p_loan;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(l.entity_id));
  select jsonb_agg(to_jsonb(r) order by r.seq), count(*), max(r.due_date) into v_rows, v_count, v_last
  from app_private.loan_schedule_rows(p_method, p_basis, p_rate, p_n, p_step, p_first, p_items, v_scale, p_min_date) r;
  insert into public.loan_schedule_versions
    (id, entity_id, loan_id, version_no, status, method, rate, installments, step_months, effective_from, principal_basis,
     maturity_date, reason, activated_at, created_by)
  values
    (v_id, l.entity_id, l.id, p_version_no, p_status, p_method, p_rate, v_count, case when p_method = 'manual' then null else p_step end,
     case when p_status = 'active' then p_effective end, p_basis, v_last, nullif(btrim(coalesce(p_reason, '')), ''),
     case when p_status = 'active' then now() end, auth.uid());
  insert into public.loan_schedule_items (entity_id, loan_id, version_id, seq, due_date, principal_due, interest_due, fee_due)
  select l.entity_id, l.id, v_id, t.seq, t.due_date, t.principal, t.interest, t.fee
  from jsonb_to_recordset(v_rows) as t(seq integer, due_date date, principal numeric, interest numeric, fee numeric)
  order by t.seq;
  return v_id;
end
$$;

-- ------------------------------------------------------------ allocation of a payment to the schedule
-- Arrears first: each part (principal, interest, fee) fills the earliest items of the version in force that still
-- owe it. What is left beyond the schedule is kept against no item.
create function app_private.loan_allocate(p_loan uuid, p_payment uuid, p_principal numeric, p_interest numeric, p_fee numeric)
returns void
language plpgsql as $$
declare
  l public.loans%rowtype;
  r record;
  v_p numeric := p_principal;
  v_i numeric := p_interest;
  v_f numeric := p_fee;
  a_p numeric;
  a_i numeric;
  a_f numeric;
begin
  select * into l from public.loans where id = p_loan;
  for r in select * from app_private.loan_items(p_loan, null, null) order by seq loop
    a_p := least(v_p, greatest(r.principal_due - r.paid_principal, 0));
    a_i := least(v_i, greatest(r.interest_due - r.paid_interest, 0));
    a_f := least(v_f, greatest(r.fee_due - r.paid_fee, 0));
    if a_p + a_i + a_f > 0 then
      insert into public.loan_payment_allocations (entity_id, loan_id, payment_id, item_id, principal, interest, fee)
      values (l.entity_id, l.id, p_payment, r.item_id, a_p, a_i, a_f);
      v_p := v_p - a_p;
      v_i := v_i - a_i;
      v_f := v_f - a_f;
    end if;
    exit when v_p + v_i + v_f = 0;
  end loop;
  if v_p + v_i + v_f > 0 then
    insert into public.loan_payment_allocations (entity_id, loan_id, payment_id, item_id, principal, interest, fee)
    values (l.entity_id, l.id, p_payment, null, v_p, v_i, v_f);
  end if;
end
$$;

-- The last day the loan's payments and reversals touched: new activity is dated on or after it, so the outstanding
-- principal is right on every day.
create function app_private.loan_last_activity(p_loan uuid) returns date
language sql stable as $$
  select greatest(l.effective_date,
                  coalesce((select max(p.payment_date) from public.loan_payments p where p.loan_id = l.id), l.effective_date),
                  coalesce((select max(p.reversed_date) from public.loan_payments p where p.loan_id = l.id), l.effective_date),
                  coalesce((select v.effective_from from public.loan_schedule_versions v where v.loan_id = l.id and v.status = 'active'), l.effective_date))
  from public.loans l where l.id = p_loan
$$;

-- ------------------------------------------------------------ create (draft)
create function public.loan_create(
  p_entity uuid, p_key text, p_direction text, p_counterparty text, p_contact uuid, p_purpose text, p_principal text,
  p_agreement date, p_term_class text, p_rate text, p_method text, p_installments integer, p_step_months integer,
  p_first_due date, p_items jsonb default null, p_asset uuid default null, p_related uuid default null,
  p_basis text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  v_replay uuid;
  v_scale integer;
  v_principal numeric;
  v_rate numeric;
  v_account uuid;
  v_term text;
  v_id uuid := gen_random_uuid();
  v_number text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'loans.manage') then
    raise exception 'FORBIDDEN: recording a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('loan.create', p_entity, p_key,
    md5(jsonb_build_object('dir', p_direction, 'n', p_counterparty, 'c', p_contact, 'p', p_purpose, 'a', p_principal,
                           'ag', p_agreement, 't', p_term_class, 'r', p_rate, 'm', p_method, 'i', p_installments,
                           's', p_step_months, 'f', p_first_due, 'it', p_items, 'as', p_asset, 're', p_related,
                           'b', p_basis)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(e.base_currency);
  if p_direction not in ('borrowed', 'lent') then
    raise exception 'INVALID: a loan is borrowed or lent' using errcode = 'invalid_parameter_value';
  end if;
  if length(btrim(coalesce(p_counterparty, ''))) not between 1 and 200 or length(btrim(coalesce(p_purpose, ''))) not between 3 and 500 then
    raise exception 'INVALID: name the counterparty (up to 200 characters) and the purpose (3 to 500)' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_agreement);
  if p_agreement > app_private.entity_today(p_entity) then
    raise exception 'INVALID: the agreement cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_contact is not null and not exists (select 1 from public.contacts where id = p_contact and entity_id = p_entity) then
    raise exception 'INVALID: unknown contact' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.check_related_entity(p_entity, p_related, p_basis);
  v_principal := app_private.money_arg(p_principal, 'the principal', v_scale);
  v_rate := app_private.rate_arg(coalesce(nullif(btrim(p_rate), ''), '0'), 'the annual interest rate');
  if p_method not in ('annuity', 'flat', 'interest_only', 'manual') then
    raise exception 'INVALID: the schedule method is annuity, flat, interest_only or manual' using errcode = 'invalid_parameter_value';
  end if;
  if p_method <> 'manual' and (p_installments is null or p_installments not between 1 and 600 or p_step_months is null
                               or p_step_months not in (1, 3, 6, 12) or p_first_due is null) then
    raise exception 'INVALID: a generated schedule needs the installments (1 to 600), a step of 1, 3, 6 or 12 months and the first due date'
      using errcode = 'invalid_parameter_value';
  end if;
  -- Which ledger account carries the balance.
  if p_direction = 'lent' then
    if p_term_class is not null then
      raise exception 'INVALID: a loan given has no short or long term class' using errcode = 'invalid_parameter_value';
    end if;
    v_account := app_private.role_account(p_entity, 'other_receivable');
  else
    if e.entity_type = 'company' and (p_term_class is null or p_term_class not in ('short', 'long')) then
      raise exception 'INVALID: a loan received is short-term or long-term' using errcode = 'invalid_parameter_value';
    end if;
    v_term := case when e.entity_type = 'company' then p_term_class end;
    v_account := app_private.role_account(p_entity, case when v_term = 'long' then 'loan_long_term' else 'loan_short_term' end);
  end if;
  if p_asset is not null then
    if p_direction <> 'borrowed' then
      raise exception 'INVALID: only a loan received can finance an asset' using errcode = 'invalid_parameter_value';
    end if;
    if not exists (select 1 from public.fixed_assets where id = p_asset and entity_id = p_entity and status <> 'cancelled') then
      raise exception 'INVALID: unknown or cancelled asset' using errcode = 'invalid_parameter_value';
    end if;
  end if;

  perform app_private.ensure_loan_numbering(p_entity);
  v_number := app_private.allocate_document_number(p_entity, 'loan', p_agreement);
  insert into public.loans
    (id, entity_id, loan_number, direction, status, counterparty_name, contact_id, purpose, principal, source_type,
     agreement_date, principal_account_id, term_class, asset_id, related_entity_id, relationship_basis, created_by)
  values
    (v_id, p_entity, v_number, p_direction, 'draft', btrim(p_counterparty), p_contact, btrim(p_purpose), v_principal, 'proceeds',
     p_agreement, v_account, v_term, p_asset, p_related, nullif(btrim(coalesce(p_basis, '')), ''), auth.uid());
  perform app_private.loan_write_version(v_id, 1, 'draft', p_method, v_rate, p_installments, p_step_months, p_first_due,
                                         p_items, v_principal, null, p_agreement, null);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_entity, 'LoanDrafted', 'loan', v_id, jsonb_build_object('number', v_number, 'direction', p_direction));
  perform app_private.idem_complete('loan.create', p_entity, p_key, 'loans', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ activate: the proceeds
create function public.loan_activate(p_loan uuid, p_key text, p_date date, p_account uuid)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_desc text;
  v_lines jsonb;
  v_journal uuid;
  v_first date;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: activating a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('loan.activate', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_loan, 'd', p_date, 'a', p_account)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'draft' then
    raise exception 'CONFLICT: only a draft loan can be activated (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(l.entity_id) then
    raise exception 'INVALID: the proceeds cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_date < l.agreement_date then
    raise exception 'INVALID: the proceeds cannot be dated before the agreement (%)', l.agreement_date using errcode = 'invalid_parameter_value';
  end if;
  select min(i.due_date) into v_first from public.loan_schedule_items i
  join public.loan_schedule_versions v on v.id = i.version_id and v.loan_id = l.id and v.status = 'draft';
  if v_first < p_date then
    raise exception 'INVALID: the first installment (%) falls before the proceeds date', v_first using errcode = 'invalid_parameter_value';
  end if;
  fa := app_private.base_cash_account(l.entity_id, p_account);
  perform app_private.assert_maker_checker(l.entity_id, 'loans', 'activate', l.principal, auth.uid(), 'activate this loan');

  v_desc := format('Loan %s %s - %s', case l.direction when 'borrowed' then 'received' else 'given' end, l.loan_number,
                   left(l.counterparty_name, 100));
  if l.direction = 'borrowed' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', fa.ledger_account_id, 'debit', l.principal, 'credit', 0, 'description', v_desc),
      jsonb_build_object('account_id', l.principal_account_id, 'debit', 0, 'credit', l.principal, 'description', v_desc));
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', l.principal_account_id, 'debit', l.principal, 'credit', 0, 'description', v_desc),
      jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', l.principal, 'description', v_desc));
  end if;
  perform 1 from public.financial_accounts where id = p_account and entity_id = l.entity_id for no key update;
  v_journal := app_private.post_system_journal(l.entity_id, 'loan', l.id, 'loan.proceeds', 'loan.v1', p_date, v_desc, v_lines);
  perform app_private.record_movement(l.entity_id, p_account, case l.direction when 'borrowed' then 'in' else 'out' end,
    l.principal, l.principal, null, p_date, 'loan', l.id, 'principal', v_journal, v_desc);
  update public.loans
  set status = 'active', effective_date = p_date, funded_principal = l.principal, financial_account_id = p_account,
      proceeds_journal_id = v_journal
  where id = l.id;
  update public.loan_schedule_versions
  set status = 'active', effective_from = p_date, activated_at = now()
  where loan_id = l.id and status = 'draft';
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (l.entity_id, 'LoanActivated', 'loan', l.id, jsonb_build_object('number', l.loan_number));
  perform app_private.idem_complete('loan.activate', l.entity_id, p_key, 'journal_entries', v_journal);
  return v_journal;
end
$$;

-- ------------------------------------------------------------ repay (principal, interest, fee)
create function public.loan_repay(
  p_loan uuid, p_key text, p_date date, p_account uuid, p_principal text, p_interest text default '0',
  p_fee text default '0', p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_scale integer;
  v_principal numeric;
  v_interest numeric;
  v_fee numeric;
  v_total numeric;
  v_outstanding numeric;
  v_last date;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_version uuid;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: recording a loan payment needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('loan.repay', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_loan, 'd', p_date, 'a', p_account, 'p', p_principal, 'i', p_interest, 'f', p_fee, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: only an active loan can be repaid (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(l.entity_id));
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(l.entity_id) then
    raise exception 'INVALID: a payment cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  v_last := app_private.loan_last_activity(l.id);
  if p_date < v_last then
    raise exception 'INVALID: the date cannot be before the last activity on this loan (%)', v_last using errcode = 'invalid_parameter_value';
  end if;
  v_principal := app_private.money_arg(coalesce(nullif(btrim(p_principal), ''), '0'), 'the principal repaid', v_scale, true);
  v_interest := app_private.money_arg(coalesce(nullif(btrim(p_interest), ''), '0'), 'the interest', v_scale, true);
  v_fee := app_private.money_arg(coalesce(nullif(btrim(p_fee), ''), '0'), 'the fee', v_scale, true);
  v_total := v_principal + v_interest + v_fee;
  if v_total = 0 then
    raise exception 'INVALID: a payment needs an amount' using errcode = 'invalid_parameter_value';
  end if;
  v_outstanding := app_private.loan_outstanding(l.id);
  if v_principal > v_outstanding then
    raise exception 'INVALID: % of principal is outstanding; the principal repaid cannot exceed it', trim_scale(v_outstanding)
      using errcode = 'invalid_parameter_value';
  end if;
  if (v_interest > 0 or v_fee > 0) and v_note is null then
    raise exception 'INVALID: interest or a fee needs a note that explains it' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_maker_checker(l.entity_id, 'loans', 'repay', v_total, auth.uid(), 'record this loan payment');
  fa := app_private.base_cash_account(l.entity_id, p_account);

  perform app_private.ensure_loan_numbering(l.entity_id);
  v_number := app_private.allocate_document_number(l.entity_id, 'loan_payment', p_date);
  v_desc := format('Loan payment %s - %s %s', v_number, l.loan_number, left(l.counterparty_name, 80));
  if l.direction = 'borrowed' then
    if v_principal > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', l.principal_account_id, 'debit', v_principal, 'credit', 0, 'description', v_desc);
    end if;
    if v_interest > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(l.entity_id, 'interest_expense'),
                                               'debit', v_interest, 'credit', 0, 'description', 'Interest: ' || v_desc);
    end if;
    if v_fee > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(l.entity_id, 'other_expense'),
                                               'debit', v_fee, 'credit', 0, 'description', 'Fee: ' || v_desc);
    end if;
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', v_total, 'description', v_desc);
  else
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', v_total, 'credit', 0, 'description', v_desc);
    if v_principal > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', l.principal_account_id, 'debit', 0, 'credit', v_principal, 'description', v_desc);
    end if;
    if v_interest > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(l.entity_id, 'interest_income'),
                                               'debit', 0, 'credit', v_interest, 'description', 'Interest: ' || v_desc);
    end if;
    if v_fee > 0 then
      v_lines := v_lines || jsonb_build_object('account_id', app_private.role_account(l.entity_id, 'other_income'),
                                               'debit', 0, 'credit', v_fee, 'description', 'Fee: ' || v_desc);
    end if;
  end if;
  perform 1 from public.financial_accounts where id = p_account and entity_id = l.entity_id for no key update;
  v_journal := app_private.post_system_journal(l.entity_id, 'loan_payment', v_id, 'loan.repay', 'loan.v1', p_date, v_desc, v_lines);
  perform app_private.record_movement(l.entity_id, p_account, case l.direction when 'borrowed' then 'out' else 'in' end,
    v_total, v_total, null, p_date, 'loan_payment', v_id, 'principal', v_journal, v_desc);
  select v.id into v_version from public.loan_schedule_versions v where v.loan_id = l.id and v.status = 'active';
  insert into public.loan_payments
    (id, entity_id, loan_id, payment_number, kind, payment_date, principal, interest, fee, financial_account_id,
     schedule_version_id, note, tax_status, journal_id, created_by)
  values
    (v_id, l.entity_id, l.id, v_number, 'repayment', p_date, v_principal, v_interest, v_fee, p_account, v_version, v_note,
     case when v_interest > 0 then 'needs_review' else 'not_applicable' end, v_journal, auth.uid());
  perform app_private.loan_allocate(l.id, v_id, v_principal, v_interest, v_fee);
  if v_principal > 0 and v_principal = v_outstanding then
    update public.loans set status = 'closed', closed_date = p_date where id = l.id;
  end if;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (l.entity_id, 'LoanPaymentRecorded', 'loan', l.id, jsonb_build_object('number', l.loan_number, 'payment', v_number));
  perform app_private.idem_complete('loan.repay', l.entity_id, p_key, 'loan_payments', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ write off (forgiven debt, bad debt)
create function public.loan_write_off(p_loan uuid, p_key text, p_date date, p_amount text, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  v_replay uuid;
  v_scale integer;
  v_amount numeric;
  v_outstanding numeric;
  v_last date;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_lines jsonb;
  v_journal uuid;
  v_version uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: writing off a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a write-off needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_replay := app_private.idem_begin('loan.write_off', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_loan, 'd', p_date, 'a', p_amount, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: only an active loan can be written off (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(l.entity_id));
  perform app_private.assert_business_date(p_date);
  if p_date > app_private.entity_today(l.entity_id) then
    raise exception 'INVALID: the write-off cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  v_last := app_private.loan_last_activity(l.id);
  if p_date < v_last then
    raise exception 'INVALID: the date cannot be before the last activity on this loan (%)', v_last using errcode = 'invalid_parameter_value';
  end if;
  v_amount := app_private.money_arg(p_amount, 'the amount written off', v_scale);
  v_outstanding := app_private.loan_outstanding(l.id);
  if v_amount > v_outstanding then
    raise exception 'INVALID: % is outstanding; the write-off cannot exceed it', trim_scale(v_outstanding) using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_maker_checker(l.entity_id, 'loans', 'write_off', v_amount, auth.uid(), 'write this off');

  perform app_private.ensure_loan_numbering(l.entity_id);
  v_number := app_private.allocate_document_number(l.entity_id, 'loan_payment', p_date);
  v_desc := format('Loan write-off %s - %s %s', v_number, l.loan_number, left(l.counterparty_name, 80));
  if l.direction = 'borrowed' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', l.principal_account_id, 'debit', v_amount, 'credit', 0, 'description', v_desc),
      jsonb_build_object('account_id', app_private.role_account(l.entity_id, 'other_income'), 'debit', 0, 'credit', v_amount, 'description', v_desc));
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('account_id', app_private.role_account(l.entity_id, 'bad_debt'), 'debit', v_amount, 'credit', 0, 'description', v_desc),
      jsonb_build_object('account_id', l.principal_account_id, 'debit', 0, 'credit', v_amount, 'description', v_desc));
  end if;
  v_journal := app_private.post_system_journal(l.entity_id, 'loan_payment', v_id, 'loan.write_off', 'loan.v1', p_date, v_desc, v_lines);
  perform set_config('app.audit_reason', v_reason, true);
  select v.id into v_version from public.loan_schedule_versions v where v.loan_id = l.id and v.status = 'active';
  insert into public.loan_payments
    (id, entity_id, loan_id, payment_number, kind, payment_date, principal, schedule_version_id, note, tax_status, journal_id, created_by)
  values
    (v_id, l.entity_id, l.id, v_number, 'write_off', p_date, v_amount, v_version, v_reason, 'needs_review', v_journal, auth.uid());
  perform app_private.loan_allocate(l.id, v_id, v_amount, 0, 0);
  if v_amount = v_outstanding then
    update public.loans set status = 'closed', closed_date = p_date where id = l.id;
  end if;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (l.entity_id, 'LoanWrittenOff', 'loan', l.id, jsonb_build_object('number', l.loan_number, 'payment', v_number));
  perform app_private.idem_complete('loan.write_off', l.entity_id, p_key, 'loan_payments', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ reverse a payment
create function app_private.loan_reverse_payment_core(p_payment uuid, p_date date, p_reason text) returns uuid
language plpgsql as $$
declare
  p public.loan_payments%rowtype;
  l public.loans%rowtype;
  m public.money_movements%rowtype;
  v_rev uuid;
begin
  select * into p from public.loan_payments where id = p_payment for update;
  select * into l from public.loans where id = p.loan_id for update;
  if p.status <> 'active' then
    raise exception 'CONFLICT: only an active payment can be reversed (now %)', p.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < p.payment_date then
    raise exception 'INVALID: a reversal cannot be dated before the payment' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.loan_schedule_versions v where v.id = p.schedule_version_id and v.status = 'active') then
    raise exception 'CONFLICT: this payment belongs to a schedule that was restructured; it is part of the history now'
      using errcode = 'integrity_constraint_violation';
  end if;
  if p.financial_account_id is not null then
    perform 1 from public.financial_accounts where id = p.financial_account_id and entity_id = p.entity_id for no key update;
  end if;
  perform set_config('app.audit_reason', p_reason, true);
  v_rev := app_private.reverse_journal_core(p.journal_id, p_date, p_reason);
  for m in
    select * from public.money_movements
    where entity_id = p.entity_id and source_type = 'loan_payment' and source_id = p.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(p.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'loan_payment', p.id, m.component, v_rev, 'Reversal: ' || p_reason, m.id);
  end loop;
  update public.loan_payments
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date,
      reversed_by = auth.uid(), reverse_reason = p_reason
  where id = p.id;
  if l.status = 'closed' then
    update public.loans set status = 'active', closed_date = null where id = l.id;
  end if;
  return v_rev;
end
$$;

create function public.loan_reverse_payment(p_payment uuid, p_key text, p_date date, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p public.loan_payments%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into p from public.loan_payments where id = p_payment;
  if not found or not app_authz.has_permission(p.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: reversing a loan payment needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) not between 5 and 1000 or p_date > app_private.entity_today(p.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of 5 to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform pg_advisory_xact_lock(hashtextextended('loan:' || p.loan_id::text, 0));
  v_replay := app_private.idem_begin('loan.reverse_payment', p.entity_id, p_key,
    md5(jsonb_build_object('p', p_payment, 'd', p_date, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p.kind = 'write_off' and not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.loan_reverse_payment_core(p_payment, p_date, v_reason);
  perform app_private.idem_complete('loan.reverse_payment', p.entity_id, p_key, 'journal_entries', v_replay);
  return v_replay;
end
$$;

-- ------------------------------------------------------------ restructure: a new schedule version
create function public.loan_restructure(
  p_loan uuid, p_key text, p_effective date, p_rate text, p_method text, p_installments integer, p_step_months integer,
  p_first_due date, p_items jsonb, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  v_replay uuid;
  v_rate numeric;
  v_outstanding numeric;
  v_last date;
  v_no integer;
  v_id uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: restructuring a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a restructuring needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_replay := app_private.idem_begin('loan.restructure', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_loan, 'e', p_effective, 'r', p_rate, 'm', p_method, 'n', p_installments, 's', p_step_months,
                           'f', p_first_due, 'i', p_items, 'why', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: only an active loan can be restructured (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(p_effective);
  if p_effective > app_private.entity_today(l.entity_id) then
    raise exception 'INVALID: a restructuring cannot take effect in the future' using errcode = 'invalid_parameter_value';
  end if;
  v_last := app_private.loan_last_activity(l.id);
  if p_effective < v_last then
    raise exception 'INVALID: the restructuring cannot take effect before the last activity on this loan (%)', v_last
      using errcode = 'invalid_parameter_value';
  end if;
  if p_method not in ('annuity', 'flat', 'interest_only', 'manual') then
    raise exception 'INVALID: the schedule method is annuity, flat, interest_only or manual' using errcode = 'invalid_parameter_value';
  end if;
  if p_method <> 'manual' and (p_installments is null or p_installments not between 1 and 600 or p_step_months is null
                               or p_step_months not in (1, 3, 6, 12) or p_first_due is null) then
    raise exception 'INVALID: a generated schedule needs the installments (1 to 600), a step of 1, 3, 6 or 12 months and the first due date'
      using errcode = 'invalid_parameter_value';
  end if;
  v_rate := app_private.rate_arg(coalesce(nullif(btrim(p_rate), ''), '0'), 'the annual interest rate');
  v_outstanding := app_private.loan_outstanding(l.id);
  select coalesce(max(version_no), 0) + 1 into v_no from public.loan_schedule_versions where loan_id = l.id;
  update public.loan_schedule_versions set status = 'superseded', superseded_at = now() where loan_id = l.id and status = 'active';
  perform set_config('app.audit_reason', v_reason, true);
  v_id := app_private.loan_write_version(l.id, v_no, 'active', p_method, v_rate, p_installments, p_step_months, p_first_due,
                                         p_items, v_outstanding, p_effective, p_effective, v_reason);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (l.entity_id, 'LoanRestructured', 'loan', l.id, jsonb_build_object('number', l.loan_number, 'version', v_no));
  perform app_private.idem_complete('loan.restructure', l.entity_id, p_key, 'loan_schedule_versions', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ cancel a draft, link an asset
create function public.loan_cancel(p_loan uuid, p_key text, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  v_replay uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: cancelling a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a cancellation needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_replay := app_private.idem_begin('loan.cancel', l.entity_id, p_key, md5(jsonb_build_object('l', p_loan, 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'draft' then
    raise exception 'CONFLICT: only a draft loan can be cancelled; an active loan is repaid or written off (now %)', l.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.loans set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = v_reason where id = l.id;
  perform app_private.idem_complete('loan.cancel', l.entity_id, p_key, 'loans', l.id);
  return l.id;
end
$$;

create function public.loan_set_asset(p_loan uuid, p_asset uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: linking an asset to a loan needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if l.status = 'cancelled' or l.direction <> 'borrowed' then
    raise exception 'INVALID: only a loan received, and not a cancelled one, can be linked to an asset' using errcode = 'invalid_parameter_value';
  end if;
  if p_asset is not null and not exists (select 1 from public.fixed_assets where id = p_asset and entity_id = l.entity_id and status <> 'cancelled') then
    raise exception 'INVALID: unknown or cancelled asset' using errcode = 'invalid_parameter_value';
  end if;
  update public.loans set asset_id = p_asset where id = l.id;
end
$$;

-- ------------------------------------------------------------ opening loans (data cut-over)
-- Loans that existed before the system: the outstanding principal at the cut-over date and the schedule that
-- continues from it. No journal is posted here - the opening balances are posted by the opening balance batch and the
-- control compares the two.
create function public.loan_load_opening(p_entity uuid, p_key text, p_loans jsonb) returns uuid[]
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  v_replay uuid;
  v_scale integer;
  v_today date;
  v_item jsonb;
  v_ids uuid[] := array[]::uuid[];
  v_id uuid;
  v_direction text;
  v_term text;
  v_outstanding numeric;
  v_original numeric;
  v_cut date;
  v_agree date;
  v_first date;
  v_step integer;
  v_n integer;
  v_method text;
  v_rate numeric;
  v_account uuid;
  v_number text;
  v_asset uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'system.import') then
    raise exception 'FORBIDDEN: loading opening loans needs system.import' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('loan.load_opening', p_entity, p_key, md5(coalesce(p_loans::text, '')));
  if v_replay is not null then
    return (select array_agg(l.id order by l.loan_number) from public.loans l
            where l.entity_id = p_entity and l.source_type = 'opening'
              and l.created_at = (select x.created_at from public.loans x where x.id = v_replay));
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_typeof(p_loans) <> 'array' or jsonb_array_length(p_loans) not between 1 and 200 then
    raise exception 'INVALID: give 1 to 200 loans' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(e.base_currency);
  v_today := app_private.entity_today(p_entity);
  perform app_private.ensure_loan_numbering(p_entity);
  for v_item in select * from jsonb_array_elements(p_loans) loop
    if jsonb_typeof(v_item) <> 'object' or length(btrim(coalesce(v_item ->> 'counterparty', ''))) not between 1 and 200 then
      raise exception 'INVALID: every loan needs a counterparty of up to 200 characters' using errcode = 'invalid_parameter_value';
    end if;
    v_direction := v_item ->> 'direction';
    if v_direction not in ('borrowed', 'lent') then
      raise exception 'INVALID: the direction of % is borrowed or lent', v_item ->> 'counterparty' using errcode = 'invalid_parameter_value';
    end if;
    begin
      v_cut := (v_item ->> 'cutover_date')::date;
      v_agree := (v_item ->> 'agreement_date')::date;
      v_first := (v_item ->> 'first_due')::date;
      v_step := coalesce((v_item ->> 'step_months')::integer, 1);
      v_n := (v_item ->> 'installments')::integer;
      v_asset := (v_item ->> 'asset')::uuid;
    exception when others then
      raise exception 'INVALID: a loan has an unreadable date, count or asset' using errcode = 'invalid_parameter_value';
    end;
    if v_cut is null or v_agree is null or v_agree > v_cut or v_cut > v_today then
      raise exception 'INVALID: % needs agreement <= cut-over <= today', v_item ->> 'counterparty' using errcode = 'invalid_parameter_value';
    end if;
    perform app_private.assert_business_date(v_agree);
    v_outstanding := app_private.money_arg(v_item ->> 'outstanding', 'the outstanding principal', v_scale);
    v_original := app_private.money_arg(coalesce(v_item ->> 'principal', v_item ->> 'outstanding'), 'the original principal', v_scale);
    if v_original < v_outstanding then
      raise exception 'INVALID: the outstanding principal of % exceeds the original', v_item ->> 'counterparty' using errcode = 'invalid_parameter_value';
    end if;
    v_method := coalesce(v_item ->> 'method', 'manual');
    v_rate := app_private.rate_arg(coalesce(nullif(btrim(v_item ->> 'rate'), ''), '0'), 'the annual interest rate');
    if v_method not in ('annuity', 'flat', 'interest_only', 'manual') then
      raise exception 'INVALID: the schedule method of % is unknown', v_item ->> 'counterparty' using errcode = 'invalid_parameter_value';
    end if;
    if v_direction = 'lent' then
      v_term := null;
      v_account := app_private.role_account(p_entity, 'other_receivable');
    else
      v_term := case when e.entity_type = 'company' then v_item ->> 'term_class' end;
      if e.entity_type = 'company' and (v_term is null or v_term not in ('short', 'long')) then
        raise exception 'INVALID: the loan of % is short-term or long-term', v_item ->> 'counterparty' using errcode = 'invalid_parameter_value';
      end if;
      v_account := app_private.role_account(p_entity, case when v_term = 'long' then 'loan_long_term' else 'loan_short_term' end);
    end if;
    if v_asset is not null and (v_direction <> 'borrowed'
       or not exists (select 1 from public.fixed_assets where id = v_asset and entity_id = p_entity and status <> 'cancelled')) then
      raise exception 'INVALID: the asset of % is unknown or the loan is not a loan received', v_item ->> 'counterparty'
        using errcode = 'invalid_parameter_value';
    end if;
    v_id := gen_random_uuid();
    v_number := app_private.allocate_document_number(p_entity, 'loan', v_cut);
    insert into public.loans
      (id, entity_id, loan_number, direction, status, counterparty_name, purpose, principal, funded_principal, source_type,
       agreement_date, effective_date, principal_account_id, term_class, asset_id, created_by)
    values
      (v_id, p_entity, v_number, v_direction, 'active', btrim(v_item ->> 'counterparty'),
       coalesce(nullif(btrim(coalesce(v_item ->> 'purpose', '')), ''), 'Opening balance'), v_original, v_outstanding, 'opening',
       v_agree, v_cut, v_account, v_term, v_asset, auth.uid());
    perform app_private.loan_write_version(v_id, 1, 'active', v_method, v_rate, v_n, v_step, v_first, v_item -> 'items',
                                           v_outstanding, v_cut, v_cut, 'Loaded at the cut-over');
    v_ids := v_ids || v_id;
  end loop;
  perform app_private.idem_complete('loan.load_opening', p_entity, p_key, 'loans', v_ids[1]);
  return v_ids;
end
$$;

revoke all on function app_private.loan_schedule_rows(text, numeric, numeric, integer, integer, date, jsonb, integer, date) from public;
revoke all on function app_private.loan_write_version(uuid, integer, text, text, numeric, integer, integer, date, jsonb, numeric, date, date, text) from public;
revoke all on function app_private.loan_allocate(uuid, uuid, numeric, numeric, numeric) from public;
revoke all on function app_private.loan_last_activity(uuid) from public;
revoke all on function app_private.loan_reverse_payment_core(uuid, date, text) from public;

revoke all on function public.loan_create(uuid, text, text, text, uuid, text, text, date, text, text, text, integer, integer, date, jsonb, uuid, uuid, text) from public, anon;
revoke all on function public.loan_activate(uuid, text, date, uuid) from public, anon;
revoke all on function public.loan_repay(uuid, text, date, uuid, text, text, text, text) from public, anon;
revoke all on function public.loan_write_off(uuid, text, date, text, text) from public, anon;
revoke all on function public.loan_reverse_payment(uuid, text, date, text) from public, anon;
revoke all on function public.loan_restructure(uuid, text, date, text, text, integer, integer, date, jsonb, text) from public, anon;
revoke all on function public.loan_cancel(uuid, text, text) from public, anon;
revoke all on function public.loan_set_asset(uuid, uuid) from public, anon;
revoke all on function public.loan_load_opening(uuid, text, jsonb) from public, anon;
grant execute on function public.loan_create(uuid, text, text, text, uuid, text, text, date, text, text, text, integer, integer, date, jsonb, uuid, uuid, text) to authenticated;
grant execute on function public.loan_activate(uuid, text, date, uuid) to authenticated;
grant execute on function public.loan_repay(uuid, text, date, uuid, text, text, text, text) to authenticated;
grant execute on function public.loan_write_off(uuid, text, date, text, text) to authenticated;
grant execute on function public.loan_reverse_payment(uuid, text, date, text) to authenticated;
grant execute on function public.loan_restructure(uuid, text, date, text, text, integer, integer, date, jsonb, text) to authenticated;
grant execute on function public.loan_cancel(uuid, text, text) to authenticated;
grant execute on function public.loan_set_asset(uuid, uuid) to authenticated;
grant execute on function public.loan_load_opening(uuid, text, jsonb) to authenticated;
