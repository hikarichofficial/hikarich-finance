-- P15 decision 278 (OWNER, 3 October 2026, on the open point of decision 277: "ikut rekomendasimu"): the two
-- BPJS bodies get their own ledger accounts.
--
--   2220  BPJS Ketenagakerjaan Liabilities  (system key BPJS_LIABILITY, the existing account, renamed)
--   2221  BPJS Kesehatan Liabilities        (system key BPJS_KES_LIABILITY, new)
--
-- The existing account keeps its key and code, so nothing that points at it changes; it now carries
-- Ketenagakerjaan only. Posting a payroll run credits each body's account; paying a body debits its account.
-- A run posted before this change has its whole BPJS liability in 2220; none exists in production.
-- The payroll control report keeps one BPJS row: the two accounts together against the two bodies together.

insert into public.coa_template_accounts
  (template_key, code, name, account_class, normal_balance, system_key, parent_code, is_group, is_control, allows_manual_posting)
values
  ('company_default', '2221', 'BPJS Kesehatan Liabilities', 'liability', 'credit', 'BPJS_KES_LIABILITY', null, false, true, false);

update public.coa_template_accounts set name = 'BPJS Ketenagakerjaan Liabilities'
where template_key = 'company_default' and code = '2220';

-- Existing Entities: the new account (provisioning is idempotent) and the new name where the default name is
-- still in use.
select app_private.provision_default_coa(e.id) from public.entities e where e.entity_type = 'company';
update public.ledger_accounts set name = 'BPJS Ketenagakerjaan Liabilities'
where system_key = 'BPJS_LIABILITY' and name = 'BPJS / Related Liabilities';


