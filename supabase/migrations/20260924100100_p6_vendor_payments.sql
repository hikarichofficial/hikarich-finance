-- P6 (Step 15 §10) part 2: vendor payments, settlement state, cancel/void/correct and the AP control.
-- Authority: Step 04 §4/§13 (purchase and payment posting, sub-ledger reconciliation), Step 07 §5/§6 (bill and
-- payment workflows), Step 08 §8/§9 (AP and payment integrity), Step 06 §3 (bills.pay, bills.void).
--
-- Model (mirror of the sales side, P5)
--   * A vendor payment is a CONFIRMED fact: money left one financial account on a date for one vendor. It is
--     written only by trusted server code together with its journal, its money movement and its allocations, in
--     one transaction. Nothing is "pending": a draft payment has no accounting meaning.
--   * Allocations link a payment to approved bills. Paid / partially paid / outstanding are DERIVED from active
--     allocations; nothing overwrites the bill's workflow state. The payment amount always equals the sum of its
--     allocations: vendor advances and vendor credits are not part of this phase (decision 77).
--   * Everything is in the payment's own currency; payment, bill and account must share it. A difference between
--     the base value booked for the bill and the base value paid is an explicit FX gain/loss line.

-- ------------------------------------------------------------ vendor payments
create table public.vendor_payments (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  payment_number text not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'reversed')),
  vendor_id uuid not null,
  financial_account_id uuid not null,
  currency public.currency_code not null,
  amount public.money_amount not null check (amount > 0),
  exchange_rate public.fx_rate,
  -- Cash side in base currency, as the money movement and the journal booked it.
  base_amount public.money_amount not null check (base_amount > 0),
  payment_date date not null,
  reference text check (reference is null or length(reference) <= 200),
  payment_channel_id uuid,
  note text check (note is null or length(note) <= 1000),
  -- Base value gained (+) or lost (-) between what the bills booked and what was paid.
  fx_difference public.money_amount not null default 0,
  journal_id uuid not null,
  reversal_journal_id uuid,
  reversed_at timestamptz,
  reversed_date date,
  reversed_by uuid,
  reverse_reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, vendor_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id, currency)
    references public.financial_accounts (entity_id, id, currency) on delete restrict,
  foreign key (entity_id, payment_channel_id) references public.payment_channels (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint vendor_payment_state_consistent check (
    (status = 'confirmed' and reversal_journal_id is null and reversed_at is null)
    or (status = 'reversed' and reversal_journal_id is not null and reversed_at is not null
        and reversed_date is not null and reverse_reason is not null))
);
create unique index vendor_payments_number_uq on public.vendor_payments (entity_id, payment_number);
create index vendor_payments_entity_date_idx on public.vendor_payments (entity_id, payment_date);
create index vendor_payments_vendor_idx on public.vendor_payments (entity_id, vendor_id);
create index vendor_payments_account_idx on public.vendor_payments (entity_id, financial_account_id);

-- The economics of a confirmed payment never change; only the one-way step to "reversed" is allowed.
create function app_private.tg_vendor_payments_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by',
                                   'reverse_reason', 'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' then
    raise exception 'A reversed vendor payment cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a confirmed vendor payment cannot be changed; reverse it instead'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.vendor_payments
  for each row execute function app_private.tg_vendor_payments_guard();
create trigger tg_forbid_delete before delete on public.vendor_payments
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.vendor_payments
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.vendor_payments');
call app_private.secure_table('public.vendor_payments');
create trigger tg_audit after insert or update or delete on public.vendor_payments
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ allocations
create table public.vendor_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  payment_id uuid not null,
  bill_id uuid not null,
  -- In the bill (= payment) currency.
  amount public.money_amount not null check (amount > 0),
  -- Payable relieved, in base currency, at the bill's own booked value.
  base_ap_amount public.money_amount not null check (base_ap_amount >= 0),
  allocation_date date not null,
  journal_id uuid not null,
  status text not null default 'active' check (status in ('active', 'reversed')),
  reversed_at timestamptz,
  reversed_date date,
  reversal_journal_id uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, payment_id) references public.vendor_payments (entity_id, id) on delete restrict,
  foreign key (entity_id, bill_id) references public.bills (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint vendor_allocation_reversed_shape check (
    (status = 'active' and reversed_at is null and reversed_date is null and reversal_journal_id is null)
    or (status = 'reversed' and reversed_at is not null and reversed_date is not null
        and reversal_journal_id is not null))
);
create index vendor_allocations_bill_idx on public.vendor_payment_allocations (entity_id, bill_id, status);
create index vendor_allocations_payment_idx on public.vendor_payment_allocations (entity_id, payment_id, status);

create function app_private.tg_vendor_allocations_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversed_at', 'reversed_date', 'reversal_journal_id',
                                   'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' then
    raise exception 'A reversed allocation cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'An allocation cannot be edited; reverse the payment' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.vendor_payment_allocations
  for each row execute function app_private.tg_vendor_allocations_guard();
create trigger tg_forbid_delete before delete on public.vendor_payment_allocations
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.vendor_payment_allocations
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.vendor_payment_allocations');
call app_private.secure_table('public.vendor_payment_allocations');
create trigger tg_audit after insert or update or delete on public.vendor_payment_allocations
  for each row execute function app_private.tg_audit('entity_id');

