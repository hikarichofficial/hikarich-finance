-- P8 part 3a (Step 07 §12, Step 08 §12, Step 15 §12, Step 16 §17): the Loan Register - tables, guards and the
-- repayment-schedule arithmetic.
--
-- A loan is either BORROWED (a liability: LOAN_SHORT_TERM / LOAN_LONG_TERM, or PERSONAL_LOAN in a Personal Entity) or
-- LENT (a receivable on OTHER_RECEIVABLE). Principal, interest and fees are always separate (Step 01 #19, Step 04 §6).
--
-- Versioned terms: every loan has schedule VERSIONS. Version 1 holds the terms at signature; a restructuring adds a
-- new version and marks the previous one superseded - nothing is rewritten (Step 07 §12, Step 08 §12). Payments are
-- allocated to the schedule items of the version in force, and reversing a payment is only possible while that
-- version is still in force.
--
-- Interest is recognised when it is PAID (or written off), like every other cash workflow of this build: the schedule
-- carries the scheduled interest as information, and the period checks warn about interest that is past due
-- (DECISIONS 108).

-- ------------------------------------------------------------ the arithmetic of a schedule (pure)
create function app_private.rate_arg(p_text text, p_label text) returns numeric
language plpgsql immutable as $$
declare
  v numeric;
begin
  if p_text is null or btrim(p_text) !~ '^[0-9]{1,3}(\.[0-9]{1,6})?$' then
    raise exception 'INVALID: % must be a percentage between 0 and 100 with up to 6 decimals', p_label using errcode = 'invalid_parameter_value';
  end if;
  v := btrim(p_text)::numeric;
  if v > 100 then
    raise exception 'INVALID: % must be a percentage between 0 and 100 with up to 6 decimals', p_label using errcode = 'invalid_parameter_value';
  end if;
  return v;
end
$$;

-- One row per installment. p_rate is the annual percentage, p_step the months between installments.
--   annuity        equal total payments; the interest shrinks with the balance; the last installment clears the balance;
--   flat           the interest on the ORIGINAL principal every period, principal in equal parts;
--   interest_only  interest on the balance every period, the whole principal in the last installment.
create function app_private.loan_plan(
  p_method text, p_principal numeric, p_rate numeric, p_n integer, p_step integer, p_first date, p_scale integer)
returns table (seq integer, due_date date, principal numeric, interest numeric)
language plpgsql immutable as $$
declare
  v_r numeric := p_rate / 100 * p_step / 12;
  v_bal numeric := p_principal;
  v_pmt numeric;
  v_int numeric;
  v_prin numeric;
  k integer;
begin
  if p_method not in ('annuity', 'flat', 'interest_only') then
    raise exception 'INVALID: unknown schedule method %', p_method using errcode = 'invalid_parameter_value';
  end if;
  if p_principal <= 0 or p_n not between 1 and 600 or p_step not in (1, 3, 6, 12) then
    raise exception 'INVALID: a schedule needs a principal, 1 to 600 installments and a step of 1, 3, 6 or 12 months'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_method = 'annuity' then
    v_pmt := case when v_r = 0 then app_private.round_amount(p_principal / p_n, p_scale, 'half_up')
                  else app_private.round_amount(p_principal * v_r / (1 - power(1 + v_r, -p_n)), p_scale, 'half_up') end;
  end if;
  for k in 1..p_n loop
    if p_method = 'flat' then
      v_int := app_private.round_amount(p_principal * v_r, p_scale, 'half_up');
      v_prin := case when k = p_n then v_bal else least(app_private.round_amount(p_principal / p_n, p_scale, 'half_up'), v_bal) end;
    elsif p_method = 'interest_only' then
      v_int := app_private.round_amount(v_bal * v_r, p_scale, 'half_up');
      v_prin := case when k = p_n then v_bal else 0 end;
    else
      v_int := app_private.round_amount(v_bal * v_r, p_scale, 'half_up');
      v_prin := case when k = p_n then v_bal else least(greatest(v_pmt - v_int, 0), v_bal) end;
    end if;
    seq := k;
    due_date := (p_first + make_interval(months => (k - 1) * p_step))::date;
    principal := v_prin;
    interest := v_int;
    return next;
    v_bal := v_bal - v_prin;
  end loop;
end
$$;

-- ------------------------------------------------------------ loans
create table public.loans (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  loan_number text not null,
  direction text not null check (direction in ('borrowed', 'lent')),
  status text not null default 'draft' check (status in ('draft', 'active', 'closed', 'cancelled')),
  counterparty_name text not null check (length(btrim(counterparty_name)) between 1 and 200),
  contact_id uuid,
  purpose text not null check (length(btrim(purpose)) between 3 and 500),
  -- The agreed principal. `funded_principal` is what the ledger carries: the proceeds actually paid out or received, or
  -- the outstanding balance of a loan loaded at the cut-over.
  principal public.money_amount not null check (principal > 0),
  funded_principal public.money_amount not null default 0 check (funded_principal >= 0 and funded_principal <= principal),
  source_type text not null default 'proceeds' check (source_type in ('proceeds', 'opening')),
  agreement_date date not null,
  effective_date date,
  -- The ledger account of the balance: fixed for the life of the loan (short or long term is chosen when it is made).
  principal_account_id uuid not null,
  term_class text check (term_class is null or term_class in ('short', 'long')),
  financial_account_id uuid,
  proceeds_journal_id uuid,
  -- Asset financing (Step 01 #19): the asset the loan paid for. A link only - it posts nothing.
  asset_id uuid,
  related_entity_id uuid references public.entities (id) on delete restrict,
  relationship_basis text check (relationship_basis is null or length(relationship_basis) <= 300),
  closed_date date,
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancel_reason text check (cancel_reason is null or length(cancel_reason) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, contact_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, principal_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, proceeds_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, asset_id) references public.fixed_assets (entity_id, id) on delete restrict,
  constraint loan_state_shape check (
    case status
      when 'draft' then effective_date is null and funded_principal = 0 and cancelled_at is null and closed_date is null
      when 'active' then effective_date is not null and funded_principal > 0 and closed_date is null and cancelled_at is null
      when 'closed' then effective_date is not null and funded_principal > 0 and closed_date is not null and cancelled_at is null
      else effective_date is null and funded_principal = 0 and cancelled_at is not null and cancel_reason is not null end),
  constraint loan_source_shape check (
    case source_type
      when 'proceeds' then (status in ('draft', 'cancelled') or (financial_account_id is not null and proceeds_journal_id is not null))
      else financial_account_id is null and proceeds_journal_id is null end),
  constraint loan_lent_shape check (direction = 'borrowed' or (term_class is null and asset_id is null)),
  constraint loan_related check (
    related_entity_id is null or (related_entity_id <> entity_id and relationship_basis is not null))
);
create unique index loans_number_uq on public.loans (entity_id, loan_number);
create index loans_status_idx on public.loans (entity_id, direction, status);

create function app_private.tg_loans_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'funded_principal', 'effective_date', 'financial_account_id', 'proceeds_journal_id',
                                   'asset_id', 'closed_date', 'cancelled_at', 'cancelled_by', 'cancel_reason',
                                   'updated_at', 'updated_by', 'version'];
begin
  if tg_op = 'INSERT' then
    if new.status not in ('draft', 'active') or (new.status = 'active' and new.source_type <> 'opening') then
      raise exception 'A loan starts as a draft (or is loaded as an opening loan)' using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;
  if old.status = 'cancelled' then
    raise exception 'A cancelled loan cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a loan cannot be changed; restructure it instead' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status and (old.status, new.status) not in
     (('draft', 'active'), ('draft', 'cancelled'), ('active', 'closed'), ('closed', 'active')) then
    raise exception 'A loan cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  if old.status <> 'draft' and (new.funded_principal is distinct from old.funded_principal
                               or new.effective_date is distinct from old.effective_date
                               or new.financial_account_id is distinct from old.financial_account_id
                               or new.proceeds_journal_id is distinct from old.proceeds_journal_id) then
    raise exception 'The proceeds of a loan cannot change once it is active' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.loans
  for each row execute function app_private.tg_loans_guard();