create or replace function public.payroll_run_post(p_run uuid, p_key text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  l public.payroll_run_lines%rowtype;
  e public.employees%rowtype;
  v_replay uuid;
  v_eng date;
  v_date date;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_det uuid;
  v_num text;
  v_diff jsonb;
  v_expense numeric;
begin
  r := app_private.payroll_run_for(p_run, 'payroll.approve', 'posting payroll', true);
  v_replay := app_private.idem_begin('payroll.post', r.entity_id, p_key, md5(p_run::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status <> 'approved' then
    raise exception 'CONFLICT: only an approved run can be posted (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  if r.employee_count = 0 or exists (select 1 from public.payroll_run_lines x where x.run_id = r.id and array_length(x.review_flags, 1) is not null) then
    raise exception 'INVALID: the run has no lines or a line still needs review' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.payroll_assert_fresh(r);
  v_diff := app_private.payroll_run_differences(r.id);
  if jsonb_array_length(v_diff) > 0 then
    raise exception 'CONFLICT: the run does not reconcile (%)', v_diff -> 0 ->> 'text' using errcode = 'integrity_constraint_violation';
  end if;
  -- PPh 21 must reach the tax ledger, so the tax engine must be running for the month (Step 05 §9).
  v_eng := app_private.tax_engine_from(r.entity_id);
  if v_eng is null then
    raise exception 'INVALID: activate the tax engine for this Entity before posting payroll; PPh 21 must reach the tax ledger'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_eng > r.period_end then
    raise exception 'INVALID: the tax engine of this Entity starts on %, after this payroll period ended; payroll of an earlier period cannot be posted', v_eng
      using errcode = 'invalid_parameter_value';
  end if;
  v_date := least(r.period_end, app_private.entity_today(r.entity_id));
  perform app_private.assert_business_date(v_date);
  v_desc := format('Payroll %s revision %s - %s', r.run_number, r.revision, to_char(r.period_start, 'YYYY-MM'));
  v_expense := r.gross_pay_total + r.tax_allowance_total;

  if v_expense > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'SALARY_EXPENSE', 'debit', v_expense, 'credit', 0, 'description', v_desc);
  end if;
  if r.employer_bpjs_total > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'EMPLOYER_BENEFIT_EXPENSE', 'debit', r.employer_bpjs_total, 'credit', 0,
      'description', 'Employer BPJS: ' || v_desc);
  end if;
  if r.net_pay_total > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'PAYROLL_LIABILITY', 'debit', 0, 'credit', r.net_pay_total, 'description', v_desc);
  end if;
  if r.pph21_total > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'TAX_PAYABLE', 'debit', 0, 'credit', r.pph21_total,
      'description', 'PPh 21: ' || v_desc);
  end if;
  -- One liability line per body (decision 277). Should the lines ever not add up to the run's total, the
  -- difference stays with Ketenagakerjaan so the journal still balances with the totals above.
  if r.employee_bpjs_total + r.employer_bpjs_total > 0 then
    if app_private.payroll_bpjs_due(r.id, 'kes') > 0 then
      v_lines := v_lines || jsonb_build_object('account_key', 'BPJS_KES_LIABILITY', 'debit', 0,
        'credit', app_private.payroll_bpjs_due(r.id, 'kes'), 'description', 'BPJS Kesehatan: ' || v_desc);
    end if;
    if r.employee_bpjs_total + r.employer_bpjs_total - app_private.payroll_bpjs_due(r.id, 'kes') > 0 then
      v_lines := v_lines || jsonb_build_object('account_key', 'BPJS_LIABILITY', 'debit', 0,
        'credit', r.employee_bpjs_total + r.employer_bpjs_total - app_private.payroll_bpjs_due(r.id, 'kes'),
        'description', 'BPJS Ketenagakerjaan: ' || v_desc);
    end if;
  end if;
  if jsonb_array_length(v_lines) < 2 then
    raise exception 'INVALID: a payroll run with nothing to book cannot be posted' using errcode = 'invalid_parameter_value';
  end if;
  v_journal := app_private.post_system_journal(r.entity_id, 'payroll_run', r.id, 'payroll.post', 'payroll.v1', v_date, v_desc, v_lines);

  -- The PPh 21 consequence: the aggregate only; per-employee detail stays inside the payroll boundary.
  insert into public.tax_determinations
    (entity_id, tax_kind, tax_type, source_type, source_id, event_date, tax_period, status, currency, base_amount, rate,
     tax_amount, direction, rules, facts, trace, components, consequence, journal_id, confirmed)
  values
    (r.entity_id, 'wht_pph21', 'wht_pph21', 'payroll_run', r.id, v_date, r.period_start, 'auto_determined',
     app_private.entity_base_currency(r.entity_id), r.tax_base_total, null, r.pph21_total, 'payable', r.rules,
     jsonb_build_object('run_number', r.run_number, 'revision', r.revision, 'employee_count', r.employee_count),
     app_private.tax_trace_add(app_private.tax_trace_add('[]'::jsonb,
       format('PPh 21 of payroll %s for %s was computed per employee from the rule versions listed', r.run_number, to_char(r.period_start, 'YYYY-MM'))),
       'Per-employee amounts stay in the payroll module; the tax ledger holds the total'),
     jsonb_build_array(
       jsonb_build_object('name', 'withheld_from_employees', 'amount', app_private.tax_money(r.pph21_total - r.tax_allowance_total)),
       jsonb_build_object('name', 'borne_by_employer_as_allowance', 'amount', app_private.tax_money(r.tax_allowance_total))),
     case when r.pph21_total > 0
       then format('%s is credited to Tax Payables and accrues in the PPh 21 ledger for %s; it is settled through a tax payment.',
                   trim_scale(r.pph21_total), to_char(r.period_start, 'YYYY-MM'))
       else 'No PPh 21 is due for this payroll month.' end,
     v_journal, false)
  returning id into v_det;
  if r.pph21_total > 0 then
    insert into public.tax_ledger_entries
      (entity_id, determination_id, tax_kind, tax_type, tax_period, direction, entry_kind, amount, entry_date, journal_id, description)
    values (r.entity_id, v_det, 'wht_pph21', 'wht_pph21', r.period_start, 'payable', 'accrual', r.pph21_total, v_date, v_journal,
            left('PPh 21 payroll ' || to_char(r.period_start, 'YYYY-MM'), 300));
  end if;

  -- One payslip per line: an immutable snapshot.
  perform app_private.ensure_payroll_numbering(r.entity_id);
  for l in select * from public.payroll_run_lines x where x.run_id = r.id order by x.employee_id loop
    select * into e from public.employees where id = l.employee_id;
    v_num := app_private.allocate_document_number(r.entity_id, 'payslip', v_date);
    insert into public.payroll_payslips (entity_id, run_id, run_line_id, employee_id, payslip_number, snapshot, created_by)
    values (r.entity_id, r.id, l.id, l.employee_id, v_num, jsonb_build_object(
      'payslip_number', v_num, 'run_number', r.run_number, 'revision', r.revision, 'period', to_char(r.period_start, 'YYYY-MM'),
      'pay_date', r.pay_date,
      'employee', jsonb_build_object('id', e.id, 'code', e.employee_code, 'name', e.full_name),
      'components', l.components,
      'adjustments', coalesce((select jsonb_agg(jsonb_build_object('kind', a.kind, 'label', a.label, 'amount', app_private.tax_money(a.amount),
                                                                   'taxable', a.taxable) order by a.kind, a.label)
                               from public.payroll_adjustments a where a.run_id = r.id and a.employee_id = l.employee_id), '[]'::jsonb),
      'earnings_total', app_private.tax_money(l.earnings_total), 'reductions_total', app_private.tax_money(l.reductions_total),
      'adjustment_earnings', app_private.tax_money(l.adjustment_earnings), 'adjustment_deductions', app_private.tax_money(l.adjustment_deductions),
      'gross_pay', app_private.tax_money(l.gross_pay),
      'bpjs_employee', jsonb_build_object('kes', app_private.tax_money(l.bpjs_kes_employee), 'jht', app_private.tax_money(l.bpjs_jht_employee),
                                          'jp', app_private.tax_money(l.bpjs_jp_employee)),
      'bpjs_employer', jsonb_build_object('kes', app_private.tax_money(l.bpjs_kes_employer), 'jht', app_private.tax_money(l.bpjs_jht_employer),
                                          'jp', app_private.tax_money(l.bpjs_jp_employer), 'jkk', app_private.tax_money(l.bpjs_jkk_employer),
                                          'jkm', app_private.tax_money(l.bpjs_jkm_employer)),
      'tax', jsonb_build_object('mode', l.tax_mode, 'method', l.tax_method, 'base', app_private.tax_money(l.tax_base),
                                'pph21', app_private.tax_money(l.pph21), 'allowance', app_private.tax_money(l.tax_allowance),
                                'withheld_from_employee', app_private.tax_money(l.pph21 - l.tax_allowance)),
      'net_pay', app_private.tax_money(l.net_pay)), auth.uid());
  end loop;

  update public.payroll_runs
  set status = 'posted', posted_at = now(), posted_by = auth.uid(), posting_date = v_date, journal_id = v_journal
  where id = r.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (r.entity_id, 'PayrollPosted', 'payroll_run', r.id, jsonb_build_object('run_number', r.run_number, 'revision', r.revision));
  perform app_private.idem_complete('payroll.post', r.entity_id, p_key, 'journal_entries', v_journal);
  return v_journal;
