-- P8 part 4a (Step 07 §13, Step 04 §6, Step 15 §12): capital and equity events - tables and guards.
--
-- Company events: a CONTRIBUTION (cash in, equity up), a CAPITAL RETURN (cash out, equity down) and a DIVIDEND
-- (declaration creates the payable; payments settle it, in parts). Personal events: an INVESTMENT CONTRIBUTION and an
-- INVESTMENT RETURN (the owner's side of a contribution to, or a return from, a company) and a DISTRIBUTION RECEIVED
-- (the dividend or distribution income). None of them is revenue or operating expense (Step 01 #20).
--
-- Workflow: draft -> confirmed (posts) -> reversed; a draft can be cancelled. A capital return and a dividend need the
-- extra `equity.approve` right and a recent step-up, so a person who may record contributions cannot pay money out of
-- the company's equity. The tax consequence of a dividend or a capital return is never guessed: it is flagged for
-- review (DECISIONS 106), like the interest of a loan.

-- ------------------------------------------------------------ the approval right
insert into public.permissions (key, module, action, description)
values ('equity.approve', 'equity', 'approve', 'Approve capital returns and dividends');

create function app_private.ensure_equity_numbering(p_entity uuid) returns void
language plpgsql as $$
begin
  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (p_entity, 'equity', 'EQ')
  on conflict (entity_id, scope) do nothing;
end
$$;

-- ------------------------------------------------------------ equity events
create table public.equity_events (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  event_number text not null,
  kind text not null check (kind in ('contribution', 'capital_return', 'dividend',
                                     'investment_contribution', 'investment_return', 'distribution_received')),
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'reversed', 'cancelled')),
  event_date date not null,
  amount public.money_amount not null check (amount > 0),
  -- Which company equity account a contribution or capital return moves: OWNER_CAPITAL or ADDITIONAL_EQUITY.
  equity_class text check (equity_class is null or equity_class in ('capital', 'additional')),
  counterparty_name text not null check (length(btrim(counterparty_name)) between 1 and 200),
  contact_id uuid,
  purpose text not null check (length(btrim(purpose)) between 3 and 500),
  -- The shareholder resolution (RUPS) or other authority for a capital return or a dividend.
  resolution_reference text check (resolution_reference is null or length(btrim(resolution_reference)) between 3 and 200),
  financial_account_id uuid,
  journal_id uuid,
  confirmed_at timestamptz,
  confirmed_by uuid,
  -- A dividend that exceeds the profit available is allowed but flagged (never silently): the figure at confirmation.
  retained_available numeric(20, 4),
  exceeds_retained_earnings boolean not null default false,
  tax_status text not null default 'not_applicable' check (tax_status in ('not_applicable', 'needs_review', 'reviewed')),
  tax_reviewed_at timestamptz,
  tax_reviewed_by uuid,
  tax_note text check (tax_note is null or length(tax_note) <= 1000),
  reversal_journal_id uuid,
  reversed_at timestamptz,
  reversed_date date,
  reversed_by uuid,
  reverse_reason text check (reverse_reason is null or length(reverse_reason) <= 1000),
  cancelled_at timestamptz,
  cancelled_by uuid,
  cancel_reason text check (cancel_reason is null or length(cancel_reason) <= 1000),
  -- PT <-> Personal analytics tag (never a posting).
  related_entity_id uuid references public.entities (id) on delete restrict,
  relationship_basis text check (relationship_basis is null or length(relationship_basis) <= 300),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, contact_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint equity_class_shape check ((kind in ('contribution', 'capital_return')) = (equity_class is not null)),
  constraint equity_resolution_shape check (kind not in ('capital_return', 'dividend') or resolution_reference is not null),
  constraint equity_cash_shape check (
    status not in ('confirmed', 'reversed') or (kind = 'dividend') = (financial_account_id is null)),
  constraint equity_state_shape check (
    case status
      when 'draft' then journal_id is null and confirmed_at is null and reversal_journal_id is null and cancelled_at is null
      when 'confirmed' then journal_id is not null and confirmed_at is not null and reversal_journal_id is null and cancelled_at is null
      when 'reversed' then journal_id is not null and confirmed_at is not null and reversal_journal_id is not null
                           and reversed_at is not null and reversed_date is not null and reverse_reason is not null
      else journal_id is null and cancelled_at is not null and cancel_reason is not null end),
  constraint equity_related check (
    related_entity_id is null or (related_entity_id <> entity_id and relationship_basis is not null)),
  constraint equity_tax_shape check ((tax_status = 'reviewed') = (tax_reviewed_at is not null and tax_reviewed_by is not null))
);
create unique index equity_events_number_uq on public.equity_events (entity_id, event_number);
create index equity_events_kind_idx on public.equity_events (entity_id, kind, status, event_date);