create trigger tg_forbid_delete before delete on public.loans
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.loans
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.loans');
call app_private.secure_table('public.loans');
create trigger tg_audit after insert or update or delete on public.loans
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ schedule versions and their items
create table public.loan_schedule_versions (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  loan_id uuid not null,
  version_no integer not null check (version_no >= 1),
  status text not null default 'draft' check (status in ('draft', 'active', 'superseded')),
  method text not null check (method in ('annuity', 'flat', 'interest_only', 'manual')),
  -- Annual interest, percent. It is a term of the schedule, never a posting.
  rate numeric(9, 6) not null default 0 check (rate >= 0 and rate <= 100),
  installments integer not null check (installments between 1 and 600),
  step_months integer check (step_months is null or step_months in (1, 3, 6, 12)),
  effective_from date,
  -- What this version schedules: the whole principal for version 1, the outstanding principal for a restructuring.
  principal_basis public.money_amount not null check (principal_basis > 0),
  maturity_date date not null,
  reason text check (reason is null or length(reason) <= 1000),
  activated_at timestamptz,
  superseded_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (loan_id, version_no),
  foreign key (entity_id, loan_id) references public.loans (entity_id, id) on delete restrict,
  constraint loan_version_state check (
    case status when 'draft' then effective_from is null and activated_at is null and superseded_at is null
                when 'active' then effective_from is not null and activated_at is not null and superseded_at is null
                else effective_from is not null and activated_at is not null and superseded_at is not null end)
);
create unique index loan_version_active_uq on public.loan_schedule_versions (loan_id) where status = 'active';

