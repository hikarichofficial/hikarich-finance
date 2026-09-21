-- P9 part 6: the payroll run lifecycle commands.
-- Authority: Step 07 §14 (workflow), Step 06 §4/§6/§7 (payroll capabilities, sensitive boundary, maker-checker),
-- Step 08 §13 (payroll integrity), Step 04 §8 (payroll posting), Step 05 §9 (payroll tax), Step 16 §18 (acceptance).
--
-- The lifecycle is: create -> calculate -> (adjust) -> submit -> approve -> post -> pay -> close, with a correction
-- path from posted on. Rules that hold in every command:
--   * the capability is checked first (payroll.run to prepare and submit, payroll.approve to approve, post, close and
--     correct, payroll.pay for payments) and every command that shows or processes money also needs
--     payroll.compensation_view, so nobody works with amounts they may not see;
--   * an approver is not the submitter unless an approval rule allows it or they are the OWNER (Step 06 §7);
--   * approval and posting refuse a run whose inputs changed since it was calculated - a posted run is never
--     silently recalculated (Step 08 §13);
--   * posting happens once per run revision: the journal, the PPh 21 determination and the payslips are created in one
--     transaction, and a repeated request returns the same result;
--   * a correction reverses the journal and the tax consequence, voids the payslips, keeps the original run visible
--     and opens the next revision as a draft (Step 08 §13, Step 16 §18).

-- ------------------------------------------------------------ helpers
create function app_private.payroll_run_for(p_run uuid, p_perm text, p_what text, p_amounts boolean)
returns public.payroll_runs
language plpgsql stable as $$
declare
  r public.payroll_runs%rowtype;
begin
  select * into r from public.payroll_runs where id = p_run;
  perform app_private.payroll_authorize(r.entity_id, p_perm, p_what, p_amounts);
  return r;
end
$$;

-- The inputs must be what the calculation saw.
create function app_private.payroll_assert_fresh(r public.payroll_runs) returns void
language plpgsql stable as $$
begin
  if r.input_fingerprint is distinct from app_private.payroll_inputs_fingerprint(r.id) then
    raise exception 'CONFLICT: the compensation, tax facts, BPJS enrolment, adjustments, employees or rules changed since this run was calculated; calculate it again'
      using errcode = 'integrity_constraint_violation';
  end if;
end
$$;

