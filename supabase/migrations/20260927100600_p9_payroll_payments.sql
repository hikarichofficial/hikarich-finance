-- P9 part 7: paying payroll (Step 04 §8, Step 06 §8, Step 08 §13, Step 16 §18).
--   * Net pay: Dr Payroll Liabilities, Cr the paying account, per employee line, in part or in full. It never books
--     salary expense again ("no second salary expense") and can never exceed what is still owed on the line.
--   * BPJS: Dr BPJS Liabilities, Cr the paying account, against the BPJS liability of the run.
--   * PPh 21 is paid with the tax payment of P7 (tax type 'wht_pph21'), which reduces the same tax ledger.
-- A payroll payment is a high-impact event: it needs payroll.pay and payroll.compensation_view, a recent step-up, and the
-- maker-checker rule of the Entity (Step 06 §7-§8). A payment is reversed, never edited.

create function public.payroll_record_payment(
  p_run uuid, p_key text, p_kind text, p_date date, p_account uuid, p_amount text default null, p_lines jsonb default null,
  p_reference text default null, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  fa public.financial_accounts%rowtype;
  l public.payroll_run_lines%rowtype;
  x jsonb;
  v_replay uuid;
  v_id uuid := gen_random_uuid();
  v_today date;
  v_scale integer;
  v_total numeric := 0;
  v_amt numeric;
  v_number text;
  v_desc text;
  v_journal uuid;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_parts jsonb := '[]'::jsonb;
  v_seen uuid[] := '{}';
  v_out numeric;
begin
  r := app_private.payroll_run_for(p_run, 'payroll.pay', 'paying payroll', true);
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('payroll.pay', r.entity_id, p_key,
    md5(jsonb_build_object('r', p_run, 'k', p_kind, 'd', p_date, 'a', p_account, 'amt', p_amount, 'l', p_lines, 'ref', p_reference, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p_kind not in ('net_pay', 'bpjs') or p_date is null or length(coalesce(v_ref, '')) > 200 or length(coalesce(v_note, '')) > 1000 then
    raise exception 'INVALID: a payment needs a kind (net_pay or bpjs), a date, a reference up to 200 and a note up to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  -- Net pay is paid per employee (or everything still owed); BPJS is one amount against the run's liability.
  if (p_kind = 'bpjs' and p_lines is not null) or (p_kind = 'net_pay' and p_amount is not null) then
    raise exception 'INVALID: net pay is paid per employee (or everything still owed) and BPJS as one amount; do not mix them'
      using errcode = 'invalid_parameter_value';
  end if;
  v_today := app_private.entity_today(r.entity_id);
  v_scale := app_private.currency_scale(app_private.entity_base_currency(r.entity_id));
  perform app_private.assert_business_date(p_date);
  if p_date > v_today then
    raise exception 'INVALID: a payment cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status not in ('posted', 'partially_paid', 'paid') then
    raise exception 'CONFLICT: payroll can be paid once it is posted and until it is closed (now %)', r.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < r.posting_date then
    raise exception 'INVALID: a payment cannot be dated before the payroll was posted (%)', r.posting_date using errcode = 'invalid_parameter_value';
  end if;
  select * into fa from public.financial_accounts where id = p_account and entity_id = r.entity_id;
  if not found or not fa.is_active then
    raise exception 'INVALID: the paying account is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;
  if fa.currency <> app_private.entity_base_currency(r.entity_id) then
    raise exception 'INVALID: payroll is paid from an account in the Entity''s base currency' using errcode = 'invalid_parameter_value';
  end if;

  if p_kind = 'net_pay' then
    if p_lines is null then
      -- Everything still owed.
      for l in select * from public.payroll_run_lines x2 where x2.run_id = r.id order by x2.employee_id loop
        v_amt := l.net_pay - app_private.payroll_line_paid(l.id);
        if v_amt > 0 then
          v_parts := v_parts || jsonb_build_object('line', l.id, 'amount', v_amt);
          v_total := v_total + v_amt;
        end if;
      end loop;
    else
      if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 1000 then
        raise exception 'INVALID: lines must list the employees paid (up to 1000)' using errcode = 'invalid_parameter_value';
      end if;
      for x in select value from jsonb_array_elements(p_lines) loop
        if jsonb_typeof(x) is distinct from 'object' or coalesce(x ->> 'employee', '') !~ '^[0-9a-f-]{36}$' then
          raise exception 'INVALID: each line needs an employee and an amount' using errcode = 'invalid_parameter_value';
        end if;
        select * into l from public.payroll_run_lines x2 where x2.run_id = r.id and x2.employee_id = (x ->> 'employee')::uuid;
        if not found then
          raise exception 'INVALID: an employee in the payment is not part of this payroll run' using errcode = 'invalid_parameter_value';
        end if;
        if l.id = any (v_seen) then
          raise exception 'INVALID: an employee appears twice in the payment' using errcode = 'invalid_parameter_value';
        end if;
        v_seen := v_seen || l.id;
        v_amt := app_private.parse_amount(x ->> 'amount', 'the net pay paid');
        if v_amt <= 0 or app_private.round_amount(v_amt, v_scale, 'down') <> v_amt then
          raise exception 'INVALID: each amount must be positive with at most % decimals', v_scale using errcode = 'invalid_parameter_value';
        end if;
        v_out := l.net_pay - app_private.payroll_line_paid(l.id);
        if v_amt > v_out then
          raise exception 'INVALID: an employee is owed % but the payment is %', trim_scale(greatest(v_out, 0)), trim_scale(v_amt)
            using errcode = 'invalid_parameter_value';
        end if;
        v_parts := v_parts || jsonb_build_object('line', l.id, 'amount', v_amt);
        v_total := v_total + v_amt;
      end loop;
    end if;
    if v_total <= 0 then
      raise exception 'INVALID: nothing is owed on this payroll run' using errcode = 'invalid_parameter_value';
    end if;
  else
    v_out := r.employee_bpjs_total + r.employer_bpjs_total - app_private.payroll_bpjs_paid(r.id);
    v_total := case when p_amount is null then v_out else app_private.parse_amount(p_amount, 'the BPJS paid') end;
    if v_total <= 0 or app_private.round_amount(v_total, v_scale, 'down') <> v_total then
      raise exception 'INVALID: the BPJS paid must be positive with at most % decimals', v_scale using errcode = 'invalid_parameter_value';
    end if;
    if v_total > v_out then
      raise exception 'INVALID: % of BPJS is still owed; the payment of % exceeds it', trim_scale(greatest(v_out, 0)), trim_scale(v_total)
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  perform app_private.assert_maker_checker(r.entity_id, 'payroll', 'pay', v_total, auth.uid(), 'record this payroll payment');

  perform 1 from public.financial_accounts where id = p_account and entity_id = r.entity_id for no key update;
  perform app_private.ensure_payroll_numbering(r.entity_id);
  v_number := app_private.allocate_document_number(r.entity_id, 'payroll_payment', p_date);
  v_desc := format('Payroll payment %s - %s %s %s', v_number, case p_kind when 'net_pay' then 'net pay' else 'BPJS' end, r.run_number,
                   to_char(r.period_start, 'YYYY-MM'));
  v_journal := app_private.post_system_journal(r.entity_id, 'payroll_payment', v_id, 'payroll.pay', 'payroll.v1', p_date, v_desc,
    jsonb_build_array(
      jsonb_build_object('account_key', case p_kind when 'net_pay' then 'PAYROLL_LIABILITY' else 'BPJS_LIABILITY' end,
                         'debit', v_total, 'credit', 0, 'description', v_desc),
      jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', v_total, 'description', v_desc)));
  perform app_private.record_movement(r.entity_id, p_account, 'out', v_total, v_total, null, p_date, 'payroll_payment', v_id,
    'principal', v_journal, v_desc);
  insert into public.payroll_payments
    (id, entity_id, run_id, payment_number, kind, payment_date, financial_account_id, amount, currency, journal_id, reference, note, created_by)
  values (v_id, r.entity_id, r.id, v_number, p_kind, p_date, p_account, v_total, app_private.entity_base_currency(r.entity_id), v_journal,
          v_ref, v_note, auth.uid());
  if p_kind = 'net_pay' then
    insert into public.payroll_payment_lines (entity_id, payment_id, run_line_id, amount, created_by)
    select r.entity_id, v_id, (p ->> 'line')::uuid, (p ->> 'amount')::numeric, auth.uid()
    from jsonb_array_elements(v_parts) p;
  end if;
  perform app_private.payroll_refresh_status(r.id);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (r.entity_id, 'PayrollPaymentRecorded', 'payroll_payment', v_id, jsonb_build_object('payment_number', v_number, 'kind', p_kind));
  perform app_private.idem_complete('payroll.pay', r.entity_id, p_key, 'payroll_payments', v_id);
  return v_id;
end
$$;

create function public.payroll_reverse_payment(p_payment uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p public.payroll_payments%rowtype;
  r public.payroll_runs%rowtype;
  m public.money_movements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
begin
  select * into p from public.payroll_payments where id = p_payment;
  perform app_private.payroll_authorize(p.entity_id, 'payroll.pay', 'reversing a payroll payment', true);
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) not between 5 and 1000 or p_date > app_private.entity_today(p.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of 5 to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  select * into r from public.payroll_runs where id = p.run_id for update;
  select * into p from public.payroll_payments where id = p_payment for update;
  v_replay := app_private.idem_begin('payroll.pay_reverse', p.entity_id, p_key,
    md5(jsonb_build_object('payment', p_payment, 'date', p_date, 'reason', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed payment can be reversed (now %)', p.status using errcode = 'integrity_constraint_violation';
  end if;
  if r.status not in ('posted', 'partially_paid', 'paid') then
    raise exception 'CONFLICT: a payment of a closed or corrected run cannot be reversed; reopen the run first (now %)', r.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < p.payment_date then
    raise exception 'INVALID: a reversal cannot be dated before the payment' using errcode = 'invalid_parameter_value';
  end if;
  perform 1 from public.financial_accounts where id = p.financial_account_id and entity_id = p.entity_id for no key update;
  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(p.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = p.entity_id and source_type = 'payroll_payment' and source_id = p.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(p.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'payroll_payment', p.id, m.component, v_rev, 'Reversal: ' || v_reason, m.id);
  end loop;
  update public.payroll_payments
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date, reversed_by = auth.uid(),
      reverse_reason = v_reason
  where id = p.id;
  perform app_private.payroll_refresh_status(p.run_id);
  perform app_private.idem_complete('payroll.pay_reverse', p.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

revoke all on all functions in schema app_private from public;
revoke all on function public.payroll_record_payment(uuid, text, text, date, uuid, text, jsonb, text, text) from public, anon;
revoke all on function public.payroll_reverse_payment(uuid, text, date, text) from public, anon;
grant execute on function public.payroll_record_payment(uuid, text, text, date, uuid, text, jsonb, text, text) to authenticated;
grant execute on function public.payroll_reverse_payment(uuid, text, date, text) to authenticated;
