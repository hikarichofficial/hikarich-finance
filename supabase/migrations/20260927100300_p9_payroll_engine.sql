-- P9 part 4: the payroll run and its calculation engine.
-- Authority: Step 07 §14 (payroll workflow: draft, calculated, submitted, approved, posted, partially paid, paid,
-- closed, corrected), Step 08 §13 (payroll integrity), Step 05 §9 (PPh 21 architecture), Step 01 #24-#25.
--
-- What this part delivers
--   * OPENING TAX FIGURES of an employee for the part of a tax year that was payrolled before this system
--     (data cut-over), so the annual reconciliation of the last tax month has the whole year.
--   * The PAYROLL RUN with its eligible employees (one line per employee), one-off ADJUSTMENTS (bonus, allowance, pay
--     cut) and the workflow states. A run has one Entity and one payroll month; a second live run for the same month is
--     blocked (Step 08 §13); a posted run is never edited or silently recalculated - a correction reverses it and opens
--     a new REVISION (Step 08 §13).
--   * The CALCULATION. It is a pure function of recorded inputs (compensation, tax facts, BPJS enrolment, adjustments,
--     year-to-date figures, the published rule versions) so the same inputs always give the same lines. The inputs are
--     fingerprinted when a run is calculated; approving or posting refuses a run whose inputs have changed since.
--       - BPJS: employee and employer shares from the rule of the month, on the wage base capped by the rule.
--       - PPh 21: the TER monthly table for every month but the last tax month of the year; in the last tax month
--         (December, or the month an employee leaves) the annual computation with PTKP, occupational cost, the
--         employee pension contributions and the Pasal 17 bands, less what was already withheld.
--       - Tax borne by the employee (withheld from pay) or by the employer (tax allowance, "gross-up", solved
--         iteratively): an explicit setting of the employee, never inferred (Step 05 §9).
--     Anything that cannot be determined (missing tax facts, missing rule, incomplete history) is a REVIEW FLAG on the
--     line, never a guess; a run with flags cannot be submitted (Step 05 no-assumption policy).
--   * Nothing here is readable through a table SELECT: the payroll tables are closed and served only by the RPCs of the
--     next parts, each with its own capability (Step 06 §6).

-- ------------------------------------------------------------ opening tax figures (data cut-over)
create table public.employee_tax_openings (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  employee_id uuid not null,
  tax_year integer not null check (tax_year between 2000 and 2100),
  revision integer not null check (revision > 0),
  -- The figures cover January up to and including this month of the tax year.
  through_month integer not null check (through_month between 1 and 11),
  taxable_gross public.money_amount not null check (taxable_gross >= 0),
  pension_deduction public.money_amount not null default 0 check (pension_deduction >= 0),
  pph21_withheld public.money_amount not null check (pph21_withheld >= 0),
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  unique (employee_id, tax_year, revision),
  foreign key (entity_id, employee_id) references public.employees (entity_id, id) on delete restrict
);
create trigger tg_forbid_update before update on public.employee_tax_openings
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.employee_tax_openings
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.employee_tax_openings
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_stamp_created before insert on public.employee_tax_openings
  for each row execute function app_private.tg_stamp_created();
call app_private.secure_table('public.employee_tax_openings');
create trigger tg_audit after insert on public.employee_tax_openings
  for each row execute function app_private.tg_audit('entity_id', 'taxable_gross', 'pension_deduction', 'pph21_withheld', 'note');

