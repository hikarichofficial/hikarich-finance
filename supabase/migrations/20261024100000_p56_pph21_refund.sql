-- Decision 396 (OWNER, 10 October 2026): the PPh 21 a year over-withheld goes back to the employee through
-- the December payroll, instead of being left for them to reclaim in their own annual return.
--
-- The December recalculation already found the figure: the year's tax against what was withheld month by
-- month, with anything negative reported as `tax_overwithheld` and then dropped (`greatest(v_due, 0)`). Under
-- PPh 21 the excess is the employer's to return, handed over with the bukti potong -- not the employee's to
-- chase at DJP. Decision 394 makes this more common, not less: a mid-year joiner now gets the whole year's
-- PTKP, so their annual tax is often nil while TER has been taking a slice every month.
--
-- The refund is its own figure, not a negative PPh 21. `pph21` stays what was withheld this month (zero, in a
-- month that only refunds), so the per-line invariant `tax_allowance <= pph21` and everything that reads the
-- tax as an amount owed keep their meaning; `tax_refund` carries the money going back. What changes:
--   * net pay rises by the refund -- the employee is paid it with the month's salary;
--   * the journal books Tax Payables NET of it, so a month of refunds debits that account instead of
--     crediting it, which is exactly what returning withheld tax does to the liability;
--   * the determination and the tax ledger carry the same net figure, so the PPh 21 owed for the month -- and
--     the SPT Masa built from it -- is already after the refund;
--   * the payslip shows it, because the employee needs to see why their December is larger.
-- The tax layer is never handed a negative total it has to interpret: only the one netted amount.

alter table public.payroll_run_lines
  add column tax_refund public.money_amount not null default 0 check (tax_refund >= 0);
comment on column public.payroll_run_lines.tax_refund is
  'PPh 21 over-withheld across the year and handed back to the employee in this run (decision 396).';

alter table public.payroll_runs
  add column tax_refund_total public.money_amount not null default 0;

create or replace function app_private.payroll_compute_line(p_in jsonb) returns jsonb
language plpgsql stable set search_path = pg_catalog, public as $$
declare
  c jsonb;
  b jsonb;
  v_p jsonb;
  v_flags text[] := '{}';
  v_info text[] := '{}';
  v_earn numeric := 0;
  v_red numeric := 0;
  v_tax_red numeric := 0;
  v_tax_earn numeric := 0;
  v_wage numeric := 0;
  v_adj_earn numeric := 0;
  v_adj_tax_earn numeric := 0;
  v_adj_red numeric := 0;
  v_adj_tax_red numeric := 0;
  v_gross numeric;
  v_code text;
  v_short text;
  v_base numeric;
  v_emp numeric;
  v_er numeric;
  v_er_rate numeric;
  v_bp jsonb := '{}'::jsonb;
  v_emp_total numeric := 0;
  v_er_total numeric := 0;
  v_er_tax numeric := 0;
  v_pension numeric := 0;
  v_taxable numeric;
  v_mode text;
  v_method text;
  v_tax numeric := 0;
  v_allow numeric := 0;
  v_a numeric := 0;
  v_next numeric;
  v_due jsonb;
  v_i integer;
  v_calc jsonb := '{}'::jsonb;
  v_net numeric;
  v_refund numeric := 0;
  v_ytd jsonb := p_in -> 'ytd';