-- A bill can never be over-paid, whoever writes the allocation (Step 08 §8: outstanding never negative). The bill
-- row is locked first, so two concurrent allocations serialise.
create function app_private.tg_vendor_allocations_capacity() returns trigger
language plpgsql as $$
declare
  b public.bills%rowtype;
  pay public.vendor_payments%rowtype;
  v_amount numeric;
  v_base numeric;
begin
  select * into b from public.bills where id = new.bill_id and entity_id = new.entity_id for update;
  if not found or b.status <> 'approved' then
    raise exception 'CONFLICT: only an approved bill can receive an allocation' using errcode = 'integrity_constraint_violation';
  end if;
  -- The payment and the bill must agree on who is paid, in what currency, and the allocation on the payment's date.
  select * into pay from public.vendor_payments where id = new.payment_id and entity_id = new.entity_id;
  if not found or pay.vendor_id <> b.vendor_id or pay.currency <> b.currency or pay.payment_date <> new.allocation_date then
    raise exception 'CONFLICT: the allocation does not match its payment (vendor, currency or date)'
      using errcode = 'integrity_constraint_violation';
  end if;
  select coalesce(sum(a.amount), 0), coalesce(sum(a.base_ap_amount), 0) into v_amount, v_base
  from public.vendor_payment_allocations a where a.bill_id = new.bill_id and a.status = 'active';
  if v_amount + new.amount > b.total or v_base + new.base_ap_amount > b.base_total then
    raise exception 'CONFLICT: the allocation exceeds what is outstanding on bill %', b.bill_number
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_capacity before insert on public.vendor_payment_allocations
  for each row execute function app_private.tg_vendor_allocations_capacity();

-- ------------------------------------------------------------ derived figures
-- Settled amount of one bill, as of a date (allocations dated on or before it that were not reversed by then).
create function app_private.bill_settled(p_bill uuid, p_as_of date default null)
returns table (settled numeric, base_settled numeric)
language sql stable as $$
  select coalesce(sum(a.amount), 0), coalesce(sum(a.base_ap_amount), 0)
  from public.vendor_payment_allocations a
  where a.bill_id = p_bill
    and (p_as_of is null
         and a.status = 'active'
         or p_as_of is not null and a.allocation_date <= p_as_of
            and (a.status = 'active' or a.reversed_date > p_as_of))
$$;

-- Positions of the Entity's bills at a date: settlement and overdue are DERIVED here, never stored (Step 07 §5).
-- A void bill counts as recognised before the day it was voided and as zero afterwards.
create function app_private.bill_positions(p_entity uuid, p_as_of date default null)
returns table (
  bill_id uuid, bill_number text, vendor_id uuid, vendor_reference text, currency public.currency_code, status text,
  bill_date date, due_date date, total numeric, settled numeric, outstanding numeric, base_total numeric,
  base_settled numeric, base_outstanding numeric, settlement_status text, is_overdue boolean, days_overdue integer)
language plpgsql stable as $$
declare
  v_asof date := coalesce(p_as_of, app_private.entity_today(p_entity));
begin
  return query
  with base as (
    select b.*,
           (b.status = 'void' and b.closed_date <= v_asof) as is_closed,
           s.settled as s_settled, s.base_settled as s_base_settled
    from public.bills b
    cross join lateral app_private.bill_settled(b.id, v_asof) s
    where b.entity_id = p_entity and b.bill_number is not null and b.bill_date <= v_asof
  )
  select b.id, b.bill_number, b.vendor_id, b.vendor_reference, b.currency,
         case when b.status = 'void' and not b.is_closed then 'approved' else b.status end,
         b.bill_date, b.due_date, b.total::numeric, b.s_settled,
         case when b.is_closed then 0 else b.total - b.s_settled end,
         b.base_total::numeric, b.s_base_settled,
         case when b.is_closed then 0 else b.base_total - b.s_base_settled end,
         case when b.is_closed then null
              when b.total - b.s_settled = 0 then 'paid'
              when b.s_settled = 0 then 'unpaid'
              else 'partial' end,
         (not b.is_closed and b.total - b.s_settled > 0 and b.due_date < v_asof),
         case when not b.is_closed and b.total - b.s_settled > 0 and b.due_date < v_asof then v_asof - b.due_date else 0 end
  from base b;
end
$$;

-- ------------------------------------------------------------ AP control (Step 04 §13)
-- Sub-ledger (from bills and allocations) against the General Ledger, restricted to journals that the purchase
-- workflow itself produced (and their reversals): opening balances and other sources are shown separately.
create function app_private.is_purchase_journal(p_journal uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.journal_entries j
    where j.id = p_journal
      and (j.source_type in ('bill', 'vendor_payment')
           or exists (select 1 from public.journal_entries o
                      where o.id = j.reverses_journal_id and o.source_type in ('bill', 'vendor_payment'))))
$$;