-- ------------------------------------------------------------ the payroll run
create table public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  run_number text not null,
  -- A correction reverses the posted run and opens the next revision of the same payroll month.
  revision integer not null default 1 check (revision > 0),
  period_start date not null check (period_start = date_trunc('month', period_start)::date),
  period_end date not null,
  pay_date date not null,
  status text not null default 'draft' check (status in
    ('draft', 'calculated', 'submitted', 'approved', 'posted', 'partially_paid', 'paid', 'closed', 'corrected', 'discarded')),
  corrects_run_id uuid,
  calc_version integer not null default 0 check (calc_version >= 0),
  calculated_at timestamptz,
  -- What the calculation was computed from; approval and posting compare it with the inputs as they are now.
  input_fingerprint text,
  employee_count integer not null default 0,
  review_count integer not null default 0,
  tax_base_total public.money_amount not null default 0,
  gross_pay_total public.money_amount not null default 0,
  tax_allowance_total public.money_amount not null default 0,
  employee_bpjs_total public.money_amount not null default 0,
  employer_bpjs_total public.money_amount not null default 0,
  pph21_total public.money_amount not null default 0,
  net_pay_total public.money_amount not null default 0,
  rules jsonb not null default '[]'::jsonb,
  note text check (note is null or length(note) <= 1000),
  submitted_at timestamptz,
  submitted_by uuid,
  approved_at timestamptz,
  approved_by uuid,
  posted_at timestamptz,
  posted_by uuid,
  posting_date date,
  journal_id uuid,
  reversal_journal_id uuid,
  closed_at timestamptz,
  closed_by uuid,
  corrected_at timestamptz,
  corrected_by uuid,
  correction_reason text check (correction_reason is null or length(correction_reason) <= 1000),
  discarded_at timestamptz,
  discarded_by uuid,
  discard_reason text check (discard_reason is null or length(discard_reason) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, corrects_run_id) references public.payroll_runs (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint payroll_run_period check (period_end = (period_start + interval '1 month - 1 day')::date),
  constraint payroll_run_posted_shape check (
    (status in ('posted', 'partially_paid', 'paid', 'closed', 'corrected')) = (journal_id is not null)),
  constraint payroll_run_corrected_shape check ((status = 'corrected') = (reversal_journal_id is not null)),
  constraint payroll_run_discarded_shape check ((status = 'discarded') = (discarded_at is not null)),
  constraint payroll_run_closed_shape check ((status = 'closed') = (closed_at is not null))
);
create unique index payroll_runs_number_uq on public.payroll_runs (entity_id, run_number, revision);
-- One live run per payroll month (a corrected or discarded run makes room for the next revision).
create unique index payroll_runs_live_uq on public.payroll_runs (entity_id, period_start)
  where status not in ('corrected', 'discarded');
create index payroll_runs_period_idx on public.payroll_runs (entity_id, period_start desc);

create function app_private.payroll_status_ok(p_old text, p_new text) returns boolean
language sql immutable as $$
  select p_old = p_new or (p_old, p_new) in (
    ('draft', 'calculated'), ('draft', 'discarded'),
    ('calculated', 'draft'), ('calculated', 'submitted'), ('calculated', 'discarded'),
    ('submitted', 'draft'), ('submitted', 'approved'), ('submitted', 'discarded'),
    ('approved', 'draft'), ('approved', 'posted'), ('approved', 'discarded'),
    ('posted', 'partially_paid'), ('posted', 'paid'), ('posted', 'corrected'),
    ('partially_paid', 'posted'), ('partially_paid', 'paid'), ('partially_paid', 'corrected'),
    ('paid', 'partially_paid'), ('paid', 'posted'), ('paid', 'closed'), ('paid', 'corrected'),
    ('closed', 'paid'))
$$;

-- Once posted, what the run says about the month and its money never changes; only its state moves.
create function app_private.tg_payroll_runs_guard() returns trigger
language plpgsql as $$
declare
  v_open constant text[] := array['status', 'updated_at', 'updated_by', 'version', 'closed_at', 'closed_by',
    'corrected_at', 'corrected_by', 'correction_reason', 'reversal_journal_id'];
begin
  if tg_op = 'UPDATE' then
    if not app_private.payroll_status_ok(old.status, new.status) then
      raise exception 'INVALID: a payroll run cannot move from % to %', old.status, new.status
        using errcode = 'invalid_parameter_value';
    end if;
    if old.status in ('posted', 'partially_paid', 'paid', 'closed', 'corrected', 'discarded')
       and (to_jsonb(new) - v_open) is distinct from (to_jsonb(old) - v_open) then
      raise exception 'A posted payroll run cannot change; correct it instead (Step 08 §13)'
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.payroll_runs
  for each row execute function app_private.tg_payroll_runs_guard();