create function app_private.tg_equity_events_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'financial_account_id', 'journal_id', 'confirmed_at', 'confirmed_by', 'retained_available',
                                   'exceeds_retained_earnings', 'tax_status', 'tax_reviewed_at', 'tax_reviewed_by', 'tax_note',
                                   'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by', 'reverse_reason',
                                   'cancelled_at', 'cancelled_by', 'cancel_reason', 'updated_at', 'updated_by', 'version'];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'An equity event starts as a draft' using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;
  if old.status in ('reversed', 'cancelled') and (to_jsonb(new) - array['tax_status', 'tax_reviewed_at', 'tax_reviewed_by', 'tax_note',
                                                                          'updated_at', 'updated_by', 'version'])
                                               is distinct from (to_jsonb(old) - array['tax_status', 'tax_reviewed_at', 'tax_reviewed_by',
                                                                                        'tax_note', 'updated_at', 'updated_by', 'version']) then
    raise exception 'A reversed or cancelled equity event cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of an equity event cannot be changed; reverse it instead' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status and (old.status, new.status) not in
     (('draft', 'confirmed'), ('draft', 'cancelled'), ('confirmed', 'reversed')) then
    raise exception 'An equity event cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  if old.status = 'confirmed' and new.status = 'confirmed'
     and (new.journal_id is distinct from old.journal_id or new.financial_account_id is distinct from old.financial_account_id) then
    raise exception 'The posting of a confirmed equity event cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.equity_events
  for each row execute function app_private.tg_equity_events_guard();