end
$$;

create or replace function public.payroll_record_payment(
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
  if p_kind not in ('net_pay', 'bpjs_kes', 'bpjs_tk') or p_date is null or length(coalesce(v_ref, '')) > 200 or length(coalesce(v_note, '')) > 1000 then
    raise exception 'INVALID: a payment needs a kind (net pay, BPJS Kesehatan or BPJS Ketenagakerjaan), a date, a reference up to 200 and a note up to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  -- Net pay is paid per employee (or everything still owed); BPJS is one amount against the run's liability.
  if (p_kind <> 'net_pay' and p_lines is not null) or (p_kind = 'net_pay' and p_amount is not null) then
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
    -- What is still owed to this body, and never more than what the run still owes for BPJS in total (earlier
    -- payments that did not name a body count against the total).
    v_out := least(
      app_private.payroll_bpjs_due(r.id, substr(p_kind, 6)) - app_private.payroll_bpjs_paid_body(r.id, substr(p_kind, 6)),
      r.employee_bpjs_total + r.employer_bpjs_total - app_private.payroll_bpjs_paid(r.id));
    v_total := case when p_amount is null then v_out else app_private.parse_amount(p_amount, 'the BPJS paid') end;
    if v_total <= 0 or app_private.round_amount(v_total, v_scale, 'down') <> v_total then
      raise exception 'INVALID: the BPJS paid must be positive with at most % decimals', v_scale using errcode = 'invalid_parameter_value';
    end if;
    if v_total > v_out then
      raise exception 'INVALID: % is still owed to %; the payment of % exceeds it', trim_scale(greatest(v_out, 0)),
        case p_kind when 'bpjs_kes' then 'BPJS Kesehatan' else 'BPJS Ketenagakerjaan' end, trim_scale(v_total)
        using errcode = 'invalid_parameter_value';
    end if;
  end if;
  perform app_private.assert_maker_checker(r.entity_id, 'payroll', 'pay', v_total, auth.uid(), 'record this payroll payment');

  perform 1 from public.financial_accounts where id = p_account and entity_id = r.entity_id for no key update;
  perform app_private.ensure_payroll_numbering(r.entity_id);
  v_number := app_private.allocate_document_number(r.entity_id, 'payroll_payment', p_date);
  v_desc := format('Payroll payment %s - %s %s %s', v_number, case p_kind when 'net_pay' then 'net pay' when 'bpjs_kes' then 'BPJS Kesehatan' else 'BPJS Ketenagakerjaan' end,
                   r.run_number,
                   to_char(r.period_start, 'YYYY-MM'));
  v_journal := app_private.post_system_journal(r.entity_id, 'payroll_payment', v_id, 'payroll.pay', 'payroll.v1', p_date, v_desc,
    jsonb_build_array(
      jsonb_build_object('account_key', case p_kind when 'net_pay' then 'PAYROLL_LIABILITY' when 'bpjs_kes' then 'BPJS_KES_LIABILITY'
                                         else 'BPJS_LIABILITY' end,
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

create or replace function app_private.payroll_control(p_entity uuid, p_as_of date default null)
returns table (account_key text, sub_ledger numeric, ledger_workflow numeric, ledger_other numeric, ledger_total numeric)
language plpgsql stable as $$
declare
  v_asof date := coalesce(p_as_of, app_private.entity_today(p_entity));
  v_net numeric;
  v_bpjs numeric;
  v_net_l numeric;
  v_bpjs_l numeric;
  v_net_w numeric;
  v_bpjs_w numeric;
begin
  select coalesce(sum(r.net_pay_total), 0), coalesce(sum(r.employee_bpjs_total + r.employer_bpjs_total), 0)
    into v_net, v_bpjs
  from public.payroll_runs r
  where r.entity_id = p_entity and r.journal_id is not null and r.posting_date <= v_asof
    and (r.reversal_journal_id is null or (select j.entry_date from public.journal_entries j where j.id = r.reversal_journal_id) > v_asof);
  v_net := v_net - coalesce((select sum(p.amount) from public.payroll_payments p where p.entity_id = p_entity and p.kind = 'net_pay'
                             and p.payment_date <= v_asof and (p.status = 'confirmed' or p.reversed_date > v_asof)), 0);
  v_bpjs := v_bpjs - coalesce((select sum(p.amount) from public.payroll_payments p where p.entity_id = p_entity and p.kind in ('bpjs', 'bpjs_kes', 'bpjs_tk')
                               and p.payment_date <= v_asof and (p.status = 'confirmed' or p.reversed_date > v_asof)), 0);

  select coalesce(sum(l.credit - l.debit), 0), coalesce(sum(l.credit - l.debit) filter (where app_private.is_payroll_journal(j.id)), 0)
    into v_net_l, v_net_w
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = 'PAYROLL_LIABILITY' and j.status = 'posted' and j.entry_date <= v_asof;
  select coalesce(sum(l.credit - l.debit), 0), coalesce(sum(l.credit - l.debit) filter (where app_private.is_payroll_journal(j.id)), 0)
    into v_bpjs_l, v_bpjs_w
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key in ('BPJS_LIABILITY', 'BPJS_KES_LIABILITY') and j.status = 'posted' and j.entry_date <= v_asof;

  return query
  select 'PAYROLL_LIABILITY'::text, v_net, v_net_w, v_net_l - v_net_w, v_net_l
  union all
  select 'BPJS_LIABILITY'::text, v_bpjs, v_bpjs_w, v_bpjs_l - v_bpjs_w, v_bpjs_l;
end
$$;

create or replace function app_private.payroll_run_differences(p_run uuid) returns jsonb
language plpgsql stable as $$
declare
  r public.payroll_runs%rowtype;
  v_out jsonb := '[]'::jsonb;
  v_lines record;
  v_debit numeric;
  v_credit numeric;
  v_tax numeric;
  v_slips bigint;
  v_slip_net numeric;
begin
  select * into r from public.payroll_runs where id = p_run;
  select count(*), coalesce(sum(l.gross_pay), 0) as gross, coalesce(sum(l.tax_allowance), 0) as allow,
         coalesce(sum(l.bpjs_kes_employee + l.bpjs_jht_employee + l.bpjs_jp_employee), 0) as emp,
         coalesce(sum(l.bpjs_kes_employer + l.bpjs_jht_employer + l.bpjs_jp_employer + l.bpjs_jkk_employer + l.bpjs_jkm_employer), 0) as er,
         coalesce(sum(l.pph21), 0) as pph, coalesce(sum(l.net_pay), 0) as net,
         coalesce(sum(l.gross_pay - (l.bpjs_kes_employee + l.bpjs_jht_employee + l.bpjs_jp_employee) - (l.pph21 - l.tax_allowance) - l.net_pay), 0) as netdiff
    into v_lines
  from public.payroll_run_lines l where l.run_id = p_run;
  if v_lines.gross <> r.gross_pay_total or v_lines.allow <> r.tax_allowance_total or v_lines.emp <> r.employee_bpjs_total
     or v_lines.er <> r.employer_bpjs_total or v_lines.pph <> r.pph21_total or v_lines.net <> r.net_pay_total then
    v_out := v_out || jsonb_build_object('code', 'lines_differ_from_run', 'text', 'The lines do not add up to the totals of the run');
  end if;
  if v_lines.netdiff <> 0 then
    v_out := v_out || jsonb_build_object('code', 'net_pay_formula', 'text', 'Net pay is not gross pay less employee BPJS and the tax borne by the employee');
  end if;
  if r.journal_id is not null then
    select coalesce(sum(jl.debit) filter (where a.system_key = 'SALARY_EXPENSE'), 0) into v_debit
    from public.journal_lines jl join public.ledger_accounts a on a.id = jl.ledger_account_id and a.entity_id = jl.entity_id
    where jl.journal_id = r.journal_id;
    if v_debit <> r.gross_pay_total + r.tax_allowance_total then
      v_out := v_out || jsonb_build_object('code', 'salary_expense_differs', 'text', 'Salary expense in the journal differs from gross pay plus tax allowance');
    end if;
    select coalesce(sum(jl.debit) filter (where a.system_key = 'EMPLOYER_BENEFIT_EXPENSE'), 0) into v_debit
    from public.journal_lines jl join public.ledger_accounts a on a.id = jl.ledger_account_id and a.entity_id = jl.entity_id
    where jl.journal_id = r.journal_id;
    if v_debit <> r.employer_bpjs_total then
      v_out := v_out || jsonb_build_object('code', 'employer_cost_differs', 'text', 'Employer BPJS cost in the journal differs from the run');
    end if;
    select coalesce(sum(jl.credit) filter (where a.system_key = 'PAYROLL_LIABILITY'), 0) into v_credit
    from public.journal_lines jl join public.ledger_accounts a on a.id = jl.ledger_account_id and a.entity_id = jl.entity_id
    where jl.journal_id = r.journal_id;
    if v_credit <> r.net_pay_total then
      v_out := v_out || jsonb_build_object('code', 'net_pay_liability_differs', 'text', 'The net pay liability in the journal differs from the run');
    end if;
    select coalesce(sum(jl.credit) filter (where a.system_key in ('BPJS_LIABILITY', 'BPJS_KES_LIABILITY')), 0) into v_credit
    from public.journal_lines jl join public.ledger_accounts a on a.id = jl.ledger_account_id and a.entity_id = jl.entity_id
    where jl.journal_id = r.journal_id;
    if v_credit <> r.employee_bpjs_total + r.employer_bpjs_total then
      v_out := v_out || jsonb_build_object('code', 'bpjs_liability_differs', 'text', 'The BPJS liability in the journal differs from the run');
    end if;
    select coalesce(sum(jl.credit) filter (where a.system_key = 'TAX_PAYABLE'), 0) into v_credit
    from public.journal_lines jl join public.ledger_accounts a on a.id = jl.ledger_account_id and a.entity_id = jl.entity_id
    where jl.journal_id = r.journal_id;
    if v_credit <> r.pph21_total then
      v_out := v_out || jsonb_build_object('code', 'tax_payable_differs', 'text', 'PPh 21 in the journal differs from the run');
    end if;
    if r.status <> 'corrected' then
      select coalesce(sum(d.tax_amount), 0) into v_tax from public.tax_determinations d
      where d.entity_id = r.entity_id and d.source_type = 'payroll_run' and d.source_id = r.id and d.superseded_at is null;
      if v_tax <> r.pph21_total then
        v_out := v_out || jsonb_build_object('code', 'tax_determination_differs', 'text', 'The PPh 21 of the tax layer differs from the run');
      end if;
      select count(*), coalesce(sum((s.snapshot ->> 'net_pay')::numeric), 0) into v_slips, v_slip_net
      from public.payroll_payslips s where s.run_id = r.id and s.status = 'issued';
      if v_slips <> v_lines.count or v_slip_net <> r.net_pay_total then
        v_out := v_out || jsonb_build_object('code', 'payslips_differ', 'text', 'The payslips do not match the lines of the run');
      end if;
    end if;
  end if;
  if app_private.payroll_net_paid(p_run) > r.net_pay_total then
    v_out := v_out || jsonb_build_object('code', 'overpaid', 'text', 'More net pay was paid than the run owes');
  end if;
  return v_out;
end
$$;
