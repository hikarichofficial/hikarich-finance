-- P9 part 8: reading payroll, the reports and the payroll control.
-- Authority: Step 06 §6 (sensitive boundary: the payroll tables are closed; these RPCs are the only way to read them),
-- Step 12 §12 (payroll reports: summary, employee history permission-gated, liabilities, payroll tax, GL reconciliation;
-- sensitive reports excluded from general report discovery), Step 08 §13/§19, Step 16 §18.
--
-- Rules that hold for every read below:
--   * money is shown only to someone with payroll.compensation_view AND a payroll working capability (payroll.run,
--     payroll.approve or payroll.pay); the tax fields of a line need payroll.tax_view as well and come back empty
--     without it - so nobody infers a person's tax from the net pay they are allowed to see;
--   * an unauthorised caller gets FORBIDDEN, never an empty list that would confirm a run exists;
--   * amounts are exact decimal text; nothing is computed in the browser.

create function app_private.payroll_read_authorize(p_entity uuid, p_what text) returns void
language plpgsql stable as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_entity is null or not app_authz.has_permission(p_entity, 'payroll.compensation_view')
     or not (app_authz.has_permission(p_entity, 'payroll.run') or app_authz.has_permission(p_entity, 'payroll.approve')
             or app_authz.has_permission(p_entity, 'payroll.pay')) then
    raise exception 'FORBIDDEN: % needs payroll.compensation_view and a payroll capability (run, approve or pay)', p_what
      using errcode = 'insufficient_privilege';
  end if;
  if (select e.entity_type from public.entities e where e.id = p_entity) <> 'company' then
    raise exception 'INVALID: payroll exists for a company Entity only' using errcode = 'invalid_parameter_value';
  end if;
end
$$;