create trigger tg_forbid_delete before delete on public.equity_events
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.equity_events
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.equity_events');
call app_private.secure_table('public.equity_events');
create trigger tg_audit after insert or update or delete on public.equity_events
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ dividend payments (they settle the payable)
create table public.equity_dividend_payments (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  event_id uuid not null,
  payment_number text not null,
  status text not null default 'active' check (status in ('active', 'reversed')),
  payment_date date not null,
  amount public.money_amount not null check (amount > 0),
  financial_account_id uuid not null,
  note text check (note is null or length(note) <= 1000),
  -- Withholding on what is paid out is a tax consequence of the actual payment: flagged for review, never guessed.
  tax_status text not null default 'needs_review' check (tax_status in ('not_applicable', 'needs_review', 'reviewed')),
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
  foreign key (entity_id, event_id) references public.equity_events (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint dividend_payment_state check (
    (status = 'active' and reversal_journal_id is null and reversed_at is null)
    or (status = 'reversed' and reversal_journal_id is not null and reversed_at is not null and reversed_date is not null
        and reverse_reason is not null)),
  constraint dividend_payment_tax_shape check ((tax_status = 'reviewed') = (tax_reviewed_at is not null and tax_reviewed_by is not null))
);
create unique index dividend_payments_number_uq on public.equity_dividend_payments (entity_id, payment_number);
create index dividend_payments_event_idx on public.equity_dividend_payments (entity_id, event_id, payment_date);

create function app_private.tg_dividend_payments_guard() returns trigger
language plpgsql as $$
declare
  v_tax constant text[] := array['tax_status', 'tax_reviewed_at', 'tax_reviewed_by', 'tax_note', 'updated_at', 'updated_by', 'version'];
  v_lock constant text[] := v_tax || array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by', 'reverse_reason'];
begin
  if old.status = 'reversed' and (to_jsonb(new) - v_tax) is distinct from (to_jsonb(old) - v_tax) then
    raise exception 'A reversed dividend payment cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a dividend payment cannot be changed; reverse it instead' using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status and (old.status, new.status) <> ('active', 'reversed') then
    raise exception 'A dividend payment cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.equity_dividend_payments
  for each row execute function app_private.tg_dividend_payments_guard();
create trigger tg_forbid_delete before delete on public.equity_dividend_payments
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.equity_dividend_payments
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.equity_dividend_payments');
call app_private.secure_table('public.equity_dividend_payments');
create trigger tg_audit after insert or update or delete on public.equity_dividend_payments
  for each row execute function app_private.tg_audit('entity_id');

-- Defence in depth: whatever writes a payment, it settles a confirmed dividend and never more than was declared.
create function app_private.tg_dividend_payments_capacity() returns trigger
language plpgsql as $$
declare
  e public.equity_events%rowtype;
begin
  select * into e from public.equity_events where id = new.event_id and entity_id = new.entity_id for update;
  if not found or e.kind <> 'dividend' or e.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed dividend can be paid' using errcode = 'integrity_constraint_violation';
  end if;
  if new.payment_date < e.event_date then
    raise exception 'INVALID: a payment cannot be dated before the declaration (%)', e.event_date using errcode = 'invalid_parameter_value';
  end if;
  if (select coalesce(sum(p.amount), 0) from public.equity_dividend_payments p where p.event_id = e.id and p.status = 'active') > e.amount then
    raise exception 'INVALID: the payments would exceed the dividend declared' using errcode = 'invalid_parameter_value';
  end if;
  return new;
end
$$;
create constraint trigger tg_capacity after insert on public.equity_dividend_payments
  deferrable initially immediate for each row execute function app_private.tg_dividend_payments_capacity();

-- ------------------------------------------------------------ what is owed, and what profit is available
-- The unpaid part of a declared dividend as of a date (declared and not reversed by then, less payments not reversed by then).
create function app_private.dividend_outstanding(p_event uuid, p_as_of date default null)
returns numeric
language sql stable as $$
  select case when e.kind <> 'dividend' or e.status not in ('confirmed', 'reversed') or (p_as_of is not null and p_as_of < e.event_date)
                   or (e.status = 'reversed' and (p_as_of is null or e.reversed_date <= p_as_of))
              then 0
         else e.amount - coalesce((
           select sum(p.amount) from public.equity_dividend_payments p
           where p.event_id = e.id and (p_as_of is null or p.payment_date <= p_as_of)
             and (p.status = 'active' or (p_as_of is not null and p.reversed_date > p_as_of))), 0) end
  from public.equity_events e
  where e.id = p_event
$$;

create function app_private.dividends_payable_total(p_entity uuid, p_as_of date) returns numeric
language sql stable as $$
  select coalesce(sum(app_private.dividend_outstanding(e.id, p_as_of)), 0)
  from public.equity_events e
  where e.entity_id = p_entity and e.kind = 'dividend' and e.status in ('confirmed', 'reversed') and e.event_date <= p_as_of
$$;

-- The profit a company has available to distribute: retained earnings and the current-year result, plus the profit and
-- loss accounts not closed into them yet (credit positive).
create function app_private.retained_available(p_entity uuid, p_as_of date default null) returns numeric
language sql stable as $$
  select coalesce(sum(l.credit - l.debit), 0)
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id and j.status = 'posted'
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and (p_as_of is null or j.entry_date <= p_as_of)
    and (a.system_key in ('RETAINED_EARNINGS', 'CURRENT_YEAR_EARNINGS')
         or a.account_class in ('revenue', 'contra_revenue', 'expense', 'other_income', 'other_expense', 'other', 'tax'))
$$;

-- The balance of one ledger account, as of a date, on its normal side (debit or credit).
create function app_private.account_balance(p_entity uuid, p_account uuid, p_as_of date default null) returns numeric
language sql stable as $$
  select coalesce(sum(case a.normal_balance when 'debit' then l.debit - l.credit else l.credit - l.debit end), 0)
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id and j.status = 'posted'
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and l.ledger_account_id = p_account and (p_as_of is null or j.entry_date <= p_as_of)
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.equity_events');
create policy equity_events_select on public.equity_events for select to authenticated
  using (app_authz.has_permission(entity_id, 'equity.view'));
call app_private.expose_select('public.equity_dividend_payments');
create policy equity_dividend_payments_select on public.equity_dividend_payments for select to authenticated
  using (app_authz.has_permission(entity_id, 'equity.view'));

revoke all on function app_private.ensure_equity_numbering(uuid) from public;
revoke all on function app_private.tg_equity_events_guard() from public;
revoke all on function app_private.tg_dividend_payments_guard() from public;
revoke all on function app_private.tg_dividend_payments_capacity() from public;
revoke all on function app_private.dividend_outstanding(uuid, date) from public;
revoke all on function app_private.dividends_payable_total(uuid, date) from public;
revoke all on function app_private.retained_available(uuid, date) from public;
revoke all on function app_private.account_balance(uuid, uuid, date) from public;