create trigger tg_forbid_delete before delete on public.payroll_runs
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.payroll_runs
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.payroll_runs');
call app_private.secure_table('public.payroll_runs');
create trigger tg_audit after insert or update or delete on public.payroll_runs
  for each row execute function app_private.tg_audit('entity_id', 'tax_base_total', 'gross_pay_total', 'tax_allowance_total',
    'employee_bpjs_total', 'employer_bpjs_total', 'pph21_total', 'net_pay_total', 'rules', 'input_fingerprint');

-- ------------------------------------------------------------ one-off adjustments
create table public.payroll_adjustments (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  run_id uuid not null,
  employee_id uuid not null,
  kind text not null check (kind in ('earning', 'deduction')),
  label text not null check (length(btrim(label)) between 1 and 120),
  amount public.money_amount not null check (amount > 0),
  taxable boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  foreign key (entity_id, run_id) references public.payroll_runs (entity_id, id) on delete restrict,
  foreign key (entity_id, employee_id) references public.employees (entity_id, id) on delete restrict
);
create index payroll_adjustments_run_idx on public.payroll_adjustments (entity_id, run_id, employee_id);

-- ------------------------------------------------------------ the lines of a run
create table public.payroll_run_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  run_id uuid not null,
  employee_id uuid not null,
  -- Blocking review flags: the line cannot be approved while any remains. Information flags never block.
  review_flags text[] not null default '{}',
  info_flags text[] not null default '{}',
  components jsonb not null default '[]'::jsonb,
  earnings_total public.money_amount not null default 0,
  reductions_total public.money_amount not null default 0,
  adjustment_earnings public.money_amount not null default 0,
  adjustment_deductions public.money_amount not null default 0,
  gross_pay public.money_amount not null default 0,
  bpjs_wage_base public.money_amount not null default 0,
  bpjs_kes_employee public.money_amount not null default 0,
  bpjs_jht_employee public.money_amount not null default 0,
  bpjs_jp_employee public.money_amount not null default 0,
  bpjs_kes_employer public.money_amount not null default 0,
  bpjs_jht_employer public.money_amount not null default 0,
  bpjs_jp_employer public.money_amount not null default 0,
  bpjs_jkk_employer public.money_amount not null default 0,
  bpjs_jkm_employer public.money_amount not null default 0,
  employer_taxable_benefits public.money_amount not null default 0,
  pension_deduction public.money_amount not null default 0,
  -- The month's taxable gross income (before any tax allowance) and the tax that follows from it.
  tax_base public.money_amount not null default 0,
  tax_mode text check (tax_mode is null or tax_mode in ('ter', 'annual')),
  tax_method text check (tax_method is null or tax_method in ('employee_borne', 'gross_up')),
  pph21 public.money_amount not null default 0,
  tax_allowance public.money_amount not null default 0,
  net_pay public.money_amount not null default 0,
  tax_calc jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  unique (run_id, employee_id),
  foreign key (entity_id, run_id) references public.payroll_runs (entity_id, id) on delete restrict,
  foreign key (entity_id, employee_id) references public.employees (entity_id, id) on delete restrict,
  constraint payroll_line_tax_shape check (tax_allowance <= pph21),
  constraint payroll_line_net_shape check (
    array_length(review_flags, 1) is not null or net_pay >= 0)
);
create index payroll_run_lines_run_idx on public.payroll_run_lines (entity_id, run_id);
create index payroll_run_lines_emp_idx on public.payroll_run_lines (entity_id, employee_id);

-- Lines and adjustments change only while the run is a draft (calculation replaces the lines of a draft).
create function app_private.tg_payroll_child_guard() returns trigger
language plpgsql as $$
declare
  v_run uuid := case when tg_op = 'DELETE' then old.run_id else new.run_id end;
  v_status text;