create function app_private.tg_loan_versions_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'effective_from', 'activated_at', 'superseded_at', 'updated_at', 'updated_by', 'version'];
begin
  if tg_op = 'INSERT' then
    if new.status not in ('draft', 'active') then
      raise exception 'A schedule version starts as a draft or is active' using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'A schedule version cannot be changed; restructure the loan instead' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status and (old.status, new.status) not in (('draft', 'active'), ('active', 'superseded')) then
    raise exception 'A schedule version cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  if old.status = 'superseded' and new is distinct from old and (to_jsonb(new) - array['updated_at', 'updated_by', 'version'])
                                                           is distinct from (to_jsonb(old) - array['updated_at', 'updated_by', 'version']) then
    raise exception 'A superseded schedule cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.loan_schedule_versions
  for each row execute function app_private.tg_loan_versions_guard();
create trigger tg_forbid_delete before delete on public.loan_schedule_versions
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.loan_schedule_versions
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.loan_schedule_versions');
call app_private.secure_table('public.loan_schedule_versions');
create trigger tg_audit after insert or update or delete on public.loan_schedule_versions
  for each row execute function app_private.tg_audit('entity_id');

create table public.loan_schedule_items (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  loan_id uuid not null,
  version_id uuid not null,
  seq integer not null check (seq >= 1),
  due_date date not null,
  principal_due public.money_amount not null default 0 check (principal_due >= 0),
  interest_due public.money_amount not null default 0 check (interest_due >= 0),
  fee_due public.money_amount not null default 0 check (fee_due >= 0),
  created_at timestamptz not null default now(),
  unique (entity_id, id),
  unique (version_id, seq),
  foreign key (entity_id, loan_id) references public.loans (entity_id, id) on delete restrict,
  foreign key (entity_id, version_id) references public.loan_schedule_versions (entity_id, id) on delete restrict,
  constraint loan_item_not_empty check (principal_due + interest_due + fee_due > 0)
);
create index loan_items_due_idx on public.loan_schedule_items (entity_id, loan_id, due_date);
create trigger tg_forbid_update before update on public.loan_schedule_items
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.loan_schedule_items
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.loan_schedule_items
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.loan_schedule_items');
create trigger tg_audit after insert on public.loan_schedule_items
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ payments, write-offs and their allocation
create table public.loan_payments (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  loan_id uuid not null,
  payment_number text not null,
  kind text not null check (kind in ('repayment', 'write_off')),
  status text not null default 'active' check (status in ('active', 'reversed')),
  payment_date date not null,
  principal public.money_amount not null default 0 check (principal >= 0),
  interest public.money_amount not null default 0 check (interest >= 0),
  fee public.money_amount not null default 0 check (fee >= 0),
  financial_account_id uuid,
  -- The schedule in force when it was made: a payment is reversible only while that version is still in force.
  schedule_version_id uuid not null,
  note text check (note is null or length(note) <= 1000),
  tax_status text not null default 'not_applicable' check (tax_status in ('not_applicable', 'needs_review', 'reviewed')),
  tax_reviewed_at timestamptz,
  tax_reviewed_by uuid,
  tax_note text check (tax_note is null or length(tax_note) <= 1000),
  journal_id uuid not null,
  reversal_journal_id uuid,
  reversed_at timestamptz,
  reversed_date date,
  reversed_by uuid,
  reverse_reason text check (reverse_reason is null or length(reverse_reason) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, loan_id) references public.loans (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, schedule_version_id) references public.loan_schedule_versions (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint loan_payment_shape check (
    principal + interest + fee > 0 and
    case kind when 'repayment' then financial_account_id is not null
              else financial_account_id is null and principal > 0 and interest = 0 and fee = 0 and length(coalesce(note, '')) >= 5 end),
  constraint loan_payment_state check (
    (status = 'active' and reversal_journal_id is null and reversed_at is null)
    or (status = 'reversed' and reversal_journal_id is not null and reversed_at is not null and reversed_date is not null
        and reverse_reason is not null)),
  constraint loan_payment_tax_shape check (
    (tax_status = 'reviewed') = (tax_reviewed_at is not null and tax_reviewed_by is not null))
);
create unique index loan_payments_number_uq on public.loan_payments (entity_id, payment_number);
create index loan_payments_loan_idx on public.loan_payments (entity_id, loan_id, payment_date);

create function app_private.tg_loan_payments_guard() returns trigger
language plpgsql as $$
declare
  v_tax constant text[] := array['tax_status', 'tax_reviewed_at', 'tax_reviewed_by', 'tax_note', 'updated_at', 'updated_by', 'version'];
  v_lock constant text[] := v_tax || array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by', 'reverse_reason'];
begin
  if old.status = 'reversed' and (to_jsonb(new) - v_tax) is distinct from (to_jsonb(old) - v_tax) then
    raise exception 'A reversed payment cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a payment cannot be changed; reverse it instead' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status and (old.status, new.status) <> ('active', 'reversed') then
    raise exception 'A payment cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.loan_payments
  for each row execute function app_private.tg_loan_payments_guard();
create trigger tg_forbid_delete before delete on public.loan_payments
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.loan_payments
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.loan_payments');
call app_private.secure_table('public.loan_payments');
create trigger tg_audit after insert or update or delete on public.loan_payments
  for each row execute function app_private.tg_audit('entity_id');

-- Which schedule item each part of a payment settled. A null item is an amount beyond the schedule (interest charged
-- above the scheduled figure, say). Allocations are facts: reversing the payment turns them off, never edits them.
create table public.loan_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  loan_id uuid not null,
  payment_id uuid not null,
  item_id uuid,
  principal public.money_amount not null default 0 check (principal >= 0),
  interest public.money_amount not null default 0 check (interest >= 0),
  fee public.money_amount not null default 0 check (fee >= 0),
  created_at timestamptz not null default now(),
  unique (entity_id, id),
  foreign key (entity_id, loan_id) references public.loans (entity_id, id) on delete restrict,
  foreign key (entity_id, payment_id) references public.loan_payments (entity_id, id) on delete restrict,
  foreign key (entity_id, item_id) references public.loan_schedule_items (entity_id, id) on delete restrict,
  constraint loan_allocation_not_empty check (principal + interest + fee > 0)
);
create index loan_allocations_payment_idx on public.loan_payment_allocations (entity_id, payment_id);
create index loan_allocations_item_idx on public.loan_payment_allocations (entity_id, item_id);
create trigger tg_forbid_update before update on public.loan_payment_allocations
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.loan_payment_allocations
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.loan_payment_allocations
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.loan_payment_allocations');

