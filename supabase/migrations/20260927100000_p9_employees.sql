-- P9 (Step 15 §13, Step 01 #24-#25, Step 02 "People & Payroll", Step 06 §4/§6): the employee master and the sensitive
-- payroll permission boundary.
--
-- What this part delivers
--   * Employees are independent from application users (Step 02). Each employee has one identity row (operational
--     fields only), effective-dated EMPLOYMENT records (position, type), effective-dated COMPENSATION components,
--     effective-dated TAX FACTS (tax-number status, PTKP status, how the tax is borne) and effective-dated BPJS
--     enrolment. Terms are recorded, never overwritten: a change is a new row from a date (Step 02: "employment
--     records preserve changing terms over time").
--   * The permission boundary (Step 06 §6). Nothing in payroll is readable with a table SELECT: every table is closed
--     to the browser roles and is read only through the RPCs below, each of which checks its own capability.
--       payroll.employee_view    the employee list: name, code, status, position, dates - never money or tax facts
--       payroll.compensation_view  compensation components and BPJS enrolment
--       payroll.tax_view         the tax profile (identifier masked; the full identifier needs a recent step-up)
--       payroll.employee_edit / payroll.compensation_edit  write the matching records
--     Audit rows of the sensitive tables are REDACTED: they record who changed what and when, never the amounts or
--     identifiers themselves.
--   * Payroll exists for a company Entity only. A Personal Entity has no employees (its salary flows are the PT
--     side of Step 04 §10).
-- The rule master for PPh 21 and BPJS, the payroll run and its posting follow in the next parts.

-- ------------------------------------------------------------ numbering families
alter table public.numbering_sequences drop constraint numbering_sequences_scope_check;
alter table public.numbering_sequences add constraint numbering_sequences_scope_check
  check (scope in ('invoice', 'payment_receipt', 'refund_receipt', 'bill', 'bill_payment', 'expense', 'journal',
                   'transfer', 'tax_payment', 'asset', 'loan', 'loan_payment', 'other_receivable', 'other_payable',
                   'obligation_settlement', 'equity', 'employee', 'payroll_run', 'payroll_payment', 'payslip', 'other'));

create function app_private.ensure_payroll_numbering(p_entity uuid) returns void
language plpgsql as $$
begin
  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (p_entity, 'employee', 'EMP'),
         (p_entity, 'payroll_run', 'PR'),
         (p_entity, 'payroll_payment', 'PYP'),
         (p_entity, 'payslip', 'PSL')
  on conflict (entity_id, scope) do nothing;
end
$$;

-- ------------------------------------------------------------ the boundary helpers
-- Every payroll RPC starts here. `p_amounts` marks an operation that shows or processes money: it needs the
-- compensation capability as well, so nobody handles payroll amounts without being allowed to see them.
create function app_private.payroll_authorize(p_entity uuid, p_perm text, p_what text, p_amounts boolean default false)
returns void
language plpgsql stable as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_entity is null or not app_authz.has_permission(p_entity, p_perm)
     or (p_amounts and not app_authz.has_permission(p_entity, 'payroll.compensation_view')) then
    raise exception 'FORBIDDEN: % needs %', p_what,
      case when p_amounts and p_perm <> 'payroll.compensation_view' then p_perm || ' and payroll.compensation_view' else p_perm end
      using errcode = 'insufficient_privilege';
  end if;
  if (select e.entity_type from public.entities e where e.id = p_entity) <> 'company' then
    raise exception 'INVALID: payroll exists for a company Entity only' using errcode = 'invalid_parameter_value';
  end if;
end
$$;

-- ------------------------------------------------------------ employees
create table public.employees (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  employee_code text not null,
  full_name text not null check (length(btrim(full_name)) between 2 and 200),
  status text not null default 'active' check (status in ('active', 'ended')),
  join_date date not null,
  exit_date date,
  exit_reason text check (exit_reason is null or length(exit_reason) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  constraint employee_exit_shape check (
    (status = 'ended') = (exit_date is not null) and (exit_date is null or exit_date >= join_date)
    and (status = 'ended' or exit_reason is null))
);
create unique index employees_code_uq on public.employees (entity_id, employee_code);
create index employees_status_idx on public.employees (entity_id, status);

create function app_private.tg_employees_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['full_name', 'status', 'join_date', 'exit_date', 'exit_reason', 'updated_at',
                                   'updated_by', 'version'];
begin
  if tg_op = 'UPDATE' and (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The identity of an employee (code, Entity) cannot be changed' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.employees
  for each row execute function app_private.tg_employees_guard();
create trigger tg_forbid_delete before delete on public.employees
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.employees
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.employees');
call app_private.secure_table('public.employees');
create trigger tg_audit after insert or update or delete on public.employees
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ append-only effective-dated records
create table public.employee_employments (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  employee_id uuid not null,
  effective_from date not null,
  employment_type text not null check (employment_type in ('permanent', 'contract', 'probation', 'part_time')),
  position_title text not null check (length(btrim(position_title)) between 1 and 120),
  department text check (department is null or length(btrim(department)) between 1 and 120),
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  unique (employee_id, effective_from),
  foreign key (entity_id, employee_id) references public.employees (entity_id, id) on delete restrict
);
create index employee_employments_emp_idx on public.employee_employments (entity_id, employee_id, effective_from desc);

create table public.employee_compensation (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  employee_id uuid not null,
  effective_from date not null,
  component_code text not null check (component_code ~ '^[a-z][a-z0-9_]{1,40}$'),
  kind text not null check (kind in ('earning', 'deduction')),
  -- Zero ends the component from that date; nothing is ever overwritten.
  amount public.money_amount not null check (amount >= 0),
  label text not null check (length(btrim(label)) between 1 and 120),
  -- An earning is taxable income unless the user says otherwise; a component counts towards the BPJS wage base
  -- only when it is marked so.
  taxable boolean not null default true,
  bpjs_base boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  unique (employee_id, component_code, effective_from),
  foreign key (entity_id, employee_id) references public.employees (entity_id, id) on delete restrict,
  constraint employee_comp_shape check (kind = 'earning' or not bpjs_base)
);
create index employee_comp_emp_idx on public.employee_compensation (entity_id, employee_id, component_code, effective_from desc);

create table public.employee_tax_profiles (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  employee_id uuid not null,
  effective_from date not null,
  -- "unknown" stays unknown: the run of such an employee waits for a decision (Step 05 no-assumption policy).
  tax_id_status text not null check (tax_id_status in ('has_tax_id', 'no_tax_id', 'unknown')),
  tax_id text check (tax_id is null or tax_id ~ '^[0-9]{15,16}$'),
  ptkp_status text not null check (ptkp_status in ('TK/0', 'TK/1', 'TK/2', 'TK/3', 'K/0', 'K/1', 'K/2', 'K/3', 'unknown')),
  -- Explicit configuration, never inferred (Step 05 §9): the employee bears the tax, or the employer grosses it up
  -- with a tax allowance.
  tax_method text not null default 'employee_borne' check (tax_method in ('employee_borne', 'gross_up')),
  note text check (note is null or length(note) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  unique (employee_id, effective_from),
  foreign key (entity_id, employee_id) references public.employees (entity_id, id) on delete restrict,
  constraint employee_tax_id_shape check ((tax_id_status = 'has_tax_id') = (tax_id is not null))
);
create index employee_tax_emp_idx on public.employee_tax_profiles (entity_id, employee_id, effective_from desc);

create table public.employee_bpjs_enrollments (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  employee_id uuid not null,
  effective_from date not null,
  component_code text not null check (component_code in ('bpjs_kes', 'bpjs_jht', 'bpjs_jp', 'bpjs_jkk', 'bpjs_jkm')),
  enrolled boolean not null,
  -- Which employer rate option applies (for example the JKK risk grade); null when the rule has a single rate.
  rate_key text check (rate_key is null or rate_key ~ '^[a-z][a-z0-9_]{1,30}$'),
  member_ref text check (member_ref is null or length(member_ref) <= 40),
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  unique (employee_id, component_code, effective_from),
  foreign key (entity_id, employee_id) references public.employees (entity_id, id) on delete restrict
);
create index employee_bpjs_emp_idx on public.employee_bpjs_enrollments (entity_id, employee_id, component_code, effective_from desc);

do $$
declare
  t text;
begin
  foreach t in array array['employee_employments', 'employee_compensation', 'employee_tax_profiles', 'employee_bpjs_enrollments'] loop
    execute format('create trigger tg_forbid_update before update on public.%I for each row execute function app_private.tg_forbid_update()', t);
    execute format('create trigger tg_forbid_delete before delete on public.%I for each row execute function app_private.tg_forbid_delete()', t);
    execute format('create trigger tg_forbid_truncate before truncate on public.%I for each statement execute function app_private.tg_forbid_truncate()', t);
    execute format('create trigger tg_stamp_created before insert on public.%I for each row execute function app_private.tg_stamp_created()', t);
    execute format('call app_private.secure_table(%L)', 'public.' || t);
  end loop;
end
$$;
-- The audit trail records that a record was added and by whom - never the money, the identifier or the status.
create trigger tg_audit after insert on public.employee_employments
  for each row execute function app_private.tg_audit('entity_id');
create trigger tg_audit after insert on public.employee_compensation
  for each row execute function app_private.tg_audit('entity_id', 'amount', 'label');
create trigger tg_audit after insert on public.employee_tax_profiles
  for each row execute function app_private.tg_audit('entity_id', 'tax_id', 'ptkp_status', 'tax_id_status', 'note');
create trigger tg_audit after insert on public.employee_bpjs_enrollments
  for each row execute function app_private.tg_audit('entity_id', 'member_ref');

-- ------------------------------------------------------------ the value of a term at a date
-- The components in force at a date: for each component the latest row from on or before the date; ended components
-- (amount zero) are left out.
create function app_private.employee_components_at(p_employee uuid, p_date date)
returns table (component_code text, kind text, amount numeric, label text, taxable boolean, bpjs_base boolean,
               effective_from date)
language sql stable as $$
  select c.component_code, c.kind, c.amount, c.label, c.taxable, c.bpjs_base, c.effective_from
  from (select distinct on (x.component_code) x.*
        from public.employee_compensation x
        where x.employee_id = p_employee and x.effective_from <= p_date
        order by x.component_code, x.effective_from desc) c
  where c.amount > 0
  order by c.kind desc, c.component_code
$$;

create function app_private.employee_tax_at(p_employee uuid, p_date date) returns public.employee_tax_profiles
language sql stable as $$
  select t.* from public.employee_tax_profiles t
  where t.employee_id = p_employee and t.effective_from <= p_date
  order by t.effective_from desc limit 1
$$;

create function app_private.employee_bpjs_at(p_employee uuid, p_date date)
returns table (component_code text, rate_key text, member_ref text, effective_from date)
language sql stable as $$
  select c.component_code, c.rate_key, c.member_ref, c.effective_from
  from (select distinct on (x.component_code) x.*
        from public.employee_bpjs_enrollments x
        where x.employee_id = p_employee and x.effective_from <= p_date
        order by x.component_code, x.effective_from desc) c
  where c.enrolled
  order by c.component_code
$$;

create function app_private.employee_employment_at(p_employee uuid, p_date date) returns public.employee_employments
language sql stable as $$
  select m.* from public.employee_employments m
  where m.employee_id = p_employee and m.effective_from <= p_date
  order by m.effective_from desc limit 1
$$;

-- ------------------------------------------------------------ commands: the identity
create function public.employee_create(
  p_entity uuid, p_key text, p_name text, p_join_date date, p_employment_type text, p_position text,
  p_department text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid := gen_random_uuid();
  v_code text;
begin
  perform app_private.payroll_authorize(p_entity, 'payroll.employee_edit', 'creating an employee');
  v_replay := app_private.idem_begin('employee.create', p_entity, p_key,
    md5(jsonb_build_object('n', p_name, 'j', p_join_date, 't', p_employment_type, 'p', p_position, 'd', p_department)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 2 and 200 or p_join_date is null
     or length(btrim(coalesce(p_position, ''))) not between 1 and 120
     or p_employment_type not in ('permanent', 'contract', 'probation', 'part_time') then
    raise exception 'INVALID: an employee needs a name, a join date, a position and an employment type'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_join_date);
  perform app_private.ensure_payroll_numbering(p_entity);
  v_code := app_private.allocate_document_number(p_entity, 'employee', p_join_date);
  insert into public.employees (id, entity_id, employee_code, full_name, join_date, created_by)
  values (v_id, p_entity, v_code, btrim(p_name), p_join_date, auth.uid());
  insert into public.employee_employments (entity_id, employee_id, effective_from, employment_type, position_title, department)
  values (p_entity, v_id, p_join_date, p_employment_type, btrim(p_position), nullif(btrim(coalesce(p_department, '')), ''));
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_entity, 'EmployeeCreated', 'employee', v_id, jsonb_build_object('code', v_code));
  perform app_private.idem_complete('employee.create', p_entity, p_key, 'employees', v_id);
  return v_id;
end
$$;

-- The name, and the join date while no payroll has counted the employee yet.
create function public.employee_update(p_employee uuid, p_name text, p_join_date date default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.employee_edit', 'changing an employee');
  select * into e from public.employees where id = p_employee for update;
  if length(btrim(coalesce(p_name, ''))) not between 2 and 200 then
    raise exception 'INVALID: the name needs 2 to 200 characters' using errcode = 'invalid_parameter_value';
  end if;
  if p_join_date is not null and p_join_date <> e.join_date then
    if exists (select 1 from public.payroll_run_lines l join public.payroll_runs r on r.id = l.run_id
               where l.employee_id = p_employee and r.status in ('posted', 'partially_paid', 'paid', 'closed', 'corrected')) then
      raise exception 'CONFLICT: payroll has already counted this employee; the join date cannot change'
        using errcode = 'integrity_constraint_violation';
    end if;
    perform app_private.assert_business_date(p_join_date);
    if e.exit_date is not null and e.exit_date < p_join_date then
      raise exception 'INVALID: the join date cannot be after the exit date' using errcode = 'invalid_parameter_value';
    end if;
  end if;
  update public.employees set full_name = btrim(p_name), join_date = coalesce(p_join_date, join_date) where id = e.id;
end
$$;

-- The employee leaves. A posted payroll for a month after the exit month would have paid a leaver: correct it first.
-- (Runs still being prepared recalculate on the new facts, and their input fingerprint changes.)
create function public.employee_end(p_employee uuid, p_key text, p_exit_date date, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  v_replay uuid;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.employee_edit', 'ending an employment');
  v_replay := app_private.idem_begin('employee.end', e.entity_id, p_key,
    md5(jsonb_build_object('e', p_employee, 'd', p_exit_date, 'r', p_reason)::text));
  if v_replay is not null then
    return;
  end if;
  select * into e from public.employees where id = p_employee for update;
  if e.status <> 'active' then
    raise exception 'CONFLICT: this employee has already left' using errcode = 'integrity_constraint_violation';
  end if;
  if p_exit_date is null or p_exit_date < e.join_date or v_reason is null or length(v_reason) > 500 then
    raise exception 'INVALID: leaving needs an exit date (not before the join date) and a reason'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_exit_date);
  if exists (select 1 from public.payroll_run_lines l
             join public.payroll_runs r on r.id = l.run_id
             where l.employee_id = e.id and r.status in ('posted', 'partially_paid', 'paid', 'closed')
               and r.period_start > date_trunc('month', p_exit_date)::date) then
    raise exception 'CONFLICT: payroll for a month after the exit month already includes this employee; correct that run first'
      using errcode = 'integrity_constraint_violation';
  end if;
  update public.employees set status = 'ended', exit_date = p_exit_date, exit_reason = v_reason where id = e.id;
  perform app_private.idem_complete('employee.end', e.entity_id, p_key, 'employees', e.id);
end
$$;

create function public.employee_record_employment(
  p_employee uuid, p_effective_from date, p_employment_type text, p_position text, p_department text default null,
  p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  v_id uuid;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.employee_edit', 'recording an employment change');
  if p_effective_from is null or p_effective_from < e.join_date
     or p_employment_type not in ('permanent', 'contract', 'probation', 'part_time')
     or length(btrim(coalesce(p_position, ''))) not between 1 and 120 then
    raise exception 'INVALID: an employment record needs a date (not before the join date), a type and a position'
      using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.employee_employments m where m.employee_id = e.id and m.effective_from = p_effective_from) then
    raise exception 'CONFLICT: the employment terms from % are already recorded; record the change from a later date', p_effective_from
      using errcode = 'integrity_constraint_violation';
  end if;
  insert into public.employee_employments (entity_id, employee_id, effective_from, employment_type, position_title, department, note)
  values (e.entity_id, e.id, p_effective_from, p_employment_type, btrim(p_position),
          nullif(btrim(coalesce(p_department, '')), ''), nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;
  return v_id;
end
$$;

-- Compensation: a list of components from a date. Each item: {component, kind, amount, label, taxable, bpjs_base}.
-- An amount of 0 ends that component from the date. Earlier dates are never rewritten.
create function public.employee_set_compensation(p_employee uuid, p_key text, p_effective_from date, p_items jsonb)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  v_replay uuid;
  v_scale integer;
  x jsonb;
  v_n integer := 0;
  v_code text;
  v_kind text;
  v_amount numeric;
  v_label text;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.compensation_edit', 'changing compensation');
  v_replay := app_private.idem_begin('employee.set_compensation', e.entity_id, p_key,
    md5(jsonb_build_object('e', p_employee, 'd', p_effective_from, 'i', p_items)::text));
  if v_replay is not null then
    return (select count(*)::integer from public.employee_compensation c where c.employee_id = e.id and c.effective_from = p_effective_from);
  end if;
  if p_effective_from is null or p_effective_from < e.join_date then
    raise exception 'INVALID: compensation needs a date that is not before the join date' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 30 then
    raise exception 'INVALID: give 1 to 30 compensation components' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_effective_from);
  v_scale := app_private.currency_scale(app_private.entity_base_currency(e.entity_id));
  for x in select value from jsonb_array_elements(p_items) loop
    v_code := lower(btrim(coalesce(x ->> 'component', '')));
    v_kind := coalesce(x ->> 'kind', '');
    v_label := btrim(coalesce(x ->> 'label', ''));
    if v_code !~ '^[a-z][a-z0-9_]{1,40}$' or v_kind not in ('earning', 'deduction') or length(v_label) not between 1 and 120 then
      raise exception 'INVALID: each component needs a code, a kind (earning or deduction) and a label' using errcode = 'invalid_parameter_value';
    end if;
    v_amount := app_private.money_arg(coalesce(x ->> 'amount', ''), 'a component amount', v_scale, true);
    if exists (select 1 from public.employee_compensation c
               where c.employee_id = e.id and c.component_code = v_code and c.effective_from = p_effective_from) then
      raise exception 'CONFLICT: % from % is already recorded; record the change from a later date', v_code, p_effective_from
        using errcode = 'integrity_constraint_violation';
    end if;
    if v_kind = 'deduction' and coalesce((x ->> 'bpjs_base')::boolean, false) then
      raise exception 'INVALID: only an earning can count towards the BPJS wage base' using errcode = 'invalid_parameter_value';
    end if;
    insert into public.employee_compensation
      (entity_id, employee_id, effective_from, component_code, kind, amount, label, taxable, bpjs_base)
    values (e.entity_id, e.id, p_effective_from, v_code, v_kind, v_amount, v_label,
            coalesce((x ->> 'taxable')::boolean, true), coalesce((x ->> 'bpjs_base')::boolean, false));
    v_n := v_n + 1;
  end loop;
  perform app_private.idem_complete('employee.set_compensation', e.entity_id, p_key, 'employees', e.id);
  return v_n;
end
$$;

-- Tax facts of an employee from a date. Unknown values are allowed and are recorded as unknown; a payroll run cannot
-- withhold on unknown facts (Step 05 §15).
create function public.employee_set_tax_profile(
  p_employee uuid, p_key text, p_effective_from date, p_tax_id_status text, p_tax_id text, p_ptkp_status text,
  p_tax_method text default 'employee_borne', p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  v_replay uuid;
  v_id uuid := gen_random_uuid();
  v_tax_id text := nullif(regexp_replace(coalesce(p_tax_id, ''), '[^0-9]', '', 'g'), '');
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.employee_edit', 'recording employee tax facts');
  if not app_authz.has_permission(e.entity_id, 'payroll.tax_view') then
    raise exception 'FORBIDDEN: recording employee tax facts needs payroll.tax_view' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('employee.set_tax_profile', e.entity_id, p_key,
    md5(jsonb_build_object('e', p_employee, 'd', p_effective_from, 's', p_tax_id_status, 'i', v_tax_id, 'p', p_ptkp_status,
                           'm', p_tax_method, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p_effective_from is null or p_effective_from < e.join_date or p_tax_id_status not in ('has_tax_id', 'no_tax_id', 'unknown')
     or p_ptkp_status not in ('TK/0', 'TK/1', 'TK/2', 'TK/3', 'K/0', 'K/1', 'K/2', 'K/3', 'unknown')
     or p_tax_method not in ('employee_borne', 'gross_up') then
    raise exception 'INVALID: tax facts need a date (not before the join date), a tax-number status, a PTKP status and a method'
      using errcode = 'invalid_parameter_value';
  end if;
  if (p_tax_id_status = 'has_tax_id') <> (v_tax_id is not null) or (v_tax_id is not null and v_tax_id !~ '^[0-9]{15,16}$') then
    raise exception 'INVALID: give a 15 or 16 digit tax number exactly when the status is has_tax_id' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.employee_tax_profiles t where t.employee_id = e.id and t.effective_from = p_effective_from) then
    raise exception 'CONFLICT: tax facts from % are already recorded; record the change from a later date', p_effective_from
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(p_effective_from);
  insert into public.employee_tax_profiles
    (id, entity_id, employee_id, effective_from, tax_id_status, tax_id, ptkp_status, tax_method, note)
  values (v_id, e.entity_id, e.id, p_effective_from, p_tax_id_status, v_tax_id, p_ptkp_status, p_tax_method,
          nullif(btrim(coalesce(p_note, '')), ''));
  perform app_private.idem_complete('employee.set_tax_profile', e.entity_id, p_key, 'employee_tax_profiles', v_id);
  return v_id;
end
$$;

-- BPJS enrolment from a date. Each item: {component, enrolled, rate_key, member_ref}.
create function public.employee_set_bpjs(p_employee uuid, p_key text, p_effective_from date, p_items jsonb) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  v_replay uuid;
  x jsonb;
  v_n integer := 0;
  v_code text;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.compensation_edit', 'changing BPJS enrolment');
  v_replay := app_private.idem_begin('employee.set_bpjs', e.entity_id, p_key,
    md5(jsonb_build_object('e', p_employee, 'd', p_effective_from, 'i', p_items)::text));
  if v_replay is not null then
    return (select count(*)::integer from public.employee_bpjs_enrollments c where c.employee_id = e.id and c.effective_from = p_effective_from);
  end if;
  if p_effective_from is null or p_effective_from < e.join_date then
    raise exception 'INVALID: BPJS enrolment needs a date that is not before the join date' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 10 then
    raise exception 'INVALID: give 1 to 10 BPJS items' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_effective_from);
  for x in select value from jsonb_array_elements(p_items) loop
    v_code := coalesce(x ->> 'component', '');
    if v_code not in ('bpjs_kes', 'bpjs_jht', 'bpjs_jp', 'bpjs_jkk', 'bpjs_jkm') or jsonb_typeof(x -> 'enrolled') is distinct from 'boolean' then
      raise exception 'INVALID: each BPJS item needs a component (bpjs_kes, bpjs_jht, bpjs_jp, bpjs_jkk, bpjs_jkm) and enrolled true or false'
        using errcode = 'invalid_parameter_value';
    end if;
    if nullif(x ->> 'rate_key', '') is not null and (x ->> 'rate_key') !~ '^[a-z][a-z0-9_]{1,30}$' then
      raise exception 'INVALID: the rate option is a short lower-case key' using errcode = 'invalid_parameter_value';
    end if;
    if exists (select 1 from public.employee_bpjs_enrollments c
               where c.employee_id = e.id and c.component_code = v_code and c.effective_from = p_effective_from) then
      raise exception 'CONFLICT: % from % is already recorded; record the change from a later date', v_code, p_effective_from
        using errcode = 'integrity_constraint_violation';
    end if;
    insert into public.employee_bpjs_enrollments (entity_id, employee_id, effective_from, component_code, enrolled, rate_key, member_ref)
    values (e.entity_id, e.id, p_effective_from, v_code, (x ->> 'enrolled')::boolean, nullif(x ->> 'rate_key', ''),
            nullif(btrim(coalesce(x ->> 'member_ref', '')), ''));
    v_n := v_n + 1;
  end loop;
  perform app_private.idem_complete('employee.set_bpjs', e.entity_id, p_key, 'employees', e.id);
  return v_n;
end
$$;

-- ------------------------------------------------------------ reads (each with its own capability)
-- The list: operational fields only. No amount, no tax fact.
create function public.employee_list(p_entity uuid, p_include_ended boolean default true)
returns table (id uuid, employee_code text, full_name text, status text, join_date date, exit_date date,
               employment_type text, position_title text, department text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.payroll_authorize(p_entity, 'payroll.employee_view', 'the employee list');
  return query
  select e.id, e.employee_code, e.full_name, e.status, e.join_date, e.exit_date, m.employment_type, m.position_title, m.department
  from public.employees e
  left join lateral app_private.employee_employment_at(e.id, coalesce(e.exit_date, app_private.entity_today(p_entity))) m on true
  where e.entity_id = p_entity and (p_include_ended or e.status = 'active')
  order by e.employee_code;
end
$$;

create function public.employee_employment_history(p_employee uuid)
returns table (effective_from date, employment_type text, position_title text, department text, note text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.employee_view', 'the employment history');
  return query
  select m.effective_from, m.employment_type, m.position_title, m.department, m.note
  from public.employee_employments m where m.employee_id = e.id order by m.effective_from desc;
end
$$;

-- Compensation in force at a date (default: today), with what is scheduled after it.
create function public.employee_compensation_get(p_employee uuid, p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  v_date date;
  v_out jsonb;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.compensation_view', 'employee compensation');
  v_date := coalesce(p_date, app_private.entity_today(e.entity_id));
  select jsonb_build_object(
    'as_of', v_date,
    'earnings_total', trim_scale(coalesce(sum(c.amount) filter (where c.kind = 'earning'), 0))::text,
    'deductions_total', trim_scale(coalesce(sum(c.amount) filter (where c.kind = 'deduction'), 0))::text,
    'components', coalesce(jsonb_agg(jsonb_build_object(
        'component', c.component_code, 'kind', c.kind, 'amount', trim_scale(c.amount)::text, 'label', c.label,
        'taxable', c.taxable, 'bpjs_base', c.bpjs_base, 'effective_from', c.effective_from) order by c.kind desc, c.component_code), '[]'::jsonb))
  into v_out
  from app_private.employee_components_at(e.id, v_date) c;
  return v_out;
end
$$;

create function public.employee_bpjs_get(p_employee uuid, p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  v_date date;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.compensation_view', 'BPJS enrolment');
  v_date := coalesce(p_date, app_private.entity_today(e.entity_id));
  return jsonb_build_object('as_of', v_date, 'enrolled', coalesce((
    select jsonb_agg(jsonb_build_object('component', b.component_code, 'rate_key', b.rate_key, 'member_ref', b.member_ref,
                                        'effective_from', b.effective_from) order by b.component_code)
    from app_private.employee_bpjs_at(e.id, v_date) b), '[]'::jsonb));
end
$$;

-- The tax profile: the identifier is masked (last four digits) ...
create function public.employee_tax_profile_get(p_employee uuid, p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
  t public.employee_tax_profiles%rowtype;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.tax_view', 'the employee tax profile');
  t := app_private.employee_tax_at(e.id, coalesce(p_date, app_private.entity_today(e.entity_id)));
  if t.id is null then
    return jsonb_build_object('recorded', false);
  end if;
  return jsonb_build_object('recorded', true, 'effective_from', t.effective_from, 'tax_id_status', t.tax_id_status,
    'tax_id_masked', case when t.tax_id is null then null else repeat('*', length(t.tax_id) - 4) || right(t.tax_id, 4) end,
    'ptkp_status', t.ptkp_status, 'tax_method', t.tax_method, 'note', t.note);
end
$$;

-- ... and the full identifier needs a recent step-up (Step 06 §8).
create function public.employee_tax_identifier(p_employee uuid, p_date date default null) returns text
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  e public.employees%rowtype;
begin
  select * into e from public.employees where id = p_employee;
  perform app_private.payroll_authorize(e.entity_id, 'payroll.tax_view', 'the employee tax identifier');
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  return (app_private.employee_tax_at(e.id, coalesce(p_date, app_private.entity_today(e.entity_id)))).tax_id;
end
$$;

-- ------------------------------------------------------------ privileges
revoke all on all functions in schema app_private from public;
revoke all on function public.employee_create(uuid, text, text, date, text, text, text) from public, anon;
revoke all on function public.employee_update(uuid, text, date) from public, anon;
revoke all on function public.employee_end(uuid, text, date, text) from public, anon;
revoke all on function public.employee_record_employment(uuid, date, text, text, text, text) from public, anon;
revoke all on function public.employee_set_compensation(uuid, text, date, jsonb) from public, anon;
revoke all on function public.employee_set_tax_profile(uuid, text, date, text, text, text, text, text) from public, anon;
revoke all on function public.employee_set_bpjs(uuid, text, date, jsonb) from public, anon;
revoke all on function public.employee_list(uuid, boolean) from public, anon;
revoke all on function public.employee_employment_history(uuid) from public, anon;
revoke all on function public.employee_compensation_get(uuid, date) from public, anon;
revoke all on function public.employee_bpjs_get(uuid, date) from public, anon;
revoke all on function public.employee_tax_profile_get(uuid, date) from public, anon;
revoke all on function public.employee_tax_identifier(uuid, date) from public, anon;
grant execute on function public.employee_create(uuid, text, text, date, text, text, text) to authenticated;
grant execute on function public.employee_update(uuid, text, date) to authenticated;
grant execute on function public.employee_end(uuid, text, date, text) to authenticated;
grant execute on function public.employee_record_employment(uuid, date, text, text, text, text) to authenticated;
grant execute on function public.employee_set_compensation(uuid, text, date, jsonb) to authenticated;
grant execute on function public.employee_set_tax_profile(uuid, text, date, text, text, text, text, text) to authenticated;
grant execute on function public.employee_set_bpjs(uuid, text, date, jsonb) to authenticated;
grant execute on function public.employee_list(uuid, boolean) to authenticated;
grant execute on function public.employee_employment_history(uuid) to authenticated;
grant execute on function public.employee_compensation_get(uuid, date) to authenticated;
grant execute on function public.employee_bpjs_get(uuid, date) to authenticated;
grant execute on function public.employee_tax_profile_get(uuid, date) to authenticated;
grant execute on function public.employee_tax_identifier(uuid, date) to authenticated;