begin
  -- pay
  for c in select value from jsonb_array_elements(p_in -> 'components') loop
    if c ->> 'kind' = 'earning' then
      v_earn := v_earn + (c ->> 'amount')::numeric;
      if (c ->> 'taxable')::boolean then
        v_tax_earn := v_tax_earn + (c ->> 'amount')::numeric;
      end if;
      if (c ->> 'bpjs_base')::boolean then
        v_wage := v_wage + (c ->> 'amount')::numeric;
      end if;
    else
      v_red := v_red + (c ->> 'amount')::numeric;
      -- Only a deduction marked taxable is less income; the rest come off take-home pay alone (decision 381).
      if (c ->> 'taxable')::boolean then
        v_tax_red := v_tax_red + (c ->> 'amount')::numeric;
      end if;
    end if;
  end loop;
  for c in select value from jsonb_array_elements(p_in -> 'adjustments') loop
    if c ->> 'kind' = 'earning' then
      v_adj_earn := v_adj_earn + (c ->> 'amount')::numeric;
      if (c ->> 'taxable')::boolean then
        v_adj_tax_earn := v_adj_tax_earn + (c ->> 'amount')::numeric;
      end if;
    else
      v_adj_red := v_adj_red + (c ->> 'amount')::numeric;
      if (c ->> 'taxable')::boolean then
        v_adj_tax_red := v_adj_tax_red + (c ->> 'amount')::numeric;
      end if;
    end if;
  end loop;
  if jsonb_array_length(p_in -> 'components') = 0 then
    v_flags := v_flags || 'no_compensation'::text;
  end if;
  v_gross := v_earn + v_adj_earn - v_red - v_adj_red;
  if v_gross < 0 then
    v_flags := v_flags || 'negative_gross_pay'::text;
  end if;
  if (p_in ->> 'joined_in_period')::boolean then
    v_info := v_info || 'joined_during_month'::text;
  end if;
  if (p_in ->> 'exited_in_period')::boolean then
    v_info := v_info || 'left_during_month'::text;
  end if;

  -- BPJS
  for b in select value from jsonb_array_elements(p_in -> 'bpjs') loop
    v_code := b ->> 'component';
    if b ->> 'rule' is null then
      v_flags := v_flags || ('no_bpjs_rule:' || v_code);
      continue;
    end if;
    select params into v_p from public.tax_rule_versions where id = (b ->> 'rule')::uuid;
    if jsonb_typeof(v_p -> 'employer_rate_options') = 'object' then
      v_er_rate := (v_p -> 'employer_rate_options' ->> coalesce(b ->> 'rate_key', ''))::numeric;
      if v_er_rate is null then
        v_flags := v_flags || ('bpjs_rate_option_missing:' || v_code);
        continue;
      end if;
    else
      v_er_rate := (v_p ->> 'employer_rate')::numeric;
    end if;
    v_base := case when jsonb_typeof(v_p -> 'wage_cap') = 'null' then v_wage else least(v_wage, (v_p ->> 'wage_cap')::numeric) end;
    v_emp := app_private.tax_round(v_p, v_base * (v_p ->> 'employee_rate')::numeric);
    v_er := app_private.tax_round(v_p, v_base * v_er_rate);
    v_short := substr(v_code, 6);
    v_bp := v_bp || jsonb_build_object(v_short, jsonb_build_object('emp', v_emp, 'er', v_er));
    v_emp_total := v_emp_total + v_emp;
    v_er_total := v_er_total + v_er;
    if (v_p ->> 'employer_taxable_benefit')::boolean then
      v_er_tax := v_er_tax + v_er;
    end if;
    if (v_p ->> 'employee_pension_deductible')::boolean then
      v_pension := v_pension + v_emp;
    end if;
  end loop;

  -- PPh 21
  v_taxable := greatest(0, v_tax_earn + v_adj_tax_earn - v_tax_red - v_adj_tax_red) + v_er_tax;
  v_mode := case when (p_in ->> 'last_tax_month')::boolean then 'annual' else 'ter' end;
  v_method := p_in -> 'tax' ->> 'method';
  if coalesce(jsonb_typeof(p_in -> 'tax'), 'null') = 'null' or p_in -> 'tax' ->> 'ptkp' = 'unknown' or p_in -> 'tax' ->> 'id_status' = 'unknown' then
    v_flags := v_flags || 'tax_facts_missing'::text;
    v_mode := null;
    v_method := null;
  elsif v_mode = 'ter' and p_in ->> 'ter_rule' is null then
    v_flags := v_flags || 'no_ter_rule'::text;
  elsif v_mode = 'annual' and p_in ->> 'annual_rule' is null then
    v_flags := v_flags || 'no_annual_rule'::text;
  else
    if v_mode = 'annual' then
      if (v_ytd ->> 'missing_months')::integer > 0 then
        v_flags := v_flags || 'ytd_incomplete'::text;
      end if;
      if (v_ytd ->> 'pending_runs')::integer > 0 then
        v_flags := v_flags || 'earlier_run_not_posted'::text;
      end if;
    end if;
    v_due := app_private.payroll_tax_due(p_in, v_taxable, v_pension);
    if v_method = 'gross_up' then
      -- The employer pays the tax as an allowance, which is itself income: solve tax = f(income + tax).
      v_a := 0;
      for v_i in 1 .. 100 loop
        v_due := app_private.payroll_tax_due(p_in, v_taxable + v_a, v_pension);
        v_next := (v_due ->> 'tax')::numeric;
        exit when v_next = v_a;
        v_a := v_next;
        if v_i = 100 then
          v_flags := v_flags || 'gross_up_not_converged'::text;
        end if;
      end loop;
      v_allow := v_a;
      v_tax := v_a;
    else
      v_tax := (v_due ->> 'tax')::numeric;
    end if;
    if (v_due ->> 'overwithheld')::numeric > 0 then
      v_info := v_info || ('tax_overwithheld:' || trim_scale((v_due ->> 'overwithheld')::numeric)::text);
      -- Decision 396: the excess goes back to the employee in this run instead of being left for them to
      -- reclaim in their own annual return. PPh 21 itself stays at zero -- nothing is withheld this month --
      -- and the refund travels as its own figure, so the tax the ledger knows about is never negative.
      v_refund := (v_due ->> 'overwithheld')::numeric;
    end if;
    v_calc := jsonb_build_object('mode', v_mode, 'method', v_method,
      'rule', case when v_mode = 'ter' then p_in ->> 'ter_rule' else p_in ->> 'annual_rule' end,
      'base', app_private.tax_money(v_taxable + v_allow)) || (v_due -> 'detail');
  end if;

  v_net := v_gross - v_emp_total - (v_tax - v_allow) + v_refund;
  if v_net < 0 then
    v_flags := v_flags || 'negative_net_pay'::text;
  end if;
  return jsonb_build_object(
    'review_flags', to_jsonb(v_flags), 'info_flags', to_jsonb(v_info), 'tax_refund', v_refund,
    'earnings_total', v_earn, 'reductions_total', v_red, 'adjustment_earnings', v_adj_earn, 'adjustment_deductions', v_adj_red,
    'gross_pay', v_gross, 'bpjs_wage_base', v_wage,
    'kes_emp', coalesce((v_bp -> 'kes' ->> 'emp')::numeric, 0), 'jht_emp', coalesce((v_bp -> 'jht' ->> 'emp')::numeric, 0),
    'jp_emp', coalesce((v_bp -> 'jp' ->> 'emp')::numeric, 0),
    'kes_er', coalesce((v_bp -> 'kes' ->> 'er')::numeric, 0), 'jht_er', coalesce((v_bp -> 'jht' ->> 'er')::numeric, 0),
    'jp_er', coalesce((v_bp -> 'jp' ->> 'er')::numeric, 0), 'jkk_er', coalesce((v_bp -> 'jkk' ->> 'er')::numeric, 0),
    'jkm_er', coalesce((v_bp -> 'jkm' ->> 'er')::numeric, 0),
    'employer_taxable_benefits', v_er_tax, 'pension_deduction', v_pension,
    'tax_base', v_taxable, 'tax_mode', v_mode, 'tax_method', v_method, 'pph21', v_tax, 'tax_allowance', v_allow,
    'net_pay', v_net, 'tax_calc', v_calc);