begin
  if tg_op = 'UPDATE' then
    raise exception 'A payroll line or adjustment is never edited; recalculate or replace it' using errcode = 'integrity_constraint_violation';
  end if;
  select status into v_status from public.payroll_runs where id = v_run;
  if v_status is distinct from 'draft' then
    raise exception 'The lines of a payroll run change only while it is a draft (now %)', v_status
      using errcode = 'integrity_constraint_violation';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end
$$;
create trigger tg_guard before insert or update or delete on public.payroll_adjustments
  for each row execute function app_private.tg_payroll_child_guard();
create trigger tg_guard before insert or update or delete on public.payroll_run_lines
  for each row execute function app_private.tg_payroll_child_guard();
create trigger tg_lock_entity before update on public.payroll_adjustments
  for each row execute function app_private.tg_lock_entity();
create trigger tg_lock_entity before update on public.payroll_run_lines
  for each row execute function app_private.tg_lock_entity();
create trigger tg_forbid_truncate before truncate on public.payroll_adjustments
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_forbid_truncate before truncate on public.payroll_run_lines
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_stamp_created before insert on public.payroll_adjustments
  for each row execute function app_private.tg_stamp_created();
create trigger tg_stamp_created before insert on public.payroll_run_lines
  for each row execute function app_private.tg_stamp_created();
call app_private.secure_table('public.payroll_adjustments');
call app_private.secure_table('public.payroll_run_lines');
create trigger tg_audit after insert on public.payroll_adjustments
  for each row execute function app_private.tg_audit('entity_id', 'label', 'amount');

-- ------------------------------------------------------------ pure PPh 21 functions (values come from rule data)
-- The TER rate of a gross monthly income: the first bracket whose upper bound is not below it.
create function app_private.pph21_ter_rate(p_params jsonb, p_ptkp text, p_gross numeric) returns numeric
language plpgsql immutable as $$
declare
  v_cat text := p_params -> 'category_of_ptkp' ->> p_ptkp;
  v_row jsonb;
begin
  if v_cat is null then
    return null;
  end if;
  for v_row in select value from jsonb_array_elements(p_params -> 'tables' -> v_cat) loop
    if jsonb_typeof(v_row -> 'up_to') = 'null' or p_gross <= (v_row ->> 'up_to')::numeric then
      return (v_row ->> 'rate')::numeric;
    end if;
  end loop;
  return null;
end
$$;

-- The progressive Pasal 17 tax of a taxable income (PKP).
create function app_private.pph21_progressive(p_params jsonb, p_pkp numeric) returns numeric
language plpgsql immutable as $$
declare
  v_row jsonb;
  v_lo numeric := 0;
  v_hi numeric;
  v_tax numeric := 0;
begin
  for v_row in select value from jsonb_array_elements(p_params -> 'brackets') loop
    if p_pkp <= v_lo then
      exit;
    end if;
    v_hi := case when jsonb_typeof(v_row -> 'up_to') = 'null' then null else (v_row ->> 'up_to')::numeric end;
    v_tax := v_tax + (least(p_pkp, coalesce(v_hi, p_pkp)) - v_lo) * (v_row ->> 'rate')::numeric;
    if v_hi is null then
      exit;
    end if;
    v_lo := v_hi;
  end loop;
  return v_tax;
end
$$;

-- The annual computation of the last tax month: the annual tax on the income of the months worked.
create function app_private.pph21_annual(
  p_params jsonb, p_ptkp_status text, p_no_tax_id boolean, p_gross numeric, p_pension numeric, p_months integer)
returns jsonb
language plpgsql immutable as $$
declare
  v_cost numeric;
  v_ptkp numeric;
  v_net numeric;
  v_pkp numeric;
  v_step numeric := (p_params ->> 'pkp_round_down_to')::numeric;
  v_tax numeric;