-- Defence in depth (Step 08 §12): whatever writes a payment, the principal repaid never exceeds the principal the
-- ledger carries, and a payment is never dated before the proceeds.
create function app_private.tg_loan_payments_capacity() returns trigger
language plpgsql as $$
declare
  l public.loans%rowtype;
begin
  select * into l from public.loans where id = new.loan_id and entity_id = new.entity_id for update;
  if not found or l.status not in ('active', 'closed') then
    raise exception 'CONFLICT: only an active loan can be repaid' using errcode = 'integrity_constraint_violation';
  end if;
  if new.payment_date < l.effective_date then
    raise exception 'INVALID: a payment cannot be dated before the proceeds (%)', l.effective_date using errcode = 'invalid_parameter_value';
  end if;
  if (select coalesce(sum(p.principal), 0) from public.loan_payments p where p.loan_id = l.id and p.status = 'active') > l.funded_principal then
    raise exception 'INVALID: the payments would take the principal below zero' using errcode = 'invalid_parameter_value';
  end if;
  return new;
end
$$;
create constraint trigger tg_capacity after insert on public.loan_payments
  deferrable initially immediate for each row execute function app_private.tg_loan_payments_capacity();

-- ------------------------------------------------------------ what is outstanding
-- As of a date: repaid principal counts from its date until (and unless) it was reversed. Before the proceeds, and for a
-- draft or cancelled loan, nothing is outstanding.
create function app_private.loan_outstanding(p_loan uuid, p_as_of date default null)
returns numeric
language sql stable as $$
  select case when l.effective_date is null or l.status in ('draft', 'cancelled') or (p_as_of is not null and p_as_of < l.effective_date)
              then 0
         else l.funded_principal - coalesce((
           select sum(p.principal) from public.loan_payments p
           where p.loan_id = l.id and (p_as_of is null or p.payment_date <= p_as_of)
             and (p.status = 'active' or (p_as_of is not null and p.reversed_date > p_as_of))), 0) end
  from public.loans l
  where l.id = p_loan
$$;