-- ------------------------------------------------------------ opening tax figures
create function public.employee_set_tax_opening(
  p_employee uuid, p_key text, p_year integer, p_through_month integer, p_gross text, p_pension text, p_tax text,
  p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  v_replay uuid;
  v_id uuid := gen_random_uuid();
  v_gross numeric;
  v_pension numeric;
  v_tax numeric;
  v_rev integer;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.compensation_edit', 'recording opening tax figures', true);
  if not app_authz.has_permission(e.entity_id, 'payroll.tax_view') then
    raise exception 'FORBIDDEN: opening tax figures need payroll.tax_view' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('employee.tax_opening', e.entity_id, p_key,
    md5(jsonb_build_object('e', p_employee, 'y', p_year, 'm', p_through_month, 'g', p_gross, 'p', p_pension, 't', p_tax, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  v_gross := app_private.parse_amount(p_gross, 'the taxable gross income');
  v_pension := app_private.parse_amount(coalesce(nullif(btrim(p_pension), ''), '0'), 'the pension contributions');
  v_tax := app_private.parse_amount(p_tax, 'the PPh 21 withheld');
  if p_year is null or p_year not between 2000 and 2100 or p_through_month is null or p_through_month not between 1 and 11
     or v_gross < 0 or v_pension < 0 or v_tax < 0 or length(coalesce(p_note, '')) > 500 then
    raise exception 'INVALID: opening tax figures need a tax year, a month from 1 to 11 and non-negative amounts'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_year < extract(year from e.join_date)::integer then
    raise exception 'INVALID: the tax year is before the employee joined' using errcode = 'invalid_parameter_value';
  end if;
  perform 1 from public.employees where id = e.id for update;
  if exists (select 1 from public.payroll_run_lines l join public.payroll_runs r on r.id = l.run_id
             where l.employee_id = e.id and extract(year from r.period_start) = p_year
               and r.status in ('posted', 'partially_paid', 'paid', 'closed')) then
    raise exception 'CONFLICT: payroll of that tax year is already posted for this employee; the opening figures cannot change'
      using errcode = 'integrity_constraint_violation';
  end if;
  select coalesce(max(revision), 0) + 1 into v_rev from public.employee_tax_openings where employee_id = e.id and tax_year = p_year;
  insert into public.employee_tax_openings
    (id, entity_id, employee_id, tax_year, revision, through_month, taxable_gross, pension_deduction, pph21_withheld, note, created_by)
  values (v_id, e.entity_id, e.id, p_year, v_rev, p_through_month, v_gross, v_pension, v_tax, nullif(btrim(coalesce(p_note, '')), ''), auth.uid());
  perform app_private.idem_complete('employee.tax_opening', e.entity_id, p_key, 'employee_tax_openings', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ create and calculate
create function public.payroll_run_create(p_entity uuid, p_key text, p_period date, p_pay_date date, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid := gen_random_uuid();
  v_start date := date_trunc('month', p_period)::date;
  v_end date;
  v_number text;
  v_rev integer;
begin
  perform app_private.payroll_authorize(p_entity, 'payroll.run', 'creating a payroll run');
  v_replay := app_private.idem_begin('payroll.create', p_entity, p_key,
    md5(jsonb_build_object('p', p_period, 'd', p_pay_date, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p_period is null or p_pay_date is null or length(coalesce(p_note, '')) > 1000 then
    raise exception 'INVALID: a payroll run needs a payroll month and a pay date' using errcode = 'invalid_parameter_value';
  end if;
  if v_start > app_private.entity_today(p_entity) then
    raise exception 'INVALID: payroll cannot be run for a month that has not started' using errcode = 'invalid_parameter_value';
  end if;
  if p_pay_date < v_start then
    raise exception 'INVALID: the pay date cannot be before the payroll month' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_pay_date);
  v_end := (v_start + interval '1 month - 1 day')::date;
  perform pg_advisory_xact_lock(hashtextextended('payroll_run:' || p_entity::text || ':' || v_start::text, 0));
  if exists (select 1 from public.payroll_runs r
             where r.entity_id = p_entity and r.period_start = v_start and r.status not in ('corrected', 'discarded')) then
    raise exception 'CONFLICT: this payroll month already has a live run (Step 08 §13: no duplicate final run)'
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.ensure_payroll_numbering(p_entity);
  select r.run_number, r.revision + 1 into v_number, v_rev from public.payroll_runs r
  where r.entity_id = p_entity and r.period_start = v_start order by r.revision desc limit 1;
  if v_number is null then
    v_number := app_private.allocate_document_number(p_entity, 'payroll_run', v_end);
    v_rev := 1;
  end if;
  insert into public.payroll_runs (id, entity_id, run_number, revision, period_start, period_end, pay_date, note, created_by)
  values (v_id, p_entity, v_number, v_rev, v_start, v_end, p_pay_date, nullif(btrim(coalesce(p_note, '')), ''), auth.uid());
  perform app_private.idem_complete('payroll.create', p_entity, p_key, 'payroll_runs', v_id);
  return v_id;
end
$$;

create function public.payroll_run_calculate(p_run uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
begin
  r := app_private.payroll_run_for(p_run, 'payroll.run', 'calculating payroll', true);
  perform app_private.payroll_calculate_core(p_run);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (r.entity_id, 'PayrollCalculated', 'payroll_run', r.id, jsonb_build_object('run_number', r.run_number));
end
$$;

-- ------------------------------------------------------------ adjustments
create function public.payroll_adjustment_add(
  p_run uuid, p_key text, p_employee uuid, p_kind text, p_label text, p_amount text, p_taxable boolean default true)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_replay uuid;
  v_id uuid := gen_random_uuid();
  v_amount numeric;
  v_label text := btrim(coalesce(p_label, ''));
begin
  r := app_private.payroll_run_for(p_run, 'payroll.run', 'adjusting payroll', true);
  v_replay := app_private.idem_begin('payroll.adjust', r.entity_id, p_key,
    md5(jsonb_build_object('r', p_run, 'e', p_employee, 'k', p_kind, 'l', p_label, 'a', p_amount, 't', p_taxable)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status not in ('draft', 'calculated') then
    raise exception 'CONFLICT: adjustments change only while a run is a draft or calculated; return a submitted run first (now %)', r.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_kind not in ('earning', 'deduction') or length(v_label) not between 1 and 120 or p_taxable is null then
    raise exception 'INVALID: an adjustment needs a kind (earning or deduction), a label and a taxable flag' using errcode = 'invalid_parameter_value';
  end if;
  v_amount := app_private.parse_amount(p_amount, 'the adjustment');
  if v_amount <= 0 or app_private.round_amount(v_amount, app_private.currency_scale(app_private.entity_base_currency(r.entity_id)), 'down') <> v_amount then
    raise exception 'INVALID: the adjustment must be positive with at most the currency''s decimals' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from app_private.payroll_eligible_employees(r) x where x.id = p_employee) then
    raise exception 'INVALID: the employee is not part of this payroll month' using errcode = 'invalid_parameter_value';
  end if;
  update public.payroll_runs set status = 'draft' where id = r.id and status <> 'draft';
  insert into public.payroll_adjustments (id, entity_id, run_id, employee_id, kind, label, amount, taxable, created_by)
  values (v_id, r.entity_id, r.id, p_employee, p_kind, v_label, v_amount, p_taxable, auth.uid());
  perform app_private.idem_complete('payroll.adjust', r.entity_id, p_key, 'payroll_adjustments', v_id);
  return v_id;
end
$$;

create function public.payroll_adjustment_remove(p_adjustment uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.payroll_adjustments%rowtype;
  r public.payroll_runs%rowtype;
begin
  select * into a from public.payroll_adjustments where id = p_adjustment;
  r := app_private.payroll_run_for(a.run_id, 'payroll.run', 'adjusting payroll', true);
  select * into r from public.payroll_runs where id = a.run_id for update;
  if r.status not in ('draft', 'calculated') then
    raise exception 'CONFLICT: adjustments change only while a run is a draft or calculated (now %)', r.status
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.payroll_runs set status = 'draft' where id = r.id and status <> 'draft';
  delete from public.payroll_adjustments where id = a.id;
end
$$;

-- ------------------------------------------------------------ submit, return, approve, discard
create function public.payroll_run_submit(p_run uuid, p_key text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_replay uuid;
begin
  r := app_private.payroll_run_for(p_run, 'payroll.run', 'submitting payroll', true);
  v_replay := app_private.idem_begin('payroll.submit', r.entity_id, p_key, md5(p_run::text));
  if v_replay is not null then
    return;
  end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status <> 'calculated' then
    raise exception 'CONFLICT: only a calculated run can be submitted (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  if r.employee_count = 0 then
    raise exception 'INVALID: the run has no employees' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.payroll_run_lines l where l.run_id = r.id and array_length(l.review_flags, 1) is not null) then
    raise exception 'INVALID: % line(s) need review (missing tax facts, rules or history); resolve them and calculate again',
      (select count(*) from public.payroll_run_lines l where l.run_id = r.id and array_length(l.review_flags, 1) is not null)
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.payroll_assert_fresh(r);
  update public.payroll_runs set status = 'submitted', submitted_at = now(), submitted_by = auth.uid() where id = r.id;
  perform app_private.idem_complete('payroll.submit', r.entity_id, p_key, 'payroll_runs', r.id);
end
$$;

-- Return a submitted or approved run to draft (the approver rejects it, or the preparer withdraws it).
create function public.payroll_run_return(p_run uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  select * into r from public.payroll_runs where id = p_run;
  perform app_private.payroll_authorize(r.entity_id,
    case when app_authz.has_permission(r.entity_id, 'payroll.run') then 'payroll.run' else 'payroll.approve' end,
    'returning a payroll run');
  if length(v_reason) not between 5 and 500 then
    raise exception 'INVALID: a reason of 5 to 500 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status not in ('submitted', 'approved') then
    raise exception 'CONFLICT: only a submitted or approved run can be returned (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.payroll_runs
  set status = 'draft', submitted_at = null, submitted_by = null, approved_at = null, approved_by = null
  where id = r.id;
end
$$;

create function public.payroll_run_approve(p_run uuid, p_key text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_replay uuid;
begin
  r := app_private.payroll_run_for(p_run, 'payroll.approve', 'approving payroll', true);
  v_replay := app_private.idem_begin('payroll.approve', r.entity_id, p_key, md5(p_run::text));
  if v_replay is not null then
    return;
  end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status <> 'submitted' then
    raise exception 'CONFLICT: only a submitted run can be approved (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_maker_checker(r.entity_id, 'payroll', 'approve', r.net_pay_total, r.submitted_by, 'approve this payroll run');
  perform app_private.payroll_assert_fresh(r);
  update public.payroll_runs set status = 'approved', approved_at = now(), approved_by = auth.uid() where id = r.id;
  perform app_private.idem_complete('payroll.approve', r.entity_id, p_key, 'payroll_runs', r.id);
end
$$;

create function public.payroll_run_discard(p_run uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  r := app_private.payroll_run_for(p_run, 'payroll.run', 'discarding a payroll run', false);
  if length(v_reason) not between 5 and 500 then
    raise exception 'INVALID: a reason of 5 to 500 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status not in ('draft', 'calculated', 'submitted', 'approved') then
    raise exception 'CONFLICT: a run that is posted can only be corrected, not discarded (now %)', r.status
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.payroll_runs
  set status = 'discarded', discarded_at = now(), discarded_by = auth.uid(), discard_reason = v_reason
  where id = r.id;
end
$$;

-- ------------------------------------------------------------ posting
create function public.payroll_run_post(p_run uuid, p_key text) returns uuid
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
  if v_eng is null or v_eng > r.period_end then
    raise exception 'INVALID: activate the tax engine for this Entity before posting payroll; PPh 21 must reach the tax ledger'
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
  if r.employee_bpjs_total + r.employer_bpjs_total > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'BPJS_LIABILITY', 'debit', 0,
      'credit', r.employee_bpjs_total + r.employer_bpjs_total, 'description', 'BPJS: ' || v_desc);
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

-- ------------------------------------------------------------ close and reopen
create function public.payroll_run_close(p_run uuid, p_key text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_replay uuid;
  v_diff jsonb;
begin
  r := app_private.payroll_run_for(p_run, 'payroll.approve', 'closing payroll', true);
  v_replay := app_private.idem_begin('payroll.close', r.entity_id, p_key, md5(p_run::text));
  if v_replay is not null then
    return;
  end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if not (r.status = 'paid' or (r.status = 'posted' and r.net_pay_total = 0)) then
    raise exception 'CONFLICT: a run is closed once its net pay is fully paid (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  v_diff := app_private.payroll_run_differences(r.id);
  if jsonb_array_length(v_diff) > 0 then
    raise exception 'CONFLICT: the run does not reconcile and cannot be closed (%)', v_diff -> 0 ->> 'text'
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.payroll_runs set status = 'closed', closed_at = now(), closed_by = auth.uid() where id = r.id;
  perform app_private.idem_complete('payroll.close', r.entity_id, p_key, 'payroll_runs', r.id);
end
$$;

create function public.payroll_run_reopen(p_run uuid, p_key text, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_replay uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  r := app_private.payroll_run_for(p_run, 'payroll.approve', 'reopening payroll', true);
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('payroll.reopen', r.entity_id, p_key, md5(jsonb_build_object('r', p_run, 'x', p_reason)::text));
  if v_replay is not null then
    return;
  end if;
  if length(v_reason) not between 5 and 500 then
    raise exception 'INVALID: a reason of 5 to 500 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status <> 'closed' then
    raise exception 'CONFLICT: only a closed run can be reopened (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.payroll_runs set status = 'paid', closed_at = null, closed_by = null where id = r.id;
  perform app_private.idem_complete('payroll.reopen', r.entity_id, p_key, 'payroll_runs', r.id);
end
$$;

-- ------------------------------------------------------------ correction (Step 08 §13)
-- Reverses a posted run and opens the next revision of the month as a draft. Payments must be reversed first (so the
-- liabilities are whole again), and only the latest posted month of the tax year can be corrected, because the annual
-- reconciliation of the last tax month depends on the months before it.
create function public.payroll_run_correct(p_run uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_replay uuid;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_rev uuid;
  v_new uuid := gen_random_uuid();
begin
  r := app_private.payroll_run_for(p_run, 'payroll.approve', 'correcting payroll', true);
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('payroll.correct', r.entity_id, p_key, md5(jsonb_build_object('r', p_run, 'd', p_date, 'x', p_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p_date is null or length(v_reason) not between 5 and 1000 or p_date > app_private.entity_today(r.entity_id) then
    raise exception 'INVALID: a correction needs a date (not in the future) and a reason of 5 to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform pg_advisory_xact_lock(hashtextextended('payroll_run:' || r.entity_id::text || ':' || r.period_start::text, 0));
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status not in ('posted', 'partially_paid', 'paid') then
    raise exception 'CONFLICT: only a posted run can be corrected; reopen a closed run first (now %)', r.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if exists (select 1 from public.payroll_payments p where p.run_id = r.id and p.status = 'confirmed') then
    raise exception 'CONFLICT: reverse the payments of this run first' using errcode = 'integrity_constraint_violation';
  end if;
  if exists (select 1 from public.payroll_runs x
             where x.entity_id = r.entity_id and extract(year from x.period_start) = extract(year from r.period_start)
               and x.period_start > r.period_start and x.status in ('posted', 'partially_paid', 'paid', 'closed')) then
    raise exception 'CONFLICT: a later month of the same tax year is posted; correct the latest month first'
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(r.journal_id, p_date, v_reason);
  perform app_private.tax_reverse_source('payroll_run', r.id, v_rev, p_date, v_reason);
  update public.payroll_payslips set status = 'voided', voided_at = now(), void_reason = left(v_reason, 1000)
  where run_id = r.id and status = 'issued';
  update public.payroll_runs
  set status = 'corrected', reversal_journal_id = v_rev, corrected_at = now(), corrected_by = auth.uid(), correction_reason = v_reason
  where id = r.id;
  -- The next revision starts as a draft with the same one-off adjustments.
  insert into public.payroll_runs (id, entity_id, run_number, revision, period_start, period_end, pay_date, corrects_run_id, note, created_by)
  values (v_new, r.entity_id, r.run_number, r.revision + 1, r.period_start, r.period_end, r.pay_date, r.id, r.note, auth.uid());
  insert into public.payroll_adjustments (entity_id, run_id, employee_id, kind, label, amount, taxable, created_by)
  select a.entity_id, v_new, a.employee_id, a.kind, a.label, a.amount, a.taxable, auth.uid()
  from public.payroll_adjustments a where a.run_id = r.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (r.entity_id, 'PayrollCorrected', 'payroll_run', r.id, jsonb_build_object('run_number', r.run_number, 'revision', r.revision));
  perform app_private.idem_complete('payroll.correct', r.entity_id, p_key, 'payroll_runs', v_new);
  return v_new;
end
$$;

revoke all on function app_private.payroll_run_for(uuid, text, text, boolean) from public;
revoke all on function app_private.payroll_assert_fresh(public.payroll_runs) from public;
revoke all on all functions in schema app_private from public;

revoke all on function public.employee_set_tax_opening(uuid, text, integer, integer, text, text, text, text) from public, anon;
revoke all on function public.payroll_run_create(uuid, text, date, date, text) from public, anon;
revoke all on function public.payroll_run_calculate(uuid) from public, anon;
revoke all on function public.payroll_adjustment_add(uuid, text, uuid, text, text, text, boolean) from public, anon;
revoke all on function public.payroll_adjustment_remove(uuid) from public, anon;
revoke all on function public.payroll_run_submit(uuid, text) from public, anon;
revoke all on function public.payroll_run_return(uuid, text) from public, anon;
revoke all on function public.payroll_run_approve(uuid, text) from public, anon;
revoke all on function public.payroll_run_discard(uuid, text) from public, anon;
revoke all on function public.payroll_run_post(uuid, text) from public, anon;
revoke all on function public.payroll_run_close(uuid, text) from public, anon;
revoke all on function public.payroll_run_reopen(uuid, text, text) from public, anon;
revoke all on function public.payroll_run_correct(uuid, text, date, text) from public, anon;
grant execute on function public.employee_set_tax_opening(uuid, text, integer, integer, text, text, text, text) to authenticated;
grant execute on function public.payroll_run_create(uuid, text, date, date, text) to authenticated;
grant execute on function public.payroll_run_calculate(uuid) to authenticated;
grant execute on function public.payroll_adjustment_add(uuid, text, uuid, text, text, text, boolean) to authenticated;
grant execute on function public.payroll_adjustment_remove(uuid) to authenticated;
grant execute on function public.payroll_run_submit(uuid, text) to authenticated;
grant execute on function public.payroll_run_return(uuid, text) to authenticated;
grant execute on function public.payroll_run_approve(uuid, text) to authenticated;
grant execute on function public.payroll_run_discard(uuid, text) to authenticated;
grant execute on function public.payroll_run_post(uuid, text) to authenticated;
grant execute on function public.payroll_run_close(uuid, text) to authenticated;
grant execute on function public.payroll_run_reopen(uuid, text, text) to authenticated;
grant execute on function public.payroll_run_correct(uuid, text, date, text) to authenticated;