begin
  v_cost := least(p_gross * (p_params -> 'occupational_cost' ->> 'rate')::numeric,
                  (p_params -> 'occupational_cost' ->> 'monthly_cap')::numeric * p_months);
  -- Multiply before dividing: PTKP x months / 12 is exact, where PTKP x (months / 12) would carry a rounding error into
  -- the PKP and could push it below a multiple of 1,000.
  v_ptkp := (p_params -> 'ptkp' ->> p_ptkp_status)::numeric
            * case p_params ->> 'ptkp_proration' when 'months_worked' then p_months else 12 end / 12;
  v_net := greatest(0, p_gross - v_cost - p_pension);
  v_pkp := floor(greatest(0, v_net - v_ptkp) / v_step) * v_step;
  v_tax := app_private.tax_round(p_params, app_private.pph21_progressive(p_params, v_pkp));
  if p_no_tax_id then
    v_tax := app_private.tax_round(p_params, v_tax * (p_params ->> 'no_tax_id_multiplier')::numeric);
  end if;
  return jsonb_build_object('gross', app_private.tax_money(p_gross), 'occupational_cost', app_private.tax_money(v_cost),
    'pension', app_private.tax_money(p_pension), 'net_income', app_private.tax_money(v_net), 'ptkp', app_private.tax_money(v_ptkp),
    'pkp', app_private.tax_money(v_pkp), 'months', p_months, 'annual_tax', app_private.tax_money(v_tax));
end
$$;

-- The PPh 21 due for a gross income basis: TER for a normal month, the annual reconciliation for the last tax month.
-- Returns the tax (never negative) and the working; an annual tax below what was already withheld is reported as
-- over-withholding and is not refunded through payroll (DECISIONS).
create function app_private.payroll_tax_due(p_in jsonb, p_gross numeric, p_pension numeric) returns jsonb
language plpgsql stable as $$
declare
  v_no_id boolean := p_in -> 'tax' ->> 'id_status' = 'no_tax_id';
  v_ptkp text := p_in -> 'tax' ->> 'ptkp';
  v_rule jsonb;
  v_rate numeric;
  v_tax numeric;
  v_months integer;
  v_a jsonb;
  v_due numeric;
begin
  if (p_in ->> 'last_tax_month')::boolean then
    select params into v_rule from public.tax_rule_versions where id = (p_in ->> 'annual_rule')::uuid;
    v_months := (p_in ->> 'month')::integer - (p_in ->> 'first_month')::integer + 1;
    v_a := app_private.pph21_annual(v_rule, v_ptkp, v_no_id,
      (p_in -> 'ytd' ->> 'gross')::numeric + p_gross, (p_in -> 'ytd' ->> 'pension')::numeric + p_pension, v_months);
    v_due := (v_a ->> 'annual_tax')::numeric - (p_in -> 'ytd' ->> 'tax')::numeric;
    return jsonb_build_object('tax', greatest(v_due, 0), 'overwithheld', greatest(-v_due, 0),
      'detail', v_a || jsonb_build_object('withheld_before', app_private.tax_money((p_in -> 'ytd' ->> 'tax')::numeric),
                                          'due', app_private.tax_money(v_due)));
  end if;
  select params into v_rule from public.tax_rule_versions where id = (p_in ->> 'ter_rule')::uuid;
  v_rate := app_private.pph21_ter_rate(v_rule, v_ptkp, p_gross);
  v_tax := app_private.tax_round(v_rule, p_gross * v_rate * case when v_no_id then (v_rule ->> 'no_tax_id_multiplier')::numeric else 1 end);
  return jsonb_build_object('tax', v_tax, 'overwithheld', 0,
    'detail', jsonb_build_object('gross', app_private.tax_money(p_gross), 'category', v_rule -> 'category_of_ptkp' ->> v_ptkp,
                                 'rate', trim_scale(v_rate)::text, 'no_tax_id', v_no_id));
end
$$;