end
$$;

create or replace function app_private.payroll_calculate_core(p_run uuid) returns void
language plpgsql set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  e public.employees%rowtype;
  v_in jsonb;
  v_o jsonb;
  v_rules jsonb;
  v_flags text[];
begin
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status not in ('draft', 'calculated') then
    raise exception 'CONFLICT: only a draft or calculated run can be calculated (now %)', r.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if exists (select 1 from public.payroll_adjustments a
             where a.run_id = r.id and not exists (select 1 from app_private.payroll_eligible_employees(r) x where x.id = a.employee_id)) then
    raise exception 'INVALID: an adjustment belongs to an employee who is not part of this payroll month; remove it first'
      using errcode = 'invalid_parameter_value';
  end if;
  update public.payroll_runs set status = 'draft' where id = r.id and status <> 'draft';
  delete from public.payroll_run_lines where run_id = r.id;
  for e in select * from app_private.payroll_eligible_employees(r) loop
    v_in := app_private.payroll_line_inputs(r, e);
    v_o := app_private.payroll_compute_line(v_in);
    insert into public.payroll_run_lines
      (entity_id, run_id, employee_id, review_flags, info_flags, components, earnings_total, reductions_total,
       adjustment_earnings, adjustment_deductions, gross_pay, bpjs_wage_base, bpjs_kes_employee, bpjs_jht_employee,
       bpjs_jp_employee, bpjs_kes_employer, bpjs_jht_employer, bpjs_jp_employer, bpjs_jkk_employer, bpjs_jkm_employer,
       employer_taxable_benefits, pension_deduction, tax_base, tax_mode, tax_method, pph21, tax_allowance, tax_refund,
       net_pay, tax_calc)
    values
      (r.entity_id, r.id, e.id,
       coalesce((select array_agg(x) from jsonb_array_elements_text(v_o -> 'review_flags') x), '{}'),
       coalesce((select array_agg(x) from jsonb_array_elements_text(v_o -> 'info_flags') x), '{}'),
       v_in -> 'components',
       (v_o ->> 'earnings_total')::numeric, (v_o ->> 'reductions_total')::numeric, (v_o ->> 'adjustment_earnings')::numeric,
       (v_o ->> 'adjustment_deductions')::numeric, (v_o ->> 'gross_pay')::numeric, (v_o ->> 'bpjs_wage_base')::numeric,
       (v_o ->> 'kes_emp')::numeric, (v_o ->> 'jht_emp')::numeric, (v_o ->> 'jp_emp')::numeric,
       (v_o ->> 'kes_er')::numeric, (v_o ->> 'jht_er')::numeric, (v_o ->> 'jp_er')::numeric, (v_o ->> 'jkk_er')::numeric,
       (v_o ->> 'jkm_er')::numeric, (v_o ->> 'employer_taxable_benefits')::numeric, (v_o ->> 'pension_deduction')::numeric,
       (v_o ->> 'tax_base')::numeric, v_o ->> 'tax_mode', v_o ->> 'tax_method', (v_o ->> 'pph21')::numeric,
       (v_o ->> 'tax_allowance')::numeric, (v_o ->> 'tax_refund')::numeric, (v_o ->> 'net_pay')::numeric,
       v_o -> 'tax_calc');
  end loop;

  -- The rule versions in force for the month, kept on the run for the audit trail.
  select coalesce(jsonb_agg(jsonb_build_object('code', q.code, 'rule_version', q.rule_version, 'effective_from', q.effective_from)
                            order by q.code), '[]'::jsonb) into v_rules
  from (select distinct (app_private.tax_rule_at(c, r.period_end)).code as code,
               (app_private.tax_rule_at(c, r.period_end)).rule_version as rule_version,
               (app_private.tax_rule_at(c, r.period_end)).effective_from as effective_from
        from unnest(array['PPH21_TER', 'PPH21_ANNUAL', 'BPJS_KES', 'BPJS_JHT', 'BPJS_JP', 'BPJS_JKK', 'BPJS_JKM']) c) q
  where q.code is not null;

  update public.payroll_runs x set
    status = 'calculated', calc_version = x.calc_version + 1, calculated_at = now(),
    input_fingerprint = app_private.payroll_inputs_fingerprint(r.id), rules = v_rules,
    employee_count = (select count(*) from public.payroll_run_lines l where l.run_id = r.id),
    review_count = (select count(*) from public.payroll_run_lines l where l.run_id = r.id and array_length(l.review_flags, 1) is not null),
    tax_base_total = (select coalesce(sum(l.tax_base), 0) from public.payroll_run_lines l where l.run_id = r.id),
    gross_pay_total = (select coalesce(sum(l.gross_pay), 0) from public.payroll_run_lines l where l.run_id = r.id),
    tax_allowance_total = (select coalesce(sum(l.tax_allowance), 0) from public.payroll_run_lines l where l.run_id = r.id),
    employee_bpjs_total = (select coalesce(sum(l.bpjs_kes_employee + l.bpjs_jht_employee + l.bpjs_jp_employee), 0)
                           from public.payroll_run_lines l where l.run_id = r.id),
    employer_bpjs_total = (select coalesce(sum(l.bpjs_kes_employer + l.bpjs_jht_employer + l.bpjs_jp_employer
                                               + l.bpjs_jkk_employer + l.bpjs_jkm_employer), 0)
                           from public.payroll_run_lines l where l.run_id = r.id),
    pph21_total = (select coalesce(sum(l.pph21), 0) from public.payroll_run_lines l where l.run_id = r.id),
    tax_refund_total = (select coalesce(sum(l.tax_refund), 0) from public.payroll_run_lines l where l.run_id = r.id),
    net_pay_total = (select coalesce(sum(l.net_pay), 0) from public.payroll_run_lines l where l.run_id = r.id)
  where x.id = r.id;