create function app_private.ap_control(p_entity uuid, p_as_of date default null)
returns table (sub_ledger numeric, ledger_purchases numeric, ledger_total numeric)
language plpgsql stable as $$
declare
  v_asof date := coalesce(p_as_of, app_private.entity_today(p_entity));
  v_sub numeric;
  v_ledger_purchases numeric;
  v_ledger_total numeric;
begin
  select coalesce(sum(p.base_outstanding), 0) into v_sub from app_private.bill_positions(p_entity, v_asof) p;

  select coalesce(sum(l.credit - l.debit), 0),
         coalesce(sum(l.credit - l.debit) filter (where app_private.is_purchase_journal(j.id)), 0)
    into v_ledger_total, v_ledger_purchases
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = 'ACCOUNTS_PAYABLE' and j.status = 'posted' and j.entry_date <= v_asof;

  return query select v_sub, v_ledger_purchases, v_ledger_total;
end
$$;

-- ------------------------------------------------------------ paying bills (the one writer)
-- `p_allocations` is a list of {bill_id, amount}; amounts are in the payment currency, which must equal the bills'
-- and the paying account's. The payment amount must equal the sum of the allocations.
create function public.record_vendor_payment(
  p_entity uuid, p_key text, p_vendor uuid, p_account uuid, p_date date, p_amount numeric, p_allocations jsonb,
  p_rate numeric default null, p_reference text default null, p_channel uuid default null, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  fa public.financial_accounts%rowtype;
  c public.contacts%rowtype;
  r record;
  v_replay uuid;
  v_base public.currency_code;
  v_bscale integer;
  v_ascale integer;
  v_today date;
  v_ids uuid[] := '{}';
  v_amts numeric[] := '{}';
  v_elem jsonb;
  v_id uuid;
  v_amt numeric;
  v_n integer := 0;
  v_rem_amount numeric;
  v_rem_base numeric;
  v_settled numeric;
  v_base_settled numeric;
  v_last_rev date;
  v_alloc_bills uuid[] := '{}';
  v_alloc_amts numeric[] := '{}';
  v_alloc_bases numeric[] := '{}';
  v_alloc_sum numeric := 0;
  v_ap_sum numeric := 0;
  v_base_ap numeric;
  v_cash_base numeric;
  v_fx numeric := 0;
  v_ap uuid;
  v_fx_acct uuid;
  v_payment uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  k integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.pay') then
    raise exception 'FORBIDDEN: missing bills.pay' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('vendor_payment.record', p_entity, p_key,
    md5(jsonb_build_object('vendor', p_vendor, 'account', p_account, 'date', p_date, 'amount', p_amount,
                           'alloc', p_allocations, 'rate', p_rate, 'ref', p_reference, 'channel', p_channel,
                           'note', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform app_private.assert_maker_checker(p_entity, 'bills', 'pay',
                                           app_private.approval_base_amount(p_entity, p_amount, p_rate), auth.uid(),
                                           'pay this bill');

  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_base := e.base_currency;
  v_bscale := app_private.currency_scale(v_base);
  v_today := app_private.entity_today(p_entity);

  select * into c from public.contacts where id = p_vendor and entity_id = p_entity;
  if not found or c.kind not in ('vendor', 'both') then
    raise exception 'INVALID: the payee is unknown or is not a vendor of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
  if not found or not fa.is_active then
    raise exception 'INVALID: the paying account is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;
  v_ascale := app_private.currency_scale(fa.currency);

  perform app_private.assert_business_date(p_date);
  if p_date > v_today then
    raise exception 'INVALID: a payment cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_amount is null or not app_private.is_finite(p_amount) or p_amount <= 0 or p_amount >= 10::numeric ^ 13
     or app_private.round_amount(p_amount, v_ascale, 'down') <> p_amount then
    raise exception 'INVALID: the payment amount must be positive and allows % decimals for %', v_ascale, fa.currency
      using errcode = 'invalid_parameter_value';
  end if;
  if (fa.currency = v_base) <> (p_rate is null) then
    raise exception 'INVALID: an exchange rate is required for a foreign-currency account, and only then'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_rate is not null and (not app_private.is_finite(p_rate) or p_rate <= 0 or p_rate >= 10::numeric ^ 10
                             or app_private.round_amount(p_rate, 10, 'down') <> p_rate) then
    raise exception 'INVALID: the exchange rate must be positive with at most 10 decimals' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(v_ref, '')) > 200 or length(coalesce(v_note, '')) > 1000 then
    raise exception 'INVALID: the reference is limited to 200 and the note to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_channel is not null and not exists (
       select 1 from public.payment_channels ch where ch.id = p_channel and ch.entity_id = p_entity and ch.is_active) then
    raise exception 'INVALID: the payment channel is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;

  -- Parse the allocation list.
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' or jsonb_array_length(p_allocations) = 0 then
    raise exception 'INVALID: a vendor payment needs at least one bill to pay' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_allocations) > 100 then
    raise exception 'INVALID: a payment can be allocated to at most 100 bills' using errcode = 'invalid_parameter_value';
  end if;
  for v_elem in select value from jsonb_array_elements(p_allocations) loop
    v_n := v_n + 1;
    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'INVALID: allocation % is not an object', v_n using errcode = 'invalid_parameter_value';
    end if;
    begin
      v_id := (v_elem ->> 'bill_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'INVALID: allocation % has an invalid bill', v_n using errcode = 'invalid_parameter_value';
    end;
    if v_id is null then
      raise exception 'INVALID: allocation % needs a bill', v_n using errcode = 'invalid_parameter_value';
    end if;
    if v_id = any (v_ids) then
      raise exception 'INVALID: a bill can appear only once in the allocations' using errcode = 'invalid_parameter_value';
    end if;
    v_amt := app_private.parse_amount(v_elem ->> 'amount', format('allocation %s amount', v_n));
    if v_amt <= 0 or app_private.round_amount(v_amt, v_ascale, 'down') <> v_amt then
      raise exception 'INVALID: allocation % must be positive and allows % decimals for %', v_n, v_ascale, fa.currency
        using errcode = 'invalid_parameter_value';
    end if;
    v_ids := v_ids || v_id;
    v_amts := v_amts || v_amt;
  end loop;

  -- Lock the bills in a fixed order (two payments over the same bills can never deadlock), then validate and
  -- split each allocation against what is outstanding NOW.
  v_n := 0;
  for r in
    select b.id, b.bill_number, b.status, b.vendor_id, b.currency, b.bill_date, b.total, b.base_total, b.exchange_rate,
           x.amt
    from public.bills b
    join unnest(v_ids, v_amts) as x(id, amt) on x.id = b.id
    where b.entity_id = p_entity
    order by b.id
    for update of b
  loop
    v_n := v_n + 1;
    if r.status <> 'approved' then
      raise exception 'CONFLICT: bill % is % and cannot be paid', coalesce(r.bill_number, 'a draft'), r.status
        using errcode = 'integrity_constraint_violation';
    end if;
    if r.vendor_id <> p_vendor then
      raise exception 'INVALID: bill % belongs to a different vendor', r.bill_number using errcode = 'invalid_parameter_value';
    end if;
    if r.currency <> fa.currency then
      raise exception 'INVALID: bill % is in % but the paying account is in %', r.bill_number, r.currency, fa.currency
        using errcode = 'invalid_parameter_value';
    end if;
    if p_date < r.bill_date then
      raise exception 'INVALID: the payment date is before the date of bill %', r.bill_number
        using errcode = 'invalid_parameter_value';
    end if;
    -- A payment cannot be dated before a reversal on the same bill: between the two dates the earlier payment
    -- and the new one would both count, and the payable would go negative as of those days.
    select max(x.reversed_date) into v_last_rev
    from public.vendor_payment_allocations x where x.bill_id = r.id and x.status = 'reversed';
    if v_last_rev is not null and p_date < v_last_rev then
      raise exception 'INVALID: bill % had a payment reversed on %; a new payment cannot be dated before that',
        r.bill_number, v_last_rev using errcode = 'invalid_parameter_value';
    end if;
    select s.settled, s.base_settled into v_settled, v_base_settled from app_private.bill_settled(r.id) s;
    v_rem_amount := r.total - v_settled;
    v_rem_base := r.base_total - v_base_settled;
    if r.amt > v_rem_amount then
      raise exception 'INVALID: the allocation of % exceeds what is outstanding (%) on bill %', r.amt, v_rem_amount, r.bill_number
        using errcode = 'invalid_parameter_value';
    end if;
    v_base_ap := app_private.prorate_remaining(v_rem_amount, v_rem_base, r.amt, v_bscale);
    v_alloc_bills := v_alloc_bills || r.id;
    v_alloc_amts := v_alloc_amts || r.amt;
    v_alloc_bases := v_alloc_bases || v_base_ap;
    v_alloc_sum := v_alloc_sum + r.amt;
    v_ap_sum := v_ap_sum + v_base_ap;
  end loop;
  if v_n <> coalesce(array_length(v_ids, 1), 0) then
    raise exception 'INVALID: a bill in the allocations does not exist in this Entity' using errcode = 'invalid_parameter_value';
  end if;
  if v_alloc_sum <> p_amount then
    raise exception 'INVALID: the payment (%) must equal the sum of its allocations (%); vendor advances are not supported',
      p_amount, v_alloc_sum using errcode = 'invalid_parameter_value';
  end if;

  v_cash_base := case when fa.currency = v_base then p_amount else app_private.round_amount(p_amount * p_rate, v_bscale, 'half_up') end;
  if v_cash_base <= 0 then
    raise exception 'INVALID: the payment is too small to book in %', v_base using errcode = 'invalid_parameter_value';
  end if;
  -- Payable relieved minus cash paid: a positive difference is a gain (we paid less base value than was booked).
  v_fx := v_ap_sum - v_cash_base;
  perform app_private.assert_fx_reasonable(v_fx, v_cash_base);
  if v_fx <> 0 then
    v_fx_acct := app_private.fx_account(p_entity);
    if v_fx_acct is null then
      raise exception 'CONFLICT: this Entity has no FX gain/loss account' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  select a.id into v_ap from public.ledger_accounts a
  where a.entity_id = p_entity and a.system_key = 'ACCOUNTS_PAYABLE' and a.status = 'active';
  if v_ap is null then
    raise exception 'CONFLICT: this Entity has no Accounts Payable account' using errcode = 'integrity_constraint_violation';
  end if;

  -- Lock order everywhere: bills, then the payment, then the paying account, then the numbering and journal
  -- counters. The account lock is taken before the counters (reversals already do), so a payment and a reversal on
  -- the same account can never wait on each other.
  perform 1 from public.financial_accounts where id = p_account and entity_id = p_entity for no key update;
  perform app_private.ensure_purchase_numbering(p_entity);
  v_number := app_private.allocate_document_number(p_entity, 'bill_payment', p_date);
  v_desc := format('Vendor payment %s - %s', v_number, c.display_name);

  for k in 1 .. array_length(v_alloc_bills, 1) loop
    select b.bill_number, b.exchange_rate, b.currency into r from public.bills b where b.id = v_alloc_bills[k];
    v_lines := app_private.add_line(v_lines, v_ap, v_alloc_bases[k], 0, v_desc || ' / ' || r.bill_number,
      app_private.orig_fields(r.currency, v_base, v_alloc_amts[k], r.exchange_rate, v_alloc_bases[k]));
  end loop;
  v_lines := app_private.add_line(v_lines, fa.ledger_account_id, 0, v_cash_base, v_desc,
    app_private.orig_fields(fa.currency, v_base, p_amount, p_rate, v_cash_base));
  v_lines := app_private.add_line(v_lines, v_fx_acct, case when v_fx < 0 then -v_fx else 0 end,
    case when v_fx > 0 then v_fx else 0 end, 'FX difference: ' || v_desc);

  v_journal := app_private.post_system_journal(
    p_entity, 'vendor_payment', v_payment, 'vendor_payment.confirm', 'vendor_payment.v1', p_date, v_desc, v_lines);
  perform app_private.record_movement(p_entity, p_account, 'out', p_amount, v_cash_base, p_rate, p_date,
    'vendor_payment', v_payment, 'principal', v_journal, v_desc);

  insert into public.vendor_payments
    (id, entity_id, payment_number, vendor_id, financial_account_id, currency, amount, exchange_rate, base_amount,
     payment_date, reference, payment_channel_id, note, fx_difference, journal_id)
  values
    (v_payment, p_entity, v_number, p_vendor, p_account, fa.currency, p_amount, p_rate, v_cash_base, p_date, v_ref,
     p_channel, v_note, v_fx, v_journal);
  for k in 1 .. array_length(v_alloc_bills, 1) loop
    insert into public.vendor_payment_allocations
      (entity_id, payment_id, bill_id, amount, base_ap_amount, allocation_date, journal_id)
    values (p_entity, v_payment, v_alloc_bills[k], v_alloc_amts[k], v_alloc_bases[k], p_date, v_journal);
  end loop;

  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_entity, 'VendorPaymentConfirmed', 'vendor_payment', v_payment,
          jsonb_build_object('payment_number', v_number, 'amount', p_amount, 'currency', fa.currency));
  perform app_private.idem_complete('vendor_payment.record', p_entity, p_key, 'vendor_payments', v_payment);
  return v_payment;
end
$$;

create function public.reverse_vendor_payment(p_payment uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p public.vendor_payments%rowtype;
  m public.money_movements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into p from public.vendor_payments where id = p_payment;
  if not found or not app_authz.has_permission(p.entity_id, 'bills.pay') then
    raise exception 'FORBIDDEN: missing bills.pay' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 or length(v_reason) > 1000 or p_date > app_private.entity_today(p.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of 5 to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  -- Bills first (fixed order), then the payment: the order every command uses.
  perform 1 from public.bills b
  where b.entity_id = p.entity_id
    and b.id in (select x.bill_id from public.vendor_payment_allocations x where x.payment_id = p.id)
  order by b.id for update;
  select * into p from public.vendor_payments where id = p_payment for update;

  v_replay := app_private.idem_begin('vendor_payment.reverse', p.entity_id, p_key,
    md5(jsonb_build_object('payment', p_payment, 'date', p_date, 'reason', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed payment can be reversed (now %)', p.status
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
    where entity_id = p.entity_id and source_type = 'vendor_payment' and source_id = p.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(
      p.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'vendor_payment', p.id, m.component, v_rev,
      'Reversal: ' || v_reason, m.id);
  end loop;
  update public.vendor_payment_allocations
  set status = 'reversed', reversed_at = now(), reversed_date = p_date, reversal_journal_id = v_rev
  where payment_id = p.id and status = 'active';
  update public.vendor_payments
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date,
      reversed_by = auth.uid(), reverse_reason = v_reason
  where id = p.id;

  perform app_private.idem_complete('vendor_payment.reverse', p.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

-- ------------------------------------------------------------ cancel / void / correct (Step 07 §5)
-- Draft or submitted -> cancelled: no accounting effect and the bill never received a number. Approved -> void:
-- the recognising journal is reversed by a linked reversal and the number stays used. A bill that has active
-- payment allocations cannot be voided: its payments must be reversed first, so no cash is ever orphaned.
-- Assumes the caller holds the bill row lock and checked permission and idempotency.
create function app_private.close_bill_core(
  p_bill uuid, p_target text, p_reason text, p_date date, p_replacement uuid default null)
returns void
language plpgsql as $$
declare
  b public.bills%rowtype;
  v_today date;
  v_date date;
  v_rev uuid;
  v_n bigint;
  v_min date;
begin
  select * into b from public.bills where id = p_bill;
  v_today := app_private.entity_today(b.entity_id);
  v_date := coalesce(p_date, v_today);
  perform set_config('app.audit_reason', p_reason, true);

  if b.status in ('draft', 'submitted') then
    if p_target <> 'cancelled' then
      raise exception 'INVALID: a bill that is not approved is cancelled, not voided' using errcode = 'invalid_parameter_value';
    end if;
    update public.bills
    set status = 'cancelled', closed_at = now(), closed_by = auth.uid(), closed_date = v_today, closed_reason = p_reason,
        replaced_by_bill_id = p_replacement
    where id = b.id;
    return;
  end if;

  if b.status <> 'approved' then
    raise exception 'CONFLICT: the bill is already %', b.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_target <> 'void' then
    raise exception 'INVALID: an approved bill is voided, not cancelled' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(v_date);
  if v_date > v_today then
    raise exception 'INVALID: the date cannot be in the future' using errcode = 'invalid_parameter_value';
  end if;
  select count(*) into v_n from public.vendor_payment_allocations a where a.bill_id = b.id and a.status = 'active';
  if v_n > 0 then
    raise exception 'CONFLICT: this bill has % active payment allocation(s); reverse those payments first', v_n
      using errcode = 'integrity_constraint_violation';
  end if;
  if exists (select 1 from public.bill_lines l where l.bill_id = b.id and l.asset_link_status = 'linked') then
    raise exception 'CONFLICT: a line of this bill is registered as a fixed asset; deal with the asset first'
      using errcode = 'integrity_constraint_violation';
  end if;
  -- Voiding is dated after every payment and reversal on the bill, so the payable never goes negative on any day
  -- in between (the sub-ledger and the ledger agree as of every date).
  select greatest(b.bill_date, coalesce(max(a.allocation_date), b.bill_date), coalesce(max(a.reversed_date), b.bill_date))
    into v_min from public.vendor_payment_allocations a where a.bill_id = b.id;
  if v_date < v_min then
    raise exception 'INVALID: the date cannot be before the last payment activity on this bill (%)', v_min
      using errcode = 'invalid_parameter_value';
  end if;

  v_rev := app_private.reverse_journal_core(b.journal_id, v_date, p_reason);
  update public.bills
  set status = 'void', reversal_journal_id = v_rev, closed_at = now(), closed_by = auth.uid(), closed_date = v_date,
      closed_reason = p_reason, replaced_by_bill_id = p_replacement
  where id = b.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (b.entity_id, 'BillVoided', 'bill', b.id, jsonb_build_object('bill_number', b.bill_number));
end
$$;

-- A draft is cancelled with bills.edit; a submitted bill with bills.void (the preparer can recall it instead).
create function public.cancel_bill(p_bill uuid, p_key text, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  if not found or not (app_authz.has_permission(b.entity_id, 'bills.edit')
                       or app_authz.has_permission(b.entity_id, 'bills.void')) then
    raise exception 'FORBIDDEN: missing bills.edit' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a cancellation needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into b from public.bills where id = p_bill for update;
  v_replay := app_private.idem_begin('bill.close', b.entity_id, p_key,
    md5(jsonb_build_object('b', p_bill, 't', 'cancelled', 'r', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not app_authz.has_permission(b.entity_id, case when b.status = 'draft' then 'bills.edit' else 'bills.void' end) then
    raise exception 'FORBIDDEN: missing bills.void' using errcode = 'insufficient_privilege';
  end if;
  if b.status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: only a draft or submitted bill can be cancelled (now %); void an approved bill instead', b.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.close_bill_core(p_bill, 'cancelled', v_reason, null);
  perform app_private.idem_complete('bill.close', b.entity_id, p_key, 'bills', p_bill);
  return p_bill;
end
$$;

create function public.void_bill(p_bill uuid, p_key text, p_reason text, p_date date default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  if not found or not app_authz.has_permission(b.entity_id, 'bills.void') then
    raise exception 'FORBIDDEN: missing bills.void' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: voiding needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into b from public.bills where id = p_bill for update;
  v_replay := app_private.idem_begin('bill.close', b.entity_id, p_key,
    md5(jsonb_build_object('b', p_bill, 't', 'void', 'r', v_reason, 'd', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if b.status <> 'approved' then
    raise exception 'CONFLICT: only an approved bill can be voided (now %)', b.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.close_bill_core(p_bill, 'void', v_reason, p_date);
  perform app_private.idem_complete('bill.close', b.entity_id, p_key, 'bills', p_bill);
  return p_bill;
end
$$;

-- Correction by replacement: the original is voided (reversal journal) and a new DRAFT copy is created that points
-- back to it. The copy keeps lines, vendor and dates so the user only edits what was wrong.
create function public.correct_bill(p_bill uuid, p_key text, p_reason text, p_date date default null) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_new uuid;
  v_lines jsonb;
  v_prep jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  if not found or not app_authz.has_permission(b.entity_id, 'bills.void')
     or not app_authz.has_permission(b.entity_id, 'bills.create') then
    raise exception 'FORBIDDEN: correcting a bill needs bills.void and bills.create' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 5 and 1000 then
    raise exception 'INVALID: a correction needs a reason of 5 to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into b from public.bills where id = p_bill for update;
  v_replay := app_private.idem_begin('bill.correct', b.entity_id, p_key,
    md5(jsonb_build_object('b', p_bill, 'r', v_reason, 'd', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if b.status <> 'approved' then
    raise exception 'CONFLICT: only an approved bill can be corrected (now %)', b.status
      using errcode = 'integrity_constraint_violation';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'description', l.description, 'quantity', l.quantity, 'unit_price', l.unit_price, 'treatment', l.treatment,
      'category_id', l.category_id, 'account_id', l.account_id) order by l.line_no), '[]'::jsonb)
    into v_lines from public.bill_lines l where l.bill_id = b.id;
  -- The lines were valid when approved: a category or account deactivated since then must not block the correction.
  v_prep := app_private.purchase_prepare_lines(b.entity_id, b.currency, v_lines, true);
  insert into public.bills
    (entity_id, vendor_id, vendor_reference, currency, exchange_rate, bill_date, due_date, notes, internal_note,
     subtotal, total, replaces_bill_id)
  values
    (b.entity_id, b.vendor_id, b.vendor_reference, b.currency, b.exchange_rate, b.bill_date, b.due_date, b.notes,
     left('Replaces ' || b.bill_number || ': ' || v_reason, 2000),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'total')::numeric, b.id)
  returning id into v_new;
  perform app_private.bill_write_lines(b.entity_id, v_new, v_prep);

  perform app_private.close_bill_core(p_bill, 'void', v_reason, p_date, v_new);
  perform app_private.idem_complete('bill.correct', b.entity_id, p_key, 'bills', v_new);
  return v_new;
end
$$;

-- The due date is the one commercial term that may change after approval: audited, with a reason, and never
-- before the bill date. The frozen figures and the journal are unaffected.
create function public.update_bill_due_date(p_bill uuid, p_due_date date, p_reason text) returns date
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  b public.bills%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into b from public.bills where id = p_bill;
  if not found or not app_authz.has_permission(b.entity_id, 'bills.edit') then
    raise exception 'FORBIDDEN: missing bills.edit' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 3 and 1000 or p_due_date is null then
    raise exception 'INVALID: a new due date and a reason are required' using errcode = 'invalid_parameter_value';
  end if;
  select * into b from public.bills where id = p_bill for update;
  if b.status <> 'approved' then
    raise exception 'CONFLICT: only an approved bill has a due date to change here (now %)', b.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(p_due_date);
  if p_due_date < b.bill_date then
    raise exception 'INVALID: the due date cannot be before the bill date' using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.bills set due_date = p_due_date where id = b.id;
  return p_due_date;
end
$$;

-- ------------------------------------------------------------ reading: positions, control, aging
create function public.list_bill_positions(
  p_entity uuid, p_filter text default null, p_vendor uuid default null, p_as_of date default null)
returns table (
  bill_id uuid, bill_number text, vendor_id uuid, vendor_name text, vendor_reference text, currency text, status text,
  bill_date date, due_date date, total text, settled text, outstanding text, base_outstanding text,
  settlement_status text, is_overdue boolean, days_overdue integer)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.view') then
    raise exception 'FORBIDDEN: missing bills.view' using errcode = 'insufficient_privilege';
  end if;
  if p_filter is not null and p_filter not in ('open', 'overdue', 'paid', 'unpaid', 'partial', 'closed') then
    raise exception 'INVALID: unknown filter' using errcode = 'invalid_parameter_value';
  end if;
  return query
  select p.bill_id, p.bill_number, p.vendor_id, c.display_name, p.vendor_reference, p.currency::text, p.status,
         p.bill_date, p.due_date, p.total::text, p.settled::text, p.outstanding::text, p.base_outstanding::text,
         p.settlement_status, p.is_overdue, p.days_overdue
  from app_private.bill_positions(p_entity, p_as_of) p
  join public.contacts c on c.id = p.vendor_id and c.entity_id = p_entity
  where (p_vendor is null or p.vendor_id = p_vendor)
    and case p_filter
          when 'open' then p.status = 'approved' and p.outstanding > 0
          when 'overdue' then p.is_overdue
          when 'paid' then p.settlement_status = 'paid'
          when 'unpaid' then p.settlement_status = 'unpaid'
          when 'partial' then p.settlement_status = 'partial'
          when 'closed' then p.status = 'void'
          else true end
  order by p.bill_date desc, p.bill_number desc;
end
$$;

create function public.ap_control_report(p_entity uuid, p_as_of date default null)
returns table (sub_ledger text, ledger_purchases text, ledger_total text, difference text, other_ledger text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.view') then
    raise exception 'FORBIDDEN: missing bills.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select c.sub_ledger::text, c.ledger_purchases::text, c.ledger_total::text, (c.ledger_purchases - c.sub_ledger)::text,
         (c.ledger_total - c.ledger_purchases)::text
  from app_private.ap_control(p_entity, p_as_of) c;
end
$$;

create function public.list_vendor_payments(
  p_entity uuid, p_vendor uuid default null, p_bill uuid default null, p_limit integer default 100)
returns table (
  payment_id uuid, payment_number text, status text, payment_date date, vendor_id uuid, vendor_name text,
  currency text, amount text, base_amount text, fx_difference text, reference text, bill_count bigint)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.view') then
    raise exception 'FORBIDDEN: missing bills.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select p.id, p.payment_number, p.status, p.payment_date, p.vendor_id, c.display_name, p.currency::text,
         p.amount::text, p.base_amount::text, p.fx_difference::text, p.reference,
         (select count(*) from public.vendor_payment_allocations a where a.payment_id = p.id)
  from public.vendor_payments p
  join public.contacts c on c.id = p.vendor_id and c.entity_id = p.entity_id
  where p.entity_id = p_entity and (p_vendor is null or p.vendor_id = p_vendor)
    and (p_bill is null or exists (select 1 from public.vendor_payment_allocations a
                                   where a.payment_id = p.id and a.bill_id = p_bill))
  order by p.payment_date desc, p.payment_number desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end
$$;

-- ------------------------------------------------------------ AP aging (Step 12; base currency)
create function public.ap_aging(p_entity uuid, p_as_of date default null, p_vendor uuid default null)
returns table (
  vendor_id uuid, vendor_name text, not_due text, days_1_30 text, days_31_60 text, days_61_90 text,
  days_over_90 text, total text, bill_count bigint)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'bills.view') then
    raise exception 'FORBIDDEN: missing bills.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select p.vendor_id, c.display_name,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue = 0), 0)::text,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue between 1 and 30), 0)::text,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue between 31 and 60), 0)::text,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue between 61 and 90), 0)::text,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue > 90), 0)::text,
         sum(p.base_outstanding)::text, count(*)
  from app_private.bill_positions(p_entity, p_as_of) p
  join public.contacts c on c.id = p.vendor_id and c.entity_id = p_entity
  where p.status = 'approved' and p.outstanding > 0 and (p_vendor is null or p.vendor_id = p_vendor)
  group by p.vendor_id, c.display_name
  order by sum(p.base_outstanding) desc, c.display_name;
end
$$;

-- ------------------------------------------------------------ period close checks (P6 form; part 3 adds evidence)
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
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.vendor_payments');
create policy vendor_payments_select on public.vendor_payments for select to authenticated
  using (app_authz.has_permission(entity_id, 'bills.view'));
call app_private.expose_select('public.vendor_payment_allocations');
create policy vendor_payment_allocations_select on public.vendor_payment_allocations for select to authenticated
  using (app_authz.has_permission(entity_id, 'bills.view'));

revoke all on function app_private.tg_vendor_payments_guard() from public;
revoke all on function app_private.tg_vendor_allocations_guard() from public;
revoke all on function app_private.tg_vendor_allocations_capacity() from public;
revoke all on function app_private.bill_settled(uuid, date) from public;
revoke all on function app_private.bill_positions(uuid, date) from public;
revoke all on function app_private.is_purchase_journal(uuid) from public;
revoke all on function app_private.ap_control(uuid, date) from public;
revoke all on function app_private.close_bill_core(uuid, text, text, date, uuid) from public;
revoke all on function app_private.period_blockers(uuid) from public;

revoke all on function public.record_vendor_payment(uuid, text, uuid, uuid, date, numeric, jsonb, numeric, text, uuid, text) from public, anon;
revoke all on function public.reverse_vendor_payment(uuid, text, date, text) from public, anon;
revoke all on function public.cancel_bill(uuid, text, text) from public, anon;
revoke all on function public.void_bill(uuid, text, text, date) from public, anon;
revoke all on function public.correct_bill(uuid, text, text, date) from public, anon;
revoke all on function public.update_bill_due_date(uuid, date, text) from public, anon;
revoke all on function public.list_bill_positions(uuid, text, uuid, date) from public, anon;
revoke all on function public.ap_control_report(uuid, date) from public, anon;
revoke all on function public.list_vendor_payments(uuid, uuid, uuid, integer) from public, anon;
revoke all on function public.ap_aging(uuid, date, uuid) from public, anon;
grant execute on function public.record_vendor_payment(uuid, text, uuid, uuid, date, numeric, jsonb, numeric, text, uuid, text) to authenticated;
grant execute on function public.reverse_vendor_payment(uuid, text, date, text) to authenticated;
grant execute on function public.cancel_bill(uuid, text, text) to authenticated;
grant execute on function public.void_bill(uuid, text, text, date) to authenticated;
grant execute on function public.correct_bill(uuid, text, text, date) to authenticated;
grant execute on function public.update_bill_due_date(uuid, date, text) to authenticated;
grant execute on function public.list_bill_positions(uuid, text, uuid, date) to authenticated;
grant execute on function public.ap_control_report(uuid, date) to authenticated;
grant execute on function public.list_vendor_payments(uuid, uuid, uuid, integer) to authenticated;
grant execute on function public.ap_aging(uuid, date, uuid) to authenticated;