-- ------------------------------------------------------------ the inputs of one employee's line
create function app_private.payroll_eligible_employees(p_run public.payroll_runs)
returns setof public.employees
language sql stable as $$
  select e.* from public.employees e
  where e.entity_id = p_run.entity_id and e.join_date <= p_run.period_end
    and (e.exit_date is null or e.exit_date >= p_run.period_start)
  order by e.employee_code
$$;

create function app_private.payroll_line_inputs(r public.payroll_runs, e public.employees) returns jsonb
language plpgsql stable as $$
declare
  v_as_of date := least(r.period_end, coalesce(e.exit_date, r.period_end));
  v_year integer := extract(year from r.period_start)::integer;
  v_month integer := extract(month from r.period_start)::integer;
  v_first integer := case when extract(year from e.join_date) = v_year then extract(month from e.join_date)::integer else 1 end;
  v_last boolean := v_month = 12 or (e.exit_date is not null and e.exit_date between r.period_start and r.period_end);
  t public.employee_tax_profiles%rowtype;
  o public.employee_tax_openings%rowtype;
  v_ytd jsonb := '{}'::jsonb;
  v_missing integer := 0;
  v_pending integer := 0;
  v_months integer[];
  v_gross numeric;
  v_pension numeric;
  v_tax numeric;
  m integer;
begin
  t := app_private.employee_tax_at(e.id, v_as_of);
  if v_last then
    select * into o from public.employee_tax_openings x
    where x.employee_id = e.id and x.tax_year = v_year order by x.revision desc limit 1;
    select coalesce(sum(l.tax_base + l.tax_allowance), 0), coalesce(sum(l.pension_deduction), 0), coalesce(sum(l.pph21), 0),
           array_agg(distinct extract(month from pr.period_start)::integer)
      into v_gross, v_pension, v_tax, v_months
    from public.payroll_run_lines l
    join public.payroll_runs pr on pr.id = l.run_id and pr.entity_id = l.entity_id
    where l.entity_id = r.entity_id and l.employee_id = e.id
      and pr.period_start >= make_date(v_year, 1, 1) and pr.period_start < r.period_start
      and pr.status in ('posted', 'partially_paid', 'paid', 'closed')
      and (o.id is null or extract(month from pr.period_start) > o.through_month);
    if o.id is not null then
      v_gross := v_gross + o.taxable_gross;
      v_pension := v_pension + o.pension_deduction;
      v_tax := v_tax + o.pph21_withheld;
    end if;
    for m in v_first .. v_month - 1 loop
      if not (m = any (coalesce(v_months, '{}'::integer[])) or (o.id is not null and m <= o.through_month)) then
        v_missing := v_missing + 1;
      end if;
    end loop;
    select count(*) into v_pending from public.payroll_runs pr
    where pr.entity_id = r.entity_id and pr.period_start >= make_date(v_year, 1, 1) and pr.period_start < r.period_start
      and pr.status in ('draft', 'calculated', 'submitted', 'approved');
    v_ytd := jsonb_build_object('gross', v_gross, 'pension', v_pension, 'tax', v_tax, 'missing_months', v_missing,
                                'pending_runs', v_pending);
  end if;
  return jsonb_build_object(
    'as_of', v_as_of, 'period_start', r.period_start, 'period_end', r.period_end, 'year', v_year, 'month', v_month,
    'first_month', v_first, 'last_tax_month', v_last,
    'joined_in_period', e.join_date > r.period_start, 'exited_in_period', e.exit_date is not null and e.exit_date < r.period_end,
    'components', coalesce((select jsonb_agg(jsonb_build_object('code', c.component_code, 'kind', c.kind, 'label', c.label,
                              'amount', app_private.tax_money(c.amount), 'taxable', c.taxable, 'bpjs_base', c.bpjs_base) order by c.kind desc, c.component_code)
                            from app_private.employee_components_at(e.id, v_as_of) c), '[]'::jsonb),
    'adjustments', coalesce((select jsonb_agg(jsonb_build_object('kind', a.kind, 'label', a.label, 'amount', a.amount, 'taxable', a.taxable)
                                              order by a.kind, a.label, a.amount, a.taxable)
                             from public.payroll_adjustments a where a.run_id = r.id and a.employee_id = e.id), '[]'::jsonb),
    'tax', case when t.id is null then null else jsonb_build_object('ptkp', t.ptkp_status, 'id_status', t.tax_id_status,
                                                                    'method', t.tax_method) end,
    'bpjs', coalesce((select jsonb_agg(jsonb_build_object('component', b.component_code, 'rate_key', b.rate_key,
                              'rule', (app_private.tax_rule_at(upper(b.component_code), r.period_end)).id) order by b.component_code)
                      from app_private.employee_bpjs_at(e.id, v_as_of) b), '[]'::jsonb),
    'ter_rule', (app_private.tax_rule_at('PPH21_TER', r.period_end)).id,
    'annual_rule', (app_private.tax_rule_at('PPH21_ANNUAL', r.period_end)).id,
    'ytd', v_ytd);
