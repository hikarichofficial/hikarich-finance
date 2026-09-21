-- P9 part 5: payslips, payroll payments and the payroll sub-ledger positions.
-- Authority: Step 04 §8 (payroll posting matrix: recognition once; net pay clears the liability; tax and BPJS
-- settlements reduce their liabilities), Step 08 §13 (net payroll payment cannot exceed the unsettled payable),
-- Step 09 §17 (payslip preview linked to payment and tax status), Step 14 (sensitive documents).
--
-- What this part delivers
--   * PAYSLIPS: an immutable snapshot of one employee's line, issued when the run is posted and voided (never edited
--     or deleted) when the run is corrected. The snapshot is the payslip; a rendered document is made from it later and
--     is a sensitive document.
--   * PAYROLL PAYMENTS: the settlement of net pay (per employee line, possibly in part and in several payments) and
--     of the BPJS liability. A payment clears the payroll liability; it never books salary expense again (Step 16 §18).
--     PPh 21 is settled through the tax payment of P7 (tax type 'wht_pph21').
--   * The POSITIONS the workflow and the reports read: what is outstanding per line, the state of a run after payments
--     and the reconciliation of a run against its journal, tax ledger and payslips.

-- ------------------------------------------------------------ payslips
create table public.payroll_payslips (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  run_id uuid not null,
  run_line_id uuid not null,
  employee_id uuid not null,
  payslip_number text not null,
  status text not null default 'issued' check (status in ('issued', 'voided')),
  snapshot jsonb not null,
  issued_at timestamptz not null default now(),
  voided_at timestamptz,
  void_reason text check (void_reason is null or length(void_reason) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  unique (entity_id, payslip_number),
  foreign key (entity_id, run_id) references public.payroll_runs (entity_id, id) on delete restrict,
  foreign key (entity_id, run_line_id) references public.payroll_run_lines (entity_id, id) on delete restrict,
  foreign key (entity_id, employee_id) references public.employees (entity_id, id) on delete restrict,
  constraint payroll_payslip_void_shape check ((status = 'voided') = (voided_at is not null))
);
create unique index payroll_payslips_live_uq on public.payroll_payslips (run_line_id) where status = 'issued';
create index payroll_payslips_emp_idx on public.payroll_payslips (entity_id, employee_id, issued_at desc);

create function app_private.tg_payroll_payslips_guard() returns trigger
language plpgsql as $$
declare
  v_ok constant text[] := array['status', 'voided_at', 'void_reason'];
begin
  if old.status = 'voided' or new.status <> 'voided' or (to_jsonb(new) - v_ok) is distinct from (to_jsonb(old) - v_ok) then
    raise exception 'A payslip is history: it can only be voided' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.payroll_payslips
  for each row execute function app_private.tg_payroll_payslips_guard();
create trigger tg_lock_entity before update on public.payroll_payslips
  for each row execute function app_private.tg_lock_entity();
create trigger tg_forbid_delete before delete on public.payroll_payslips
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.payroll_payslips
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_stamp_created before insert on public.payroll_payslips
  for each row execute function app_private.tg_stamp_created();
call app_private.secure_table('public.payroll_payslips');
create trigger tg_audit after insert or update on public.payroll_payslips
  for each row execute function app_private.tg_audit('entity_id', 'snapshot');

-- ------------------------------------------------------------ payroll payments
create table public.payroll_payments (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  run_id uuid not null,
  payment_number text not null,
  kind text not null check (kind in ('net_pay', 'bpjs')),
  payment_date date not null,
  financial_account_id uuid not null,
  amount public.money_amount not null check (amount > 0),
  currency public.currency_code not null,
  journal_id uuid not null,
  reference text check (reference is null or length(reference) <= 200),
  note text check (note is null or length(note) <= 1000),
  status text not null default 'confirmed' check (status in ('confirmed', 'reversed')),
  reversal_journal_id uuid,
  reversed_at timestamptz,
  reversed_by uuid,
  reversed_date date,
  reverse_reason text check (reverse_reason is null or length(reverse_reason) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (entity_id, payment_number),
  foreign key (entity_id, run_id) references public.payroll_runs (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint payroll_payment_reversal_shape check (
    (status = 'reversed') = (reversal_journal_id is not null and reversed_at is not null and reversed_date is not null
                             and reverse_reason is not null))
);
create index payroll_payments_run_idx on public.payroll_payments (entity_id, run_id, kind);
create index payroll_payments_date_idx on public.payroll_payments (entity_id, payment_date);

create table public.payroll_payment_lines (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  payment_id uuid not null,
  run_line_id uuid not null,
  amount public.money_amount not null check (amount > 0),
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  unique (payment_id, run_line_id),
  foreign key (entity_id, payment_id) references public.payroll_payments (entity_id, id) on delete restrict,
  foreign key (entity_id, run_line_id) references public.payroll_run_lines (entity_id, id) on delete restrict
);
create index payroll_payment_lines_line_idx on public.payroll_payment_lines (entity_id, run_line_id);

create function app_private.tg_payroll_payments_guard() returns trigger
language plpgsql as $$
declare
  v_ok constant text[] := array['status', 'reversal_journal_id', 'reversed_at', 'reversed_by', 'reversed_date', 'reverse_reason',
                                'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' or new.status <> 'reversed' or (to_jsonb(new) - v_ok) is distinct from (to_jsonb(old) - v_ok) then
    raise exception 'A payroll payment is history: it can only be reversed' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.payroll_payments
  for each row execute function app_private.tg_payroll_payments_guard();
create trigger tg_forbid_delete before delete on public.payroll_payments
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.payroll_payments
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.payroll_payments');
call app_private.secure_table('public.payroll_payments');
create trigger tg_audit after insert or update on public.payroll_payments
  for each row execute function app_private.tg_audit('entity_id', 'amount', 'reference', 'note');

create trigger tg_forbid_update before update on public.payroll_payment_lines
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.payroll_payment_lines
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.payroll_payment_lines
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_stamp_created before insert on public.payroll_payment_lines
  for each row execute function app_private.tg_stamp_created();
call app_private.secure_table('public.payroll_payment_lines');

-- ------------------------------------------------------------ positions
-- What has been paid on a line (confirmed payments only) and on the BPJS liability of a run.
create function app_private.payroll_line_paid(p_line uuid) returns numeric
language sql stable as $$
  select coalesce(sum(pl.amount), 0)
  from public.payroll_payment_lines pl
  join public.payroll_payments p on p.id = pl.payment_id and p.entity_id = pl.entity_id
  where pl.run_line_id = p_line and p.status = 'confirmed'
$$;

create function app_private.payroll_bpjs_paid(p_run uuid) returns numeric
language sql stable as $$
  select coalesce(sum(p.amount), 0) from public.payroll_payments p
  where p.run_id = p_run and p.kind = 'bpjs' and p.status = 'confirmed'
$$;

create function app_private.payroll_net_paid(p_run uuid) returns numeric
language sql stable as $$
  select coalesce(sum(p.amount), 0) from public.payroll_payments p
  where p.run_id = p_run and p.kind = 'net_pay' and p.status = 'confirmed'
$$;

-- Defence in depth for the capacity rule (Step 08 §13): whatever writes a payment, net pay paid on a line never
-- exceeds the net pay of the line, BPJS paid never exceeds the BPJS liability of the run, and the lines of a net pay
-- payment add up to its amount. Checked at commit, once the lines exist.
create function app_private.tg_payroll_payments_capacity() returns trigger
language plpgsql as $$
declare
  r public.payroll_runs%rowtype;
  v_lines numeric;
begin
  if new.status <> 'confirmed' then
    return new;
  end if;
  select * into r from public.payroll_runs where id = new.run_id;
  if new.kind = 'net_pay' then
    select coalesce(sum(pl.amount), 0) into v_lines from public.payroll_payment_lines pl where pl.payment_id = new.id;
    if v_lines <> new.amount then
      raise exception 'INVALID: the lines of a net pay payment must add up to the payment' using errcode = 'invalid_parameter_value';
    end if;
    if exists (select 1 from public.payroll_payment_lines pl
               join public.payroll_run_lines l on l.id = pl.run_line_id
               where pl.payment_id = new.id and app_private.payroll_line_paid(l.id) > l.net_pay) then
      raise exception 'INVALID: net pay paid would exceed the net pay of an employee' using errcode = 'invalid_parameter_value';
    end if;
  else
    if exists (select 1 from public.payroll_payment_lines pl where pl.payment_id = new.id) then
      raise exception 'INVALID: a BPJS payment has no employee lines' using errcode = 'invalid_parameter_value';
    end if;
    if app_private.payroll_bpjs_paid(new.run_id) > r.employee_bpjs_total + r.employer_bpjs_total then
      raise exception 'INVALID: BPJS paid would exceed the BPJS liability of the payroll run' using errcode = 'invalid_parameter_value';
    end if;
  end if;
  return new;
end
$$;
create constraint trigger tg_capacity after insert on public.payroll_payments
  deferrable initially deferred for each row execute function app_private.tg_payroll_payments_capacity();

-- The state of a posted run follows its net pay settlement (Step 07 §14).
create function app_private.payroll_refresh_status(p_run uuid) returns void
language plpgsql as $$
declare
  r public.payroll_runs%rowtype;
  v_paid numeric;
  v_new text;
begin
  select * into r from public.payroll_runs where id = p_run for update;
  if r.status not in ('posted', 'partially_paid', 'paid') then
    return;
  end if;
  v_paid := app_private.payroll_net_paid(p_run);
  v_new := case when v_paid >= r.net_pay_total and r.net_pay_total > 0 then 'paid'
                when v_paid > 0 then 'partially_paid'
                else 'posted' end;
  if v_new <> r.status then
    update public.payroll_runs set status = v_new where id = p_run;
  end if;
end
$$;

-- ------------------------------------------------------------ reconciliation of a run (Step 08 §13, Step 16 §18)
-- Gross, deductions, employee and employer components, tax, net pay and liabilities of a posted run against the
-- journal it created, the tax ledger and the payslips. An empty list means the run reconciles.
create function app_private.payroll_run_differences(p_run uuid) returns jsonb
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
    select coalesce(sum(jl.credit) filter (where a.system_key = 'BPJS_LIABILITY'), 0) into v_credit
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

revoke all on all functions in schema app_private from public;