end
$$;

create or replace function public.payroll_run_post(p_run uuid, p_key text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_pph_net numeric;
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
  -- What this month actually owes the tax office: the PPh 21 withheld, less anything handed back to
  -- employees whose year turned out to be over-withheld (decision 396). Negative when a December of
  -- refunds outweighs the month's own withholding, which is a debit to Tax Payables, not a credit.
  v_pph_net := r.pph21_total - r.tax_refund_total;

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
  if v_pph_net <> 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'TAX_PAYABLE',
      'debit', greatest(-v_pph_net, 0), 'credit', greatest(v_pph_net, 0),
      'description', case when v_pph_net > 0 then 'PPh 21: ' || v_desc
                          else 'Pengembalian kelebihan potong PPh 21: ' || v_desc end);
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
     app_private.entity_base_currency(r.entity_id), r.tax_base_total, null, v_pph_net, 'payable', r.rules,
     jsonb_build_object('run_number', r.run_number, 'revision', r.revision, 'employee_count', r.employee_count),
     app_private.tax_trace_add(app_private.tax_trace_add('[]'::jsonb,
       format('PPh 21 of payroll %s for %s was computed per employee from the rule versions listed', r.run_number, to_char(r.period_start, 'YYYY-MM'))),
       'Per-employee amounts stay in the payroll module; the tax ledger holds the total'),
     jsonb_build_array(
       jsonb_build_object('name', 'withheld_from_employees', 'amount', app_private.tax_money(r.pph21_total - r.tax_allowance_total)),
       jsonb_build_object('name', 'borne_by_employer_as_allowance', 'amount', app_private.tax_money(r.tax_allowance_total)),
       jsonb_build_object('name', 'refunded_to_employees', 'amount', app_private.tax_money(r.tax_refund_total))),
     case when v_pph_net > 0
       then format('%s is credited to Tax Payables and accrues in the PPh 21 ledger for %s; it is settled through a tax payment.',
                   trim_scale(v_pph_net), to_char(r.period_start, 'YYYY-MM'))
       when v_pph_net < 0
       then format('%s was handed back to employees who had been over-withheld over the year, so the PPh 21 of %s is reduced by that much.',
                   trim_scale(-v_pph_net), to_char(r.period_start, 'YYYY-MM'))
       else 'No PPh 21 is due for this payroll month.' end,
     v_journal, false)
  returning id into v_det;
  if v_pph_net <> 0 then
    insert into public.tax_ledger_entries
      (entity_id, determination_id, tax_kind, tax_type, tax_period, direction, entry_kind, amount, entry_date, journal_id, description)
    values (r.entity_id, v_det, 'wht_pph21', 'wht_pph21', r.period_start, 'payable', 'accrual', v_pph_net, v_date, v_journal,
            left(case when v_pph_net > 0 then 'PPh 21 payroll ' else 'Pengembalian kelebihan potong PPh 21 payroll ' end
                 || to_char(r.period_start, 'YYYY-MM'), 300));
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
                                'withheld_from_employee', app_private.tax_money(l.pph21 - l.tax_allowance),
                                'refund', app_private.tax_money(l.tax_refund)),
      'tax_refund', app_private.tax_money(l.tax_refund),
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