end
$$;

-- ------------------------------------------------------------ the calculation of one line (pure)
create function app_private.payroll_compute_line(p_in jsonb) returns jsonb
language plpgsql stable as $$
declare
  c jsonb;
  b jsonb;
  v_p jsonb;
  v_flags text[] := '{}';
  v_info text[] := '{}';
  v_earn numeric := 0;
  v_red numeric := 0;
  v_tax_earn numeric := 0;
  v_wage numeric := 0;
  v_adj_earn numeric := 0;
  v_adj_tax_earn numeric := 0;
  v_adj_red numeric := 0;
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
  v_taxable := greatest(0, v_tax_earn + v_adj_tax_earn - v_red - v_adj_red) + v_er_tax;
  v_mode := case when (p_in ->> 'last_tax_month')::boolean then 'annual' else 'ter' end;
  v_method := p_in -> 'tax' ->> 'method';
  if p_in -> 'tax' is null or p_in -> 'tax' ->> 'ptkp' = 'unknown' or p_in -> 'tax' ->> 'id_status' = 'unknown' then
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
    end if;
    v_calc := jsonb_build_object('mode', v_mode, 'method', v_method,
      'rule', case when v_mode = 'ter' then p_in ->> 'ter_rule' else p_in ->> 'annual_rule' end,
      'base', app_private.tax_money(v_taxable + v_allow)) || (v_due -> 'detail');
  end if;

  v_net := v_gross - v_emp_total - (v_tax - v_allow);
  if v_net < 0 then
    v_flags := v_flags || 'negative_net_pay'::text;
  end if;
  return jsonb_build_object(
    'review_flags', to_jsonb(v_flags), 'info_flags', to_jsonb(v_info),
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

-- Fingerprint of everything a run's calculation depends on, for the whole run.
create function app_private.payroll_inputs_fingerprint(p_run uuid) returns text
language plpgsql stable as $$
declare
  r public.payroll_runs%rowtype;
begin
  select * into r from public.payroll_runs where id = p_run;
  return md5(coalesce((select jsonb_agg(jsonb_build_object('e', e.id, 'in', app_private.payroll_line_inputs(r, e))
                                        order by e.employee_code)
                       from app_private.payroll_eligible_employees(r) e), '[]'::jsonb)::text);
end
$$;

-- ------------------------------------------------------------ the calculation of a run
create function app_private.payroll_calculate_core(p_run uuid) returns void
language plpgsql as $$
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
       employer_taxable_benefits, pension_deduction, tax_base, tax_mode, tax_method, pph21, tax_allowance, net_pay, tax_calc)
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
       (v_o ->> 'tax_allowance')::numeric, (v_o ->> 'net_pay')::numeric, v_o -> 'tax_calc');
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
    net_pay_total = (select coalesce(sum(l.net_pay), 0) from public.payroll_run_lines l where l.run_id = r.id)
  where x.id = r.id;
end
$$;

-- ------------------------------------------------------------ privileges
revoke all on all functions in schema app_private from public;