-- The sub-ledger total of one direction (optionally one ledger account) as of a date.
create function app_private.loans_total(p_entity uuid, p_direction text, p_as_of date, p_account uuid default null)
returns numeric
language sql stable as $$
  select coalesce(sum(app_private.loan_outstanding(l.id, p_as_of)), 0)
  from public.loans l
  where l.entity_id = p_entity and l.direction = p_direction and l.status in ('active', 'closed')
    and l.effective_date <= p_as_of and (p_account is null or l.principal_account_id = p_account)
$$;

-- The state of every schedule item as of a date (the version in force, or a given one).
create function app_private.loan_items(p_loan uuid, p_version uuid default null, p_as_of date default null)
returns table (item_id uuid, version_id uuid, seq integer, due_date date, principal_due numeric, interest_due numeric,
               fee_due numeric, paid_principal numeric, paid_interest numeric, paid_fee numeric, state text, overdue boolean)
language sql stable as $$
  with asof as (select coalesce(p_as_of, app_private.entity_today(l.entity_id)) as d, l.id as loan_id, l.entity_id
                from public.loans l where l.id = p_loan),
  ver as (select v.id from public.loan_schedule_versions v
          where v.loan_id = p_loan and ((p_version is null and v.status = 'active') or v.id = p_version)),
  paid as (
    select a.item_id, sum(a.principal) as pp, sum(a.interest) as pi, sum(a.fee) as pf
    from public.loan_payment_allocations a
    join public.loan_payments p on p.id = a.payment_id and p.entity_id = a.entity_id
    cross join asof
    where a.loan_id = p_loan and a.item_id is not null and p.payment_date <= asof.d
      and (p.status = 'active' or p.reversed_date > asof.d)
    group by a.item_id)
  select i.id, i.version_id, i.seq, i.due_date, i.principal_due, i.interest_due, i.fee_due,
         coalesce(pd.pp, 0), coalesce(pd.pi, 0), coalesce(pd.pf, 0),
         case when coalesce(pd.pp, 0) >= i.principal_due and coalesce(pd.pi, 0) >= i.interest_due and coalesce(pd.pf, 0) >= i.fee_due then 'paid'
              when coalesce(pd.pp, 0) + coalesce(pd.pi, 0) + coalesce(pd.pf, 0) > 0 then 'partially_paid'
              when i.due_date <= asof.d then 'due'
              else 'scheduled' end,
         (i.due_date < asof.d and not (coalesce(pd.pp, 0) >= i.principal_due and coalesce(pd.pi, 0) >= i.interest_due and coalesce(pd.pf, 0) >= i.fee_due))
  from public.loan_schedule_items i
  join ver on ver.id = i.version_id
  cross join asof
  left join paid pd on pd.item_id = i.id
  order by i.seq
$$;

create function app_private.ensure_loan_numbering(p_entity uuid) returns void
language plpgsql as $$
begin
  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (p_entity, 'loan', 'LN'),
         (p_entity, 'loan_payment', 'LPY')
  on conflict (entity_id, scope) do nothing;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.loans');
create policy loans_select on public.loans for select to authenticated
  using (app_authz.has_permission(entity_id, 'loans.view'));
call app_private.expose_select('public.loan_schedule_versions');
create policy loan_schedule_versions_select on public.loan_schedule_versions for select to authenticated
  using (app_authz.has_permission(entity_id, 'loans.view'));
call app_private.expose_select('public.loan_schedule_items');
create policy loan_schedule_items_select on public.loan_schedule_items for select to authenticated
  using (app_authz.has_permission(entity_id, 'loans.view'));
call app_private.expose_select('public.loan_payments');
create policy loan_payments_select on public.loan_payments for select to authenticated
  using (app_authz.has_permission(entity_id, 'loans.view'));
call app_private.expose_select('public.loan_payment_allocations');
create policy loan_payment_allocations_select on public.loan_payment_allocations for select to authenticated
  using (app_authz.has_permission(entity_id, 'loans.view'));

revoke all on function app_private.rate_arg(text, text) from public;
revoke all on function app_private.loan_plan(text, numeric, numeric, integer, integer, date, integer) from public;
revoke all on function app_private.tg_loans_guard() from public;
revoke all on function app_private.tg_loan_versions_guard() from public;
revoke all on function app_private.tg_loan_payments_guard() from public;
revoke all on function app_private.tg_loan_payments_capacity() from public;
revoke all on function app_private.loan_outstanding(uuid, date) from public;
revoke all on function app_private.loans_total(uuid, text, date, uuid) from public;
revoke all on function app_private.loan_items(uuid, uuid, date) from public;
revoke all on function app_private.ensure_loan_numbering(uuid) from public;