create or replace function app_private.payroll_run_differences(p_run uuid) returns jsonb
language plpgsql stable set search_path = pg_catalog, public as $$
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
         coalesce(sum(l.gross_pay - (l.bpjs_kes_employee + l.bpjs_jht_employee + l.bpjs_jp_employee) - (l.pph21 - l.tax_allowance) + l.tax_refund - l.net_pay), 0) as netdiff,
         coalesce(sum(l.tax_refund), 0) as refund
    into v_lines
  from public.payroll_run_lines l where l.run_id = p_run;
  if v_lines.refund <> r.tax_refund_total then
    v_out := v_out || jsonb_build_object('code', 'tax_refund_differs', 'text', 'The PPh 21 refunded in the lines differs from the run');
  end if;
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
    -- Netted, because a December of refunds debits Tax Payables instead of crediting it (decision 396).
    select coalesce(sum(jl.credit) filter (where a.system_key = 'TAX_PAYABLE'), 0)
           - coalesce(sum(jl.debit) filter (where a.system_key = 'TAX_PAYABLE'), 0) into v_credit
    from public.journal_lines jl join public.ledger_accounts a on a.id = jl.ledger_account_id and a.entity_id = jl.entity_id
    where jl.journal_id = r.journal_id;
    if v_credit <> r.pph21_total - r.tax_refund_total then
      v_out := v_out || jsonb_build_object('code', 'tax_payable_differs', 'text', 'PPh 21 in the journal differs from the run');
    end if;
    if r.status <> 'corrected' then
      select coalesce(sum(d.tax_amount), 0) into v_tax from public.tax_determinations d
      where d.entity_id = r.entity_id and d.source_type = 'payroll_run' and d.source_id = r.id and d.superseded_at is null;
      if v_tax <> r.pph21_total - r.tax_refund_total then
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

