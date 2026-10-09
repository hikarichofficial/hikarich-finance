-- P49 / decision 376: paying a loan.
--  (a) an ordinary instalment carries interest, so interest no longer needs a note; a fee or penalty needs one only
--      when it is not already on the schedule;
--  (b) loan_pay_installments pays the next N unpaid instalments, the amounts taken from the schedule;
--  (c) loan_prepay pays part of the principal early and recalculates what is left, either shortening the term (the
--      instalment stays) or lowering the instalment (the term stays).

create function app_private.loan_repay_core(
  p_loan uuid, p_key text, p_date date, p_account uuid, p_principal text, p_interest text, p_fee text, p_note text,
  p_prepay boolean)
returns uuid
language plpgsql set search_path = pg_catalog, public as $$
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
  v_sched_fee numeric;
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
  -- Interest is part of an ordinary instalment and needs no note; a fee or penalty needs one unless the schedule itself carries it.
  select coalesce(sum(greatest(i.fee_due - i.paid_fee, 0)), 0) into v_sched_fee from app_private.loan_items(l.id, null, null) i;
  if v_fee > v_sched_fee and v_note is null then
    raise exception 'INVALID: a fee or penalty that is not on the schedule needs a note that explains it' using errcode = 'invalid_parameter_value';
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
  if p_prepay then
    -- A prepayment belongs to no instalment: the schedule is recalculated from the balance that is left.
    insert into public.loan_payment_allocations (entity_id, loan_id, payment_id, item_id, principal, interest, fee)
    values (l.entity_id, l.id, v_id, null, v_principal, 0, 0);
  else
    perform app_private.loan_allocate(l.id, v_id, v_principal, v_interest, v_fee);
  end if;
  if v_principal > 0 and v_principal = v_outstanding then
    update public.loans set status = 'closed', closed_date = p_date where id = l.id;
  end if;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (l.entity_id, 'LoanPaymentRecorded', 'loan', l.id, jsonb_build_object('number', l.loan_number, 'payment', v_number));
  perform app_private.idem_complete('loan.repay', l.entity_id, p_key, 'loan_payments', v_id);
  return v_id;
end
$$;