-- ------------------------------------------------------------ runs
create function public.payroll_run_list(p_entity uuid, p_status text default null, p_limit integer default 100)
returns table (run_id uuid, run_number text, revision integer, period_start date, period_end date, pay_date date, status text,
               employee_count integer, review_count integer, gross_pay_total text, tax_allowance_total text,
               employee_bpjs_total text, employer_bpjs_total text, pph21_total text, net_pay_total text, net_paid text,
               bpjs_paid text, journal_id uuid, corrects_run_id uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.payroll_read_authorize(p_entity, 'the payroll run list');
  return query
  select r.id, r.run_number, r.revision, r.period_start, r.period_end, r.pay_date, r.status, r.employee_count, r.review_count,
         r.gross_pay_total::text, r.tax_allowance_total::text, r.employee_bpjs_total::text, r.employer_bpjs_total::text,
         case when app_authz.has_permission(p_entity, 'payroll.tax_view') then r.pph21_total::text end,
         r.net_pay_total::text, app_private.payroll_net_paid(r.id)::text, app_private.payroll_bpjs_paid(r.id)::text,
         r.journal_id, r.corrects_run_id
  from public.payroll_runs r
  where r.entity_id = p_entity and (p_status is null or r.status = p_status)
  order by r.period_start desc, r.revision desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end
$$;

create function public.payroll_run_get(p_run uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
  v_tax boolean;
begin
  select * into r from public.payroll_runs where id = p_run;
  perform app_private.payroll_read_authorize(r.entity_id, 'a payroll run');
  v_tax := app_authz.has_permission(r.entity_id, 'payroll.tax_view');
  return jsonb_build_object(
    'run_id', r.id, 'run_number', r.run_number, 'revision', r.revision, 'period_start', r.period_start, 'period_end', r.period_end,
    'pay_date', r.pay_date, 'status', r.status, 'corrects_run_id', r.corrects_run_id, 'calc_version', r.calc_version,
    'calculated_at', r.calculated_at, 'employee_count', r.employee_count, 'review_count', r.review_count,
    'gross_pay_total', r.gross_pay_total::text, 'tax_allowance_total', case when v_tax then r.tax_allowance_total::text end,
    'employee_bpjs_total', r.employee_bpjs_total::text, 'employer_bpjs_total', r.employer_bpjs_total::text,
    'pph21_total', case when v_tax then r.pph21_total::text end, 'tax_base_total', case when v_tax then r.tax_base_total::text end,
    'net_pay_total', r.net_pay_total::text, 'net_paid', app_private.payroll_net_paid(r.id)::text,
    'bpjs_paid', app_private.payroll_bpjs_paid(r.id)::text, 'rules', r.rules, 'note', r.note,
    'submitted_at', r.submitted_at, 'approved_at', r.approved_at, 'posted_at', r.posted_at, 'posting_date', r.posting_date,
    'journal_id', r.journal_id, 'reversal_journal_id', r.reversal_journal_id, 'closed_at', r.closed_at,
    'corrected_at', r.corrected_at, 'correction_reason', r.correction_reason,
    -- A run that was calculated is stale when its inputs have changed since.
    'stale', r.status in ('calculated', 'submitted', 'approved') and r.input_fingerprint is distinct from app_private.payroll_inputs_fingerprint(r.id),
    'differences', case when r.journal_id is not null then app_private.payroll_run_differences(r.id) else '[]'::jsonb end);
end
$$;

create function public.payroll_run_lines(p_run uuid)
returns table (line_id uuid, employee_id uuid, employee_code text, employee_name text, review_flags text[], info_flags text[],
               earnings_total text, reductions_total text, adjustment_earnings text, adjustment_deductions text, gross_pay text,
               bpjs_wage_base text, bpjs_employee text, bpjs_employer text, tax_base text, tax_mode text, tax_method text,
               pph21 text, tax_allowance text, net_pay text, net_paid text, tax_calc jsonb)
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
         l.net_pay::text, app_private.payroll_line_paid(l.id)::text, case when v_tax then l.tax_calc end
  from public.payroll_run_lines l
  join public.employees e on e.id = l.employee_id and e.entity_id = l.entity_id
  where l.run_id = r.id
  order by e.employee_code;
end
$$;

create function public.payroll_adjustments_list(p_run uuid)
returns table (adjustment_id uuid, employee_id uuid, employee_code text, kind text, label text, amount text, taxable boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
begin
  select * into r from public.payroll_runs where id = p_run;
  perform app_private.payroll_read_authorize(r.entity_id, 'the adjustments of a payroll run');
  return query
  select a.id, a.employee_id, e.employee_code, a.kind, a.label, a.amount::text, a.taxable
  from public.payroll_adjustments a join public.employees e on e.id = a.employee_id and e.entity_id = a.entity_id
  where a.run_id = r.id order by e.employee_code, a.kind, a.label;
end
$$;

-- ------------------------------------------------------------ payments
create function public.payroll_payments_list(p_run uuid)
returns table (payment_id uuid, payment_number text, kind text, status text, payment_date date, amount text,
               financial_account_id uuid, reference text, journal_id uuid, reversal_journal_id uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  r public.payroll_runs%rowtype;
begin
  select * into r from public.payroll_runs where id = p_run;
  perform app_private.payroll_read_authorize(r.entity_id, 'the payments of a payroll run');
  return query
  select p.id, p.payment_number, p.kind, p.status, p.payment_date, p.amount::text, p.financial_account_id, p.reference,
         p.journal_id, p.reversal_journal_id
  from public.payroll_payments p where p.run_id = r.id order by p.payment_date desc, p.payment_number desc;
end
$$;

-- ------------------------------------------------------------ payslips
create function public.payroll_payslip_list(p_entity uuid, p_run uuid default null, p_employee uuid default null, p_limit integer default 100)
returns table (payslip_id uuid, payslip_number text, status text, run_id uuid, employee_id uuid, employee_code text, employee_name text,
               period text, net_pay text, issued_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.payroll_read_authorize(p_entity, 'payslips');
  return query
  select s.id, s.payslip_number, s.status, s.run_id, s.employee_id, e.employee_code, e.full_name, s.snapshot ->> 'period',
         s.snapshot ->> 'net_pay', s.issued_at
  from public.payroll_payslips s join public.employees e on e.id = s.employee_id and e.entity_id = s.entity_id
  where s.entity_id = p_entity and (p_run is null or s.run_id = p_run) and (p_employee is null or s.employee_id = p_employee)
  order by s.issued_at desc, s.payslip_number desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end
$$;

-- The payslip as it was issued; its tax section needs payroll.tax_view.
create function public.payroll_payslip_get(p_payslip uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  s public.payroll_payslips%rowtype;
begin
  select * into s from public.payroll_payslips where id = p_payslip;
  perform app_private.payroll_read_authorize(s.entity_id, 'a payslip');
  return s.snapshot - case when app_authz.has_permission(s.entity_id, 'payroll.tax_view') then '' else 'tax' end
         || jsonb_build_object('status', s.status, 'issued_at', s.issued_at, 'voided_at', s.voided_at, 'void_reason', s.void_reason,
                               'net_paid', app_private.payroll_line_paid(s.run_line_id)::text);
end
$$;

-- ------------------------------------------------------------ employee tax ledger and the annual reconciliation
-- One row per payroll line (and per opening figure) of an employee for a tax year: the employee tax ledger of Step 01 #24.
create function public.payroll_employee_tax_ledger(p_entity uuid, p_year integer, p_employee uuid default null)
returns table (employee_id uuid, employee_code text, employee_name text, tax_period date, source text, run_number text,
               tax_base text, tax_mode text, pph21 text, tax_allowance text, pension_deduction text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.payroll_read_authorize(p_entity, 'the employee tax ledger');
  if not app_authz.has_permission(p_entity, 'payroll.tax_view') then
    raise exception 'FORBIDDEN: the employee tax ledger needs payroll.tax_view' using errcode = 'insufficient_privilege';
  end if;
  if p_year is null or p_year not between 2000 and 2100 then
    raise exception 'INVALID: a tax year is required' using errcode = 'invalid_parameter_value';
  end if;
  return query
  select q.employee_id, q.employee_code, q.full_name, q.tax_period, q.source, q.run_number, q.tax_base::text, q.tax_mode, q.pph21::text,
         q.tax_allowance::text, q.pension::text
  from (
    select l.employee_id, e.employee_code, e.full_name, r.period_start as tax_period, 'run'::text as source, r.run_number,
           l.tax_base, l.tax_mode, l.pph21, l.tax_allowance, l.pension_deduction as pension
    from public.payroll_run_lines l
    join public.payroll_runs r on r.id = l.run_id and r.entity_id = l.entity_id
    join public.employees e on e.id = l.employee_id and e.entity_id = l.entity_id
    where l.entity_id = p_entity and extract(year from r.period_start) = p_year
      and r.status in ('posted', 'partially_paid', 'paid', 'closed') and (p_employee is null or l.employee_id = p_employee)
    union all
    select o.employee_id, e.employee_code, e.full_name, make_date(o.tax_year, o.through_month, 1), 'opening', null,
           o.taxable_gross, null, o.pph21_withheld, 0::numeric, o.pension_deduction
    from public.employee_tax_openings o
    join public.employees e on e.id = o.employee_id and e.entity_id = o.entity_id
    where o.entity_id = p_entity and o.tax_year = p_year and (p_employee is null or o.employee_id = p_employee)
      and o.revision = (select max(x.revision) from public.employee_tax_openings x where x.employee_id = o.employee_id and x.tax_year = o.tax_year)
  ) q
  order by q.employee_code, q.tax_period, q.source;
end
$$;

-- The tax year of each employee side by side with the annual computation of the rule in force at the end of the year:
-- what should have been withheld for the months worked, against what was withheld. It is a check for the tax adviser and
-- the owner; the last tax month of the payroll makes the same computation when it withholds.
create function public.payroll_annual_reconciliation(p_entity uuid, p_year integer)
returns table (employee_id uuid, employee_code text, employee_name text, months_worked integer, gross_income text,
               annual_tax text, withheld text, difference text, status text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  t public.employee_tax_profiles%rowtype;
  v_rule jsonb;
  v_gross numeric;
  v_pension numeric;
  v_withheld numeric;
  v_first integer;
  v_last integer;
  v_months integer;
  v_a jsonb;
  v_end date := make_date(p_year, 12, 31);
begin
  perform app_private.payroll_read_authorize(p_entity, 'the annual payroll tax reconciliation');
  if not app_authz.has_permission(p_entity, 'payroll.tax_view') then
    raise exception 'FORBIDDEN: the annual reconciliation needs payroll.tax_view' using errcode = 'insufficient_privilege';
  end if;
  if p_year is null or p_year not between 2000 and 2100 then
    raise exception 'INVALID: a tax year is required' using errcode = 'invalid_parameter_value';
  end if;
  select params into v_rule from public.tax_rule_versions where id = (app_private.tax_rule_at('PPH21_ANNUAL', v_end)).id;
  for e in select x.* from public.employees x
           where x.entity_id = p_entity and x.join_date <= v_end and (x.exit_date is null or x.exit_date >= make_date(p_year, 1, 1))
           order by x.employee_code loop
    employee_id := e.id; employee_code := e.employee_code; employee_name := e.full_name;
    select coalesce(sum(q.gross), 0), coalesce(sum(q.pension), 0), coalesce(sum(q.tax), 0)
      into v_gross, v_pension, v_withheld
    from (
      select l.tax_base + l.tax_allowance as gross, l.pension_deduction as pension, l.pph21 as tax
      from public.payroll_run_lines l join public.payroll_runs r on r.id = l.run_id and r.entity_id = l.entity_id
      where l.entity_id = p_entity and l.employee_id = e.id and extract(year from r.period_start) = p_year
        and r.status in ('posted', 'partially_paid', 'paid', 'closed')
      union all
      select o.taxable_gross, o.pension_deduction, o.pph21_withheld
      from public.employee_tax_openings o
      where o.entity_id = p_entity and o.employee_id = e.id and o.tax_year = p_year
        and o.revision = (select max(x.revision) from public.employee_tax_openings x where x.employee_id = o.employee_id and x.tax_year = o.tax_year)
    ) q;
    v_first := case when extract(year from e.join_date) = p_year then extract(month from e.join_date)::integer else 1 end;
    v_last := case when e.exit_date is not null and extract(year from e.exit_date) = p_year then extract(month from e.exit_date)::integer else 12 end;
    v_months := v_last - v_first + 1;
    months_worked := v_months;
    gross_income := trim_scale(v_gross)::text;
    withheld := trim_scale(v_withheld)::text;
    t := app_private.employee_tax_at(e.id, least(v_end, coalesce(e.exit_date, v_end)));
    if v_rule is null or t.id is null or t.ptkp_status = 'unknown' or t.tax_id_status = 'unknown' then
      annual_tax := null; difference := null; status := 'incomplete';
    else
      v_a := app_private.pph21_annual(v_rule, t.ptkp_status, t.tax_id_status = 'no_tax_id', v_gross, v_pension, v_months);
      annual_tax := v_a ->> 'annual_tax';
      difference := trim_scale((v_a ->> 'annual_tax')::numeric - v_withheld)::text;
      status := case when (v_a ->> 'annual_tax')::numeric = v_withheld then 'reconciled'
                     when (v_a ->> 'annual_tax')::numeric > v_withheld then 'under_withheld' else 'over_withheld' end;
    end if;
    return next;
  end loop;
end
$$;

-- ------------------------------------------------------------ reports
create function public.payroll_summary_report(p_entity uuid, p_from date default null, p_to date default null)
returns table (run_id uuid, run_number text, revision integer, period_start date, status text, employee_count integer,
               gross_pay text, tax_allowance text, employee_bpjs text, employer_bpjs text, pph21 text, net_pay text,
               net_unpaid text, bpjs_unpaid text, pph21_period_outstanding text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_today date;
begin
  perform app_private.payroll_read_authorize(p_entity, 'the payroll summary');
  v_today := app_private.entity_today(p_entity);
  return query
  select r.id, r.run_number, r.revision, r.period_start, r.status, r.employee_count, r.gross_pay_total::text,
         case when app_authz.has_permission(p_entity, 'payroll.tax_view') then r.tax_allowance_total::text end,
         r.employee_bpjs_total::text, r.employer_bpjs_total::text,
         case when app_authz.has_permission(p_entity, 'payroll.tax_view') then r.pph21_total::text end, r.net_pay_total::text,
         case when r.status in ('posted', 'partially_paid', 'paid', 'closed')
              then (r.net_pay_total - app_private.payroll_net_paid(r.id))::text end,
         case when r.status in ('posted', 'partially_paid', 'paid', 'closed')
              then (r.employee_bpjs_total + r.employer_bpjs_total - app_private.payroll_bpjs_paid(r.id))::text end,
         case when app_authz.has_permission(p_entity, 'payroll.tax_view') and r.status in ('posted', 'partially_paid', 'paid', 'closed')
              then (select (a.accrued_payable - a.paid_payable)::text from app_private.tax_period_amounts(p_entity, 'wht_pph21', r.period_start, v_today) a) end
  from public.payroll_runs r
  where r.entity_id = p_entity and r.status not in ('discarded')
    and (p_from is null or r.period_start >= date_trunc('month', p_from)::date)
    and (p_to is null or r.period_start <= p_to)
  order by r.period_start desc, r.revision desc;
end
$$;

-- What is still owed to employees, BPJS and (PPh 21) the tax office, as of a date.
create function public.payroll_liability_report(p_entity uuid, p_as_of date default null)
returns table (liability text, period_start date, run_number text, owed text, paid text, outstanding text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_asof date;
begin
  perform app_private.payroll_read_authorize(p_entity, 'the payroll liabilities');
  v_asof := coalesce(p_as_of, app_private.entity_today(p_entity));
  return query
  select 'net_pay'::text, r.period_start, r.run_number, r.net_pay_total::text,
         coalesce((select sum(p.amount) from public.payroll_payments p where p.run_id = r.id and p.kind = 'net_pay'
                   and p.payment_date <= v_asof and (p.status = 'confirmed' or p.reversed_date > v_asof)), 0)::text,
         (r.net_pay_total - coalesce((select sum(p.amount) from public.payroll_payments p where p.run_id = r.id and p.kind = 'net_pay'
                   and p.payment_date <= v_asof and (p.status = 'confirmed' or p.reversed_date > v_asof)), 0))::text
  from public.payroll_runs r
  where r.entity_id = p_entity and r.journal_id is not null and r.posting_date <= v_asof
    and (r.reversal_journal_id is null or (select j.entry_date from public.journal_entries j where j.id = r.reversal_journal_id) > v_asof)
  union all
  select 'bpjs', r.period_start, r.run_number, (r.employee_bpjs_total + r.employer_bpjs_total)::text,
         coalesce((select sum(p.amount) from public.payroll_payments p where p.run_id = r.id and p.kind = 'bpjs'
                   and p.payment_date <= v_asof and (p.status = 'confirmed' or p.reversed_date > v_asof)), 0)::text,
         (r.employee_bpjs_total + r.employer_bpjs_total - coalesce((select sum(p.amount) from public.payroll_payments p
                   where p.run_id = r.id and p.kind = 'bpjs' and p.payment_date <= v_asof
                     and (p.status = 'confirmed' or p.reversed_date > v_asof)), 0))::text
  from public.payroll_runs r
  where r.entity_id = p_entity and r.journal_id is not null and r.posting_date <= v_asof
    and (r.reversal_journal_id is null or (select j.entry_date from public.journal_entries j where j.id = r.reversal_journal_id) > v_asof)
    and r.employee_bpjs_total + r.employer_bpjs_total > 0
  order by 2 desc, 1, 3;
  if app_authz.has_permission(p_entity, 'payroll.tax_view') then
    return query
    select 'pph21'::text, m.period, null::text, a.accrued_payable::text, a.paid_payable::text, (a.accrued_payable - a.paid_payable)::text
    from (select distinct e.tax_period as period from public.tax_ledger_entries e
          where e.entity_id = p_entity and e.tax_type = 'wht_pph21' and e.tax_period <= v_asof) m
    cross join lateral app_private.tax_period_amounts(p_entity, 'wht_pph21', m.period, v_asof) a
    order by m.period desc;
  end if;
end
$$;

-- ------------------------------------------------------------ the payroll control against the General Ledger
-- Payroll journals (a run and its correction, a payment and its reversal) take part in the comparison; anything else posted
-- to the payroll accounts (an opening balance) is shown in the "other" column so the control never hides it. PPh 21 sits in
-- the tax control (its journals are tax journals).
create function app_private.is_payroll_journal(p_journal uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.journal_entries j
    where j.id = p_journal
      and (j.source_type in ('payroll_run', 'payroll_payment')
           or exists (select 1 from public.journal_entries o
                      where o.id = j.reverses_journal_id and o.source_type in ('payroll_run', 'payroll_payment'))))
$$;

create function app_private.payroll_control(p_entity uuid, p_as_of date default null)
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
  v_bpjs := v_bpjs - coalesce((select sum(p.amount) from public.payroll_payments p where p.entity_id = p_entity and p.kind = 'bpjs'
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
  where l.entity_id = p_entity and a.system_key = 'BPJS_LIABILITY' and j.status = 'posted' and j.entry_date <= v_asof;

  return query
  select 'PAYROLL_LIABILITY'::text, v_net, v_net_w, v_net_l - v_net_w, v_net_l
  union all
  select 'BPJS_LIABILITY'::text, v_bpjs, v_bpjs_w, v_bpjs_l - v_bpjs_w, v_bpjs_l;
end
$$;

create function public.payroll_control_report(p_entity uuid, p_as_of date default null)
returns table (account_key text, sub_ledger text, ledger_workflow text, ledger_other text, ledger_total text, difference text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.payroll_read_authorize(p_entity, 'the payroll control');
  if not app_authz.has_permission(p_entity, 'accounting.view') then
    raise exception 'FORBIDDEN: the payroll control needs accounting.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select c.account_key, c.sub_ledger::text, c.ledger_workflow::text, c.ledger_other::text, c.ledger_total::text,
         (c.sub_ledger - c.ledger_workflow)::text
  from app_private.payroll_control(p_entity, p_as_of) c;
end
$$;

-- ------------------------------------------------------------ the period close, with the payroll checks
create or replace function app_private.period_blockers(p_period uuid)
returns table (code text, severity text, message text, item_count bigint)
language plpgsql stable as $$
declare
  v_p public.accounting_periods%rowtype;
  v_n bigint;
begin
  select * into v_p from public.accounting_periods where id = p_period;
  if not found then
    raise exception 'INVALID: unknown accounting period' using errcode = 'invalid_parameter_value';
  end if;

  select count(*) into v_n from public.journal_entries j where j.period_id = p_period and j.status = 'draft';
  if v_n > 0 then
    return query select 'draft_journals'::text, 'blocker'::text,
      'Draft journals exist in this period and must be posted or discarded'::text, v_n;
  end if;

  -- Detective control: posted journals are balanced by construction; a mismatch means corruption.
  select count(*) into v_n from (
    select j.id
    from public.journal_entries j
    join public.journal_lines l on l.journal_id = j.id
    where j.period_id = p_period and j.status = 'posted'
    group by j.id
    having sum(l.debit) <> sum(l.credit)
  ) q;
  if v_n > 0 then
    return query select 'unbalanced_posted_journals'::text, 'blocker'::text,
      'Posted journals with debit different from credit were found'::text, v_n;
  end if;

  -- Migration must be signed off before normal production posting (Step 15 §24).
  select count(*) into v_n
  from public.opening_balance_batches b
  where b.entity_id = v_p.entity_id and b.status = 'posted'
    and b.cutover_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'opening_not_completed'::text, 'blocker'::text,
      'Opening balances in this period have not been completed and signed off'::text, v_n;
  end if;

  select count(*) into v_n from public.journal_entries j where j.period_id = p_period and j.status = 'posted';
  if v_n = 0 then
    return query select 'empty_period'::text, 'warning'::text,
      'The period has no posted journals'::text, 0::bigint;
  end if;

  -- Money layer against the General Ledger, as of the end of the period (Step 04 §13).
  select count(*) into v_n from app_private.money_control_rows(v_p.entity_id, v_p.period_end) r
  where r.ledger_balance <> r.movement_base_balance;
  if v_n > 0 then
    return query select 'money_ledger_mismatch'::text, 'blocker'::text,
      'Cash/bank balances from money movements differ from the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from app_private.money_control_rows(v_p.entity_id, v_p.period_end) r
  where r.movement_balance < 0;
  if v_n > 0 then
    return query select 'negative_cash_balance'::text, 'warning'::text,
      'A cash/bank account has a negative balance at the end of the period'::text, v_n;
  end if;

  select count(*) into v_n
  from public.statement_lines l
  join public.reconciliation_sessions s on s.id = l.session_id and s.status in ('open', 'reopened')
  where l.entity_id = v_p.entity_id and l.line_date between v_p.period_start and v_p.period_end
    and not l.is_excluded
    and not exists (select 1 from public.reconciliation_matches m where m.statement_line_id = l.id);
  if v_n > 0 then
    return query select 'unresolved_statement_lines'::text, 'warning'::text,
      'Bank statement lines of this period are neither matched nor excluded'::text, v_n;
  end if;

  select count(*) into v_n
  from public.financial_accounts fa
  where fa.entity_id = v_p.entity_id and fa.is_active
    and exists (select 1 from public.money_movements mv
                where mv.financial_account_id = fa.id and mv.movement_date between v_p.period_start and v_p.period_end
                  and mv.source_type <> 'opening_balance')
    and not exists (select 1 from public.reconciliation_sessions s
                    where s.financial_account_id = fa.id and s.status = 'reconciled' and s.period_end >= v_p.period_end);
  if v_n > 0 then
    return query select 'account_not_reconciled'::text, 'warning'::text,
      'Active cash/bank accounts with movements in this period are not reconciled up to its end'::text, v_n;
  end if;

  -- A completed reconciliation whose book balance no longer matches what it recorded: something was booked
  -- inside the reconciled window afterwards, so its evidence is stale.
  select count(*) into v_n
  from public.reconciliation_sessions s
  where s.entity_id = v_p.entity_id and s.status = 'reconciled'
    and s.period_start <= v_p.period_end and s.period_end >= v_p.period_start
    and s.system_book_balance is distinct from app_private.account_balance(s.financial_account_id, s.period_end);
  if v_n > 0 then
    return query select 'reconciliation_stale'::text, 'warning'::text,
      'A completed reconciliation no longer matches the books: movements were added inside its period afterwards'::text, v_n;
  end if;

  -- Cash/bank ledger accounts with postings but no financial account are invisible to the money control.
  select count(distinct a.id) into v_n
  from public.ledger_accounts a
  join public.journal_lines l on l.ledger_account_id = a.id
  join public.journal_entries j on j.id = l.journal_id and j.status = 'posted' and j.period_id = p_period
  where a.entity_id = v_p.entity_id and app_private.is_cash_ledger_account(v_p.entity_id, a.id)
    and not exists (select 1 from public.financial_accounts fa where fa.ledger_account_id = a.id);
  if v_n > 0 then
    return query select 'unmapped_cash_account'::text, 'warning'::text,
      'Cash/bank ledger accounts with postings in this period have no financial account, so the money layer cannot check them'::text, v_n;
  end if;
  -- Sales sub-ledgers against the General Ledger, as of the end of the period (Step 04 §13). Only journals the sales
  -- workflow produced take part; opening balances and other sources are shown separately in the AR control report.
  select count(*) into v_n from app_private.ar_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_sales;
  if v_n > 0 then
    return query select 'ar_ledger_mismatch'::text, 'blocker'::text,
      'Accounts receivable from invoices and payments differs from the General Ledger'::text, v_n;
  end if;
  select count(*) into v_n from app_private.ar_control(v_p.entity_id, v_p.period_end) c
  where c.advance_sub_ledger <> c.advance_ledger_sales;
  if v_n > 0 then
    return query select 'advance_ledger_mismatch'::text, 'blocker'::text,
      'Customer advances from payments differ from the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from public.invoices i
  where i.entity_id = v_p.entity_id and i.status = 'draft' and i.issue_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'draft_invoices'::text, 'warning'::text,
      'Draft invoices dated in this period are not issued yet and are not in the books'::text, v_n;
  end if;

  select count(*) into v_n from public.payment_submissions s
  where s.entity_id = v_p.entity_id and s.status = 'pending' and s.payment_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'pending_payment_claims'::text, 'warning'::text,
      'Customer payment claims dated in this period are still waiting for verification'::text, v_n;
  end if;

  -- Purchase sub-ledger against the General Ledger, as of the end of the period (Step 04 §13). Only journals the
  -- purchase workflow produced take part; opening balances and other sources are shown separately in the AP control.
  select count(*) into v_n from app_private.ap_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_purchases;
  if v_n > 0 then
    return query select 'ap_ledger_mismatch'::text, 'blocker'::text,
      'Accounts payable from bills and vendor payments differs from the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from public.bills b
  where b.entity_id = v_p.entity_id and b.status in ('draft', 'submitted')
    and b.bill_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'unapproved_bills'::text, 'warning'::text,
      'Draft or submitted bills dated in this period are not approved yet and are not in the books'::text, v_n;
  end if;

  select count(*) into v_n from public.expenses x
  where x.entity_id = v_p.entity_id and x.status in ('draft', 'submitted')
    and x.expense_date between v_p.period_start and v_p.period_end;
  if v_n > 0 then
    return query select 'unconfirmed_expenses'::text, 'warning'::text,
      'Draft or submitted expenses dated in this period are not confirmed yet and are not in the books'::text, v_n;
  end if;

  -- Recognised purchases with no evidence attached (Step 08 §17): worth a look before closing, never a block.
  select count(*) into v_n from (
    select b.id from public.bills b
    where b.entity_id = v_p.entity_id and b.status = 'approved'
      and b.bill_date between v_p.period_start and v_p.period_end
      and not exists (select 1 from public.document_links l
                      where l.entity_id = b.entity_id and l.target_type = 'bill' and l.target_id = b.id and l.status = 'active')
    union all
    select x.id from public.expenses x
    where x.entity_id = v_p.entity_id and x.status = 'confirmed'
      and x.expense_date between v_p.period_start and v_p.period_end
      and not exists (select 1 from public.document_links l
                      where l.entity_id = x.entity_id and l.target_type = 'expense' and l.target_id = x.id and l.status = 'active')
  ) q;
  if v_n > 0 then
    return query select 'purchases_without_evidence'::text, 'warning'::text,
      'Bills and expenses of this period have no supporting document attached'::text, v_n;
  end if;

  -- Tax ledger against Tax Payable and Tax Asset in the General Ledger, as of the end of the period (Step 08 §19).
  -- Only journals the tax workflow produced take part; other postings to the tax accounts are shown in the tax control.
  select count(*) into v_n from app_private.tax_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_workflow;
  if v_n > 0 then
    return query select 'tax_ledger_mismatch'::text, 'blocker'::text,
      'The tax ledger differs from Tax Payable / Tax Asset in the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from app_private.tax_review_count(v_p.entity_id, v_p.period_start, v_p.period_end) c where c > 0;
  if v_n > 0 then
    return query select 'tax_review_pending'::text, 'warning'::text,
      'Draft or submitted documents dated in this period need a tax review before they can be recognised'::text,
      app_private.tax_review_count(v_p.entity_id, v_p.period_start, v_p.period_end);
  end if;

  -- Final income tax of a completed month that is on the final regime but not computed yet.
  select count(*) into v_n
  from generate_series(date_trunc('month', v_p.period_start)::date, v_p.period_end, interval '1 month') g(m)
  where app_private.tax_engine_from(v_p.entity_id) is not null and app_private.tax_engine_from(v_p.entity_id) <= g.m::date
    and (g.m::date + interval '1 month' - interval '1 day')::date <= v_p.period_end
    and (g.m::date + interval '1 month' - interval '1 day')::date < app_private.entity_today(v_p.entity_id)
    and (select p.income_regime from app_private.tax_profile_at(v_p.entity_id, (g.m::date + interval '1 month' - interval '1 day')::date) p) = 'final_umkm'
    and not exists (select 1 from public.tax_determinations d
                    where d.entity_id = v_p.entity_id and d.tax_kind = 'final_umkm' and d.tax_period = g.m::date
                      and d.source_type = 'period' and d.superseded_at is null);
  if v_n > 0 then
    return query select 'final_tax_not_computed'::text, 'warning'::text,
      'The final income tax of a completed month in this period is not computed yet'::text, v_n;
  end if;
  -- ---- P8: fixed assets, financing and equity (Step 15 §12, Step 16 §16-17)
  -- The asset register (cost and accumulated depreciation) against the General Ledger, as of the end of the period.
  select count(*) into v_n from app_private.asset_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_total;
  if v_n > 0 then
    return query select 'asset_ledger_mismatch'::text, 'blocker'::text,
      'The fixed asset register differs from the fixed asset accounts in the General Ledger'::text, v_n;
  end if;

  -- Loans, other receivables/payables and dividends payable against their control accounts.
  select count(*) into v_n from app_private.financing_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_total;
  if v_n > 0 then
    return query select 'financing_ledger_mismatch'::text, 'blocker'::text,
      'Loans, other receivables/payables or dividends payable differ from their accounts in the General Ledger'::text, v_n;
  end if;

  -- Depreciation of a month inside this period that is over but not posted: the expense would be missing from it.
  select count(*) into v_n
  from public.asset_depreciation_lines l
  join public.fixed_assets f on f.id = l.asset_id and f.entity_id = l.entity_id
  where l.entity_id = v_p.entity_id and l.status = 'scheduled' and f.status = 'active'
    and app_private.month_end(l.period_month) between v_p.period_start and v_p.period_end
    and app_private.month_end(l.period_month) < app_private.entity_today(v_p.entity_id);
  if v_n > 0 then
    return query select 'depreciation_not_posted'::text, 'blocker'::text,
      'Depreciation due in this period has not been posted'::text, v_n;
  end if;

  select count(*) into v_n from (
    select l.id from public.bill_lines l
    join public.bills b on b.id = l.bill_id and b.entity_id = l.entity_id
    where l.entity_id = v_p.entity_id and l.asset_link_status = 'pending' and b.status = 'approved'
      and b.bill_date between v_p.period_start and v_p.period_end
    union all
    select l.id from public.expense_lines l
    join public.expenses x on x.id = l.expense_id and x.entity_id = l.entity_id
    where l.entity_id = v_p.entity_id and l.asset_link_status = 'pending' and x.status = 'confirmed'
      and x.expense_date between v_p.period_start and v_p.period_end
  ) q;
  if v_n > 0 then
    return query select 'asset_lines_pending'::text, 'warning'::text,
      'Purchase lines booked as fixed assets in this period are not registered as assets yet'::text, v_n;
  end if;

  -- Loan installments due by the end of the period that are still unpaid (information: no interest is booked before it is paid).
  select count(*) into v_n
  from public.loans ln
  cross join lateral app_private.loan_items(ln.id, null, v_p.period_end) i
  where ln.entity_id = v_p.entity_id and ln.status = 'active' and ln.effective_date <= v_p.period_end
    and i.state <> 'paid' and i.due_date <= v_p.period_end;
  if v_n > 0 then
    return query select 'loan_installments_overdue'::text, 'warning'::text,
      'Loan installments due by the end of this period are unpaid'::text, v_n;
  end if;

  -- Interest, write-offs, dividends and capital returns have tax consequences the rules do not decide (DECISIONS 106).
  select (select count(*) from public.other_obligation_settlements s
          where s.entity_id = v_p.entity_id and s.status = 'active' and s.tax_status = 'needs_review'
            and s.settlement_date between v_p.period_start and v_p.period_end)
       + (select count(*) from public.loan_payments p
          where p.entity_id = v_p.entity_id and p.status = 'active' and p.tax_status = 'needs_review'
            and p.payment_date between v_p.period_start and v_p.period_end)
       + (select count(*) from public.equity_events e
          where e.entity_id = v_p.entity_id and e.status = 'confirmed' and e.tax_status = 'needs_review'
            and e.event_date between v_p.period_start and v_p.period_end)
       + (select count(*) from public.equity_dividend_payments d
          where d.entity_id = v_p.entity_id and d.status = 'active' and d.tax_status = 'needs_review'
            and d.payment_date between v_p.period_start and v_p.period_end)
    into v_n;
  if v_n > 0 then
    return query select 'financing_tax_review_pending'::text, 'warning'::text,
      'Loan interest, write-offs, dividends or capital returns of this period still need a tax review'::text, v_n;
  end if;

  -- Payroll: the payroll liabilities against the General Ledger, and payroll that is not posted yet.
  select count(*) into v_n from app_private.payroll_control(v_p.entity_id, v_p.period_end) c
  where c.sub_ledger <> c.ledger_workflow;
  if v_n > 0 then
    return query select 'payroll_ledger_mismatch'::text, 'blocker'::text,
      'The payroll liabilities differ from their accounts in the General Ledger'::text, v_n;
  end if;

  select count(*) into v_n from public.payroll_runs r
  where r.entity_id = v_p.entity_id and r.period_end between v_p.period_start and v_p.period_end and r.status = 'approved';
  if v_n > 0 then
    return query select 'payroll_approved_not_posted'::text, 'blocker'::text,
      'An approved payroll run of this period has not been posted'::text, v_n;
  end if;

  select count(*) into v_n from public.payroll_runs r
  where r.entity_id = v_p.entity_id and r.period_end between v_p.period_start and v_p.period_end
    and r.status in ('draft', 'calculated', 'submitted');
  if v_n > 0 then
    return query select 'payroll_not_posted'::text, 'warning'::text,
      'Payroll of this period is still being prepared: its expense and liabilities are not booked yet'::text, v_n;
  end if;

  select count(*) into v_n from public.payroll_runs r
  where r.entity_id = v_p.entity_id and r.period_end between v_p.period_start and v_p.period_end
    and r.status in ('posted', 'partially_paid', 'paid', 'closed')
    and jsonb_array_length(app_private.payroll_run_differences(r.id)) > 0;
  if v_n > 0 then
    return query select 'payroll_run_not_reconciled'::text, 'blocker'::text,
      'A posted payroll run does not reconcile to its journal, tax ledger or payslips'::text, v_n;
  end if;
end
$$;


-- ------------------------------------------------------------ privileges
revoke all on all functions in schema app_private from public;
revoke all on function public.payroll_run_list(uuid, text, integer) from public, anon;
revoke all on function public.payroll_run_get(uuid) from public, anon;
revoke all on function public.payroll_run_lines(uuid) from public, anon;
revoke all on function public.payroll_adjustments_list(uuid) from public, anon;
revoke all on function public.payroll_payments_list(uuid) from public, anon;
revoke all on function public.payroll_payslip_list(uuid, uuid, uuid, integer) from public, anon;
revoke all on function public.payroll_payslip_get(uuid) from public, anon;
revoke all on function public.payroll_employee_tax_ledger(uuid, integer, uuid) from public, anon;
revoke all on function public.payroll_annual_reconciliation(uuid, integer) from public, anon;
revoke all on function public.payroll_summary_report(uuid, date, date) from public, anon;
revoke all on function public.payroll_liability_report(uuid, date) from public, anon;
revoke all on function public.payroll_control_report(uuid, date) from public, anon;
grant execute on function public.payroll_run_list(uuid, text, integer) to authenticated;
grant execute on function public.payroll_run_get(uuid) to authenticated;
grant execute on function public.payroll_run_lines(uuid) to authenticated;
grant execute on function public.payroll_adjustments_list(uuid) to authenticated;
grant execute on function public.payroll_payments_list(uuid) to authenticated;
grant execute on function public.payroll_payslip_list(uuid, uuid, uuid, integer) to authenticated;
grant execute on function public.payroll_payslip_get(uuid) to authenticated;
grant execute on function public.payroll_employee_tax_ledger(uuid, integer, uuid) to authenticated;
grant execute on function public.payroll_annual_reconciliation(uuid, integer) to authenticated;
grant execute on function public.payroll_summary_report(uuid, date, date) to authenticated;
grant execute on function public.payroll_liability_report(uuid, date) to authenticated;
grant execute on function public.payroll_control_report(uuid, date) to authenticated;