-- The returned row gains a column, so the old function goes first; the grants are restated after it.
drop function public.payroll_run_lines(uuid);
create function public.payroll_run_lines(p_run uuid)
returns table (line_id uuid, employee_id uuid, employee_code text, employee_name text, review_flags text[], info_flags text[],
               earnings_total text, reductions_total text, adjustment_earnings text, adjustment_deductions text, gross_pay text,
               bpjs_wage_base text, bpjs_employee text, bpjs_employer text, tax_base text, tax_mode text, tax_method text,
               pph21 text, tax_allowance text, tax_refund text, net_pay text, net_paid text, tax_calc jsonb)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_tax boolean;
begin
  select * into r from public.payroll_runs where id = p_run;
  perform app_private.payroll_read_authorize(r.entity_id, 'the lines of a payroll run');
  v_tax := app_authz.has_permission(r.entity_id, 'payroll.tax_view');
  return query
  select l.id, l.employee_id, e.employee_code, e.full_name, l.review_flags, l.info_flags, l.earnings_total::text, l.reductions_total::text,
         l.adjustment_earnings::text, l.adjustment_deductions::text, l.gross_pay::text, l.bpjs_wage_base::text,
         (l.bpjs_kes_employee + l.bpjs_jht_employee + l.bpjs_jp_employee)::text,
         (l.bpjs_kes_employer + l.bpjs_jht_employer + l.bpjs_jp_employer + l.bpjs_jkk_employer + l.bpjs_jkm_employer)::text,
         case when v_tax then l.tax_base::text end, case when v_tax then l.tax_mode end, case when v_tax then l.tax_method end,
         case when v_tax then l.pph21::text end, case when v_tax then l.tax_allowance::text end,
         l.tax_refund::text, l.net_pay::text, app_private.payroll_line_paid(l.id)::text, case when v_tax then l.tax_calc end
  from public.payroll_run_lines l
  join public.employees e on e.id = l.employee_id and e.entity_id = l.entity_id
  where l.run_id = r.id
  order by e.employee_code;
end
$$;

revoke all on function public.payroll_run_lines(uuid) from public, anon;
grant execute on function public.payroll_run_lines(uuid) to authenticated;