-- public.loan_repay keeps its signature and now delegates to the core.
create or replace function public.loan_repay(
  p_loan uuid, p_key text, p_date date, p_account uuid, p_principal text, p_interest text default '0',
  p_fee text default '0', p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  return app_private.loan_repay_core(p_loan, p_key, p_date, p_account, p_principal, p_interest, p_fee, p_note, false);
end
$$;

-- ------------------------------------------------------------ pay the next N instalments
create function public.loan_pay_installments(
  p_loan uuid, p_key text, p_date date, p_account uuid, p_count integer, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  it record;
  v_total integer;
  v_replay uuid;
  v_payment uuid;
  v_p numeric := 0;
  v_i numeric := 0;
  v_f numeric := 0;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: recording a loan payment needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if l.status <> 'active' then
    raise exception 'CONFLICT: only an active loan can be repaid (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  -- The amounts come from the schedule as it stands, so the replay of a request is answered from its first outcome.
  v_replay := app_private.idem_begin('loan.pay_installments', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_loan, 'd', p_date, 'a', p_account, 'c', p_count, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: only an active loan can be repaid (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  select count(*) into v_total from app_private.loan_items(l.id, null, null) i where i.state <> 'paid';
  if v_total = 0 then
    raise exception 'INVALID: no instalment is waiting to be paid' using errcode = 'invalid_parameter_value';
  end if;
  if p_count is null or p_count < 1 or p_count > v_total then
    raise exception 'INVALID: choose between 1 and % instalments', v_total using errcode = 'invalid_parameter_value';
  end if;
  for it in
    select * from app_private.loan_items(l.id, null, null) i where i.state <> 'paid' order by i.seq limit p_count
  loop
    v_p := v_p + greatest(it.principal_due - it.paid_principal, 0);
    v_i := v_i + greatest(it.interest_due - it.paid_interest, 0);
    v_f := v_f + greatest(it.fee_due - it.paid_fee, 0);
  end loop;
  v_payment := app_private.loan_repay_core(p_loan, p_key || '#pay', p_date, p_account, v_p::text, v_i::text, v_f::text, p_note, false);
  perform app_private.idem_complete('loan.pay_installments', l.entity_id, p_key, 'loan_payments', v_payment);
  return v_payment;
end
$$;

-- ------------------------------------------------------------ partial early repayment of the principal
create function public.loan_prepay(
  p_loan uuid, p_key text, p_date date, p_account uuid, p_principal text, p_mode text, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.loans%rowtype;
  v public.loan_schedule_versions%rowtype;
  it record;
  r record;
  v_replay uuid;
  v_payment uuid;
  v_scale integer;
  v_amount numeric;
  v_outstanding numeric;
  v_carried numeric := 0;
  v_basis numeric;
  v_n integer := 0;
  v_new_n integer;
  v_first date;
  v_target numeric;
  v_trial numeric;
  v_k integer;
  v_rows jsonb := '[]'::jsonb;
  v_no integer;
  v_today date;
  v_last date;
  v_reason text;
  v_id uuid := gen_random_uuid();
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.loans where id = p_loan;
  if not found or not app_authz.has_permission(l.entity_id, 'loans.manage') then
    raise exception 'FORBIDDEN: recording a loan payment needs loans.manage' using errcode = 'insufficient_privilege';
  end if;
  if p_mode not in ('shorten', 'reduce') then
    raise exception 'INVALID: choose to shorten the term or to lower the instalment' using errcode = 'invalid_parameter_value';
  end if;
  v_replay := app_private.idem_begin('loan.prepay', l.entity_id, p_key,
    md5(jsonb_build_object('l', p_loan, 'd', p_date, 'a', p_account, 'p', p_principal, 'm', p_mode, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('loan:' || l.id::text, 0));
  select * into l from public.loans where id = p_loan for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: only an active loan can be repaid (now %)', l.status using errcode = 'integrity_constraint_violation';
  end if;
  select * into v from public.loan_schedule_versions where loan_id = l.id and status = 'active';
  if v.method = 'manual' then
    raise exception 'INVALID: a manual schedule carries its own amounts; use Restrukturisasi Jadwal to replace it'
      using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(app_private.entity_base_currency(l.entity_id));
  v_amount := app_private.money_arg(p_principal, 'the principal prepaid', v_scale);
  v_outstanding := app_private.loan_outstanding(l.id);
  if v_amount > v_outstanding then
    raise exception 'INVALID: % of principal is outstanding; the principal repaid cannot exceed it', trim_scale(v_outstanding)
      using errcode = 'invalid_parameter_value';
  end if;
  -- The instalment the borrower is used to paying: the first one still ahead, as scheduled before this payment.
  select i.principal_due + i.interest_due into v_target
  from app_private.loan_items(l.id, v.id, null) i
  where i.state in ('scheduled', 'due') and i.due_date >= p_date order by i.seq limit 1;

  v_payment := app_private.loan_repay_core(l.id, p_key || '#pay', p_date, p_account, v_amount::text, '0', '0', p_note, true);
  if v_amount = v_outstanding then
    perform app_private.idem_complete('loan.prepay', l.entity_id, p_key, 'loan_payments', v_payment);
    return v_payment;
  end if;

  -- What is overdue or already part paid stays as it is; the instalments still ahead are recalculated from the balance.
  for it in select * from app_private.loan_items(l.id, v.id, null) order by seq loop
    if it.state = 'paid' then
      continue;
    elsif it.due_date < p_date or it.state = 'partially_paid' then
      v_rows := v_rows || jsonb_build_object('due_date', it.due_date,
        'principal', greatest(it.principal_due - it.paid_principal, 0), 'interest', greatest(it.interest_due - it.paid_interest, 0),
        'fee', greatest(it.fee_due - it.paid_fee, 0));
      v_carried := v_carried + greatest(it.principal_due - it.paid_principal, 0);
    else
      v_n := v_n + 1;
      v_first := least(coalesce(v_first, it.due_date), it.due_date);
    end if;
  end loop;
  v_outstanding := app_private.loan_outstanding(l.id);
  v_basis := v_outstanding - v_carried;
  if v_basis > 0 then
    if v_n = 0 then
      raise exception 'INVALID: no instalment is left to carry the remaining principal' using errcode = 'invalid_parameter_value';
    end if;
    v_new_n := v_n;
    if p_mode = 'shorten' and v.method <> 'interest_only' and v_target is not null then
      -- the fewest instalments that keep the payment at what it was (the last one is smaller)
      for v_k in 1..v_n loop
        select p.principal + p.interest into v_trial
        from app_private.loan_plan(v.method, v_basis, v.rate, v_k, v.step_months, v_first, v_scale, v.rate_steps) p where p.seq = 1;
        if v_trial <= v_target then
          v_new_n := v_k;
          exit;
        end if;
      end loop;
    end if;
    for r in select * from app_private.loan_plan(v.method, v_basis, v.rate, v_new_n, v.step_months, v_first, v_scale, v.rate_steps) loop
      v_rows := v_rows || jsonb_build_object('due_date', r.due_date, 'principal', r.principal, 'interest', r.interest, 'fee', 0);
    end loop;
  end if;

  v_today := app_private.entity_today(l.entity_id);
  v_last := app_private.loan_last_activity(l.id);
  v_reason := case p_mode when 'shorten' then 'Pelunasan dipercepat sebagian: jangka waktu dipersingkat'
                          else 'Pelunasan dipercepat sebagian: cicilan diperkecil' end;
  select coalesce(max(version_no), 0) + 1 into v_no from public.loan_schedule_versions where loan_id = l.id;
  update public.loan_schedule_versions set status = 'superseded', superseded_at = now() where id = v.id;
  perform set_config('app.audit_reason', v_reason, true);
  insert into public.loan_schedule_versions
    (id, entity_id, loan_id, version_no, status, method, rate, installments, step_months, effective_from, principal_basis,
     maturity_date, reason, activated_at, created_by, rate_steps)
  values
    (v_id, l.entity_id, l.id, v_no, 'active', v.method, v.rate, jsonb_array_length(v_rows), v.step_months, greatest(v_today, v_last),
     v_outstanding, (select max((x ->> 'due_date')::date) from jsonb_array_elements(v_rows) x), v_reason, now(), auth.uid(), v.rate_steps);
  insert into public.loan_schedule_items (entity_id, loan_id, version_id, seq, due_date, principal_due, interest_due, fee_due)
  select l.entity_id, l.id, v_id, row_number() over (order by (x.e ->> 'due_date')::date, x.o), (x.e ->> 'due_date')::date,
         (x.e ->> 'principal')::numeric, (x.e ->> 'interest')::numeric, (x.e ->> 'fee')::numeric
  from jsonb_array_elements(v_rows) with ordinality as x(e, o);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (l.entity_id, 'LoanPrepaid', 'loan', l.id,
          jsonb_build_object('number', l.loan_number, 'version', v_no, 'mode', p_mode, 'principal', v_amount::text));
  perform app_private.idem_complete('loan.prepay', l.entity_id, p_key, 'loan_payments', v_payment);
  return v_payment;
end
$$;

revoke all on function app_private.loan_repay_core(uuid, text, date, uuid, text, text, text, text, boolean) from public;
revoke all on function public.loan_pay_installments(uuid, text, date, uuid, integer, text) from public, anon;
revoke all on function public.loan_prepay(uuid, text, date, uuid, text, text, text) from public, anon;
grant execute on function public.loan_pay_installments(uuid, text, date, uuid, integer, text) to authenticated;
grant execute on function public.loan_prepay(uuid, text, date, uuid, text, text, text) to authenticated;
