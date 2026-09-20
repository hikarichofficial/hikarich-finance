-- P5 (Step 15 §9) part 2: customer payments, allocation, advances, cancel/void/correct and the AR control.
-- Authority: Step 04 §3/§13/§15 (posting matrix, sub-ledger reconciliation, overpayment limits), Step 07 §3/§4/§7
-- (invoice, public payment and payment workflows), Step 08 §9 (payment integrity), Step 01 (overpayment needs an
-- explicit treatment).
--
-- Model
--   * A payment is a CONFIRMED fact: money arrived on one financial account, on a date, for one customer. It is
--     written only by trusted server code together with its journal, its money movement and its allocations, in
--     one transaction. A customer's claim ("Saya Sudah Bayar") is a payment submission: it has no accounting
--     effect until an authorised person confirms it.
--   * Allocations link a payment to invoices. Paid / partially paid / outstanding are DERIVED from active
--     allocations; nothing overwrites the invoice's issuance state.
--   * Money above what the chosen invoices need is either refused or kept as a customer advance (a liability),
--     only when the caller explicitly asks for it. An advance can later be applied to another invoice.
--   * Everything is in the payment's own currency; payment, invoice and account must share it. A difference
--     between the base value at the invoice rate and at the payment rate is an explicit FX gain/loss line.

-- ------------------------------------------------------------ shared helpers
-- Remaining base value for a part of a remaining amount: the last part takes the exact remainder, so nothing is
-- ever left over or over-consumed (Step 04 §14 largest-remainder spirit).
create function app_private.prorate_remaining(
  p_rem_amount numeric, p_rem_base numeric, p_amount numeric, p_scale integer)
returns numeric
language plpgsql immutable as $$
begin
  if p_amount is null or p_amount <= 0 or p_rem_amount is null or p_amount > p_rem_amount then
    raise exception 'INVALID: the amount exceeds what remains' using errcode = 'invalid_parameter_value';
  end if;
  if p_amount = p_rem_amount then
    return p_rem_base;
  end if;
  -- Exact half-up rounding of amount x base / remaining, in integers: a plain numeric division keeps only about
  -- 16 significant digits, which can round a near-tie the wrong way before the final rounding.
  return trunc(div(2 * p_amount * p_rem_base * 10::numeric ^ p_scale + p_rem_amount, 2 * p_rem_amount))
         / 10::numeric ^ p_scale;
end
$$;

-- Original-currency detail for a journal line, only when it is exactly consistent (the posting engine requires
-- original amount x rate = base amount for lines that carry it).
create function app_private.orig_fields(
  p_currency public.currency_code, p_base public.currency_code, p_amount numeric, p_rate numeric, p_base_amount numeric)
returns jsonb
language sql immutable as $$
  select case
    when p_currency = p_base or p_rate is null or p_amount is null then '{}'::jsonb
    when app_private.round_amount(p_amount * p_rate, app_private.currency_scale(p_base), 'half_up') = p_base_amount
      then jsonb_build_object('original_currency', p_currency, 'original_amount', p_amount, 'exchange_rate', p_rate)
    else '{}'::jsonb end
$$;

-- Appends a debit or credit line unless it is zero.
create function app_private.add_line(
  p_lines jsonb, p_account uuid, p_debit numeric, p_credit numeric, p_description text, p_orig jsonb default '{}'::jsonb)
returns jsonb
language sql immutable as $$
  select case when coalesce(p_debit, 0) = 0 and coalesce(p_credit, 0) = 0 then p_lines
    else p_lines || (jsonb_build_object('account_id', p_account, 'debit', coalesce(p_debit, 0),
                                        'credit', coalesce(p_credit, 0), 'description', p_description)
                     || coalesce(p_orig, '{}'::jsonb)) end
$$;

create function app_private.customer_advance_account(p_entity uuid) returns uuid
language sql stable as $$
  select a.id from public.ledger_accounts a
  where a.entity_id = p_entity and a.system_key = 'CUSTOMER_ADVANCE' and a.status = 'active' and not a.is_group
$$;

create function app_private.fx_account(p_entity uuid) returns uuid
language sql stable as $$
  select a.id from public.ledger_accounts a
  where a.entity_id = p_entity and a.system_key = 'FX_GAIN_LOSS' and a.status = 'active' and not a.is_group
$$;

-- An FX difference beyond 20% of the cash amount is a typing mistake, not an exchange result (Step 04 §14).
create function app_private.assert_fx_reasonable(p_difference numeric, p_cash_base numeric) returns void
language plpgsql immutable as $$
begin
  if abs(p_difference) * 5 > p_cash_base then
    raise exception 'INVALID: the exchange difference exceeds 20%% of the amount; check the exchange rate'
      using errcode = 'invalid_parameter_value';
  end if;
end
$$;

-- ------------------------------------------------------------ payments
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  payment_number text not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'reversed')),
  customer_id uuid not null,
  financial_account_id uuid not null,
  currency public.currency_code not null,
  amount public.money_amount not null check (amount > 0),
  exchange_rate public.fx_rate,
  -- Cash side in base currency, as the money movement and the journal booked it.
  base_amount public.money_amount not null check (base_amount > 0),
  payment_date date not null,
  reference text check (reference is null or length(reference) <= 200),
  payer_name text check (payer_name is null or length(payer_name) <= 200),
  payment_channel_id uuid,
  submission_id uuid,
  -- Split of the amount: allocated to invoices at confirmation, and kept as a customer advance.
  allocated_amount public.money_amount not null check (allocated_amount >= 0),
  advance_amount public.money_amount not null default 0 check (advance_amount >= 0),
  advance_base public.money_amount not null default 0 check (advance_base >= 0),
  -- Base value gained (+) or lost (-) between the invoice rate and the payment rate.
  fx_difference public.money_amount not null default 0,
  note text check (note is null or length(note) <= 1000),
  -- Issuer / customer / receiving-account facts frozen at confirmation: the receipt is generated from this, so a
  -- later edit of the masters never rewrites a receipt (Step 11 §14).
  receipt_snapshot jsonb not null,
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
  foreign key (entity_id, customer_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id, currency)
    references public.financial_accounts (entity_id, id, currency) on delete restrict,
  foreign key (entity_id, payment_channel_id) references public.payment_channels (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint payment_split check (allocated_amount + advance_amount = amount),
  constraint payment_advance_base_shape check ((advance_amount = 0) = (advance_base = 0)),
  constraint payment_state_consistent check (
    (status = 'confirmed' and reversal_journal_id is null and reversed_at is null)
    or (status = 'reversed' and reversal_journal_id is not null and reversed_at is not null
        and reversed_date is not null and reverse_reason is not null))
);
create unique index payments_number_uq on public.payments (entity_id, payment_number);
create unique index payments_submission_uq on public.payments (submission_id) where submission_id is not null;
create index payments_entity_date_idx on public.payments (entity_id, payment_date);
create index payments_customer_idx on public.payments (entity_id, customer_id);
create index payments_account_idx on public.payments (entity_id, financial_account_id);

-- The economics of a confirmed payment never change; only the one-way step to "reversed" is allowed.
create function app_private.tg_payments_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by',
                                   'reverse_reason', 'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' then
    raise exception 'A reversed payment cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a confirmed payment cannot be changed; reverse it instead'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.payments
  for each row execute function app_private.tg_payments_guard();
create trigger tg_forbid_delete before delete on public.payments
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.payments
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.payments');
call app_private.secure_table('public.payments');
create trigger tg_audit after insert or update or delete on public.payments
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ allocations
-- "payment": allocated when the payment was confirmed. "credit": a customer advance applied later.
create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  payment_id uuid not null,
  invoice_id uuid not null,
  kind text not null check (kind in ('payment', 'credit')),
  -- In the invoice (= payment) currency.
  amount public.money_amount not null check (amount > 0),
  -- Receivable relieved, in base currency, at the invoice's own booked value.
  base_ar_amount public.money_amount not null check (base_ar_amount >= 0),
  -- Advance (base value) consumed by a credit application; zero for a plain payment allocation.
  advance_base_used public.money_amount not null default 0 check (advance_base_used >= 0),
  fx_difference public.money_amount not null default 0,
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
  foreign key (entity_id, payment_id) references public.payments (entity_id, id) on delete restrict,
  foreign key (entity_id, invoice_id) references public.invoices (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint allocation_kind_shape check (kind = 'credit' or advance_base_used = 0),
  constraint allocation_reversed_shape check (
    (status = 'active' and reversed_at is null and reversed_date is null and reversal_journal_id is null)
    or (status = 'reversed' and reversed_at is not null and reversed_date is not null
        and reversal_journal_id is not null))
);
create index payment_allocations_invoice_idx on public.payment_allocations (entity_id, invoice_id, status);
create index payment_allocations_payment_idx on public.payment_allocations (entity_id, payment_id, status);

create function app_private.tg_allocations_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversed_at', 'reversed_date', 'reversal_journal_id',
                                   'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' then
    raise exception 'A reversed allocation cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'An allocation cannot be edited; reverse the payment or the credit application'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.payment_allocations
  for each row execute function app_private.tg_allocations_guard();
create trigger tg_forbid_delete before delete on public.payment_allocations
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.payment_allocations
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.payment_allocations');
call app_private.secure_table('public.payment_allocations');
create trigger tg_audit after insert or update or delete on public.payment_allocations
  for each row execute function app_private.tg_audit('entity_id');

-- An invoice can never be over-allocated, whoever writes the allocation (Step 08 §8: outstanding never negative).
-- The invoice row is locked first, so two concurrent allocations serialise.
create function app_private.tg_allocations_capacity() returns trigger
language plpgsql as $$
declare
  i public.invoices%rowtype;
  v_amount numeric;
  v_base numeric;
begin
  select * into i from public.invoices where id = new.invoice_id and entity_id = new.entity_id for update;
  if not found or i.status <> 'issued' then
    raise exception 'CONFLICT: only an issued invoice can receive an allocation' using errcode = 'integrity_constraint_violation';
  end if;
  select coalesce(sum(a.amount), 0), coalesce(sum(a.base_ar_amount), 0) into v_amount, v_base
  from public.payment_allocations a where a.invoice_id = new.invoice_id and a.status = 'active';
  if v_amount + new.amount > i.total or v_base + new.base_ar_amount > i.base_total then
    raise exception 'CONFLICT: the allocation exceeds what is outstanding on invoice %', i.invoice_number
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_capacity before insert on public.payment_allocations
  for each row execute function app_private.tg_allocations_capacity();

-- ------------------------------------------------------------ payment submissions ("Saya Sudah Bayar")
create table public.payment_submissions (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  invoice_id uuid not null,
  source text not null default 'public' check (source in ('public', 'staff')),
  amount public.money_amount not null check (amount > 0),
  currency public.currency_code not null references public.currencies (code),
  payment_date date not null,
  payer_name text check (payer_name is null or length(payer_name) <= 200),
  payer_reference text check (payer_reference is null or length(payer_reference) <= 200),
  payment_channel_id uuid,
  note text check (note is null or length(note) <= 1000),
  -- Reserved for the evidence upload of P11; a public visitor never attaches a file in P5.
  proof_document_id uuid,
  fingerprint text not null,
  -- Salted hash of the requester (never the address itself); only used to throttle abuse.
  client_hash text,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected', 'duplicate')),
  duplicate_of uuid,
  payment_id uuid,
  review_reason text check (review_reason is null or length(review_reason) <= 1000),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, invoice_id) references public.invoices (entity_id, id) on delete restrict,
  foreign key (entity_id, payment_channel_id) references public.payment_channels (entity_id, id) on delete restrict,
  foreign key (entity_id, payment_id) references public.payments (entity_id, id) on delete restrict,
  foreign key (entity_id, duplicate_of) references public.payment_submissions (entity_id, id) on delete restrict,
  constraint submission_state_consistent check (
    case status
      when 'pending' then payment_id is null and reviewed_at is null and duplicate_of is null
      when 'confirmed' then payment_id is not null and reviewed_at is not null
      when 'rejected' then payment_id is null and reviewed_at is not null and review_reason is not null
      else payment_id is null and reviewed_at is not null and review_reason is not null
    end)
);
create index payment_submissions_invoice_idx on public.payment_submissions (entity_id, invoice_id, status);
create index payment_submissions_fingerprint_idx on public.payment_submissions (invoice_id, fingerprint) where status = 'pending';
create index payment_submissions_pending_idx on public.payment_submissions (entity_id, created_at) where status = 'pending';
create index payment_submissions_client_idx on public.payment_submissions (client_hash, created_at) where client_hash is not null;

create function app_private.tg_submissions_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'duplicate_of', 'payment_id', 'review_reason', 'reviewed_by', 'reviewed_at',
                                   'updated_at', 'updated_by', 'version'];
begin
  if old.status <> 'pending' then
    raise exception 'A reviewed payment submission cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The content of a payment submission cannot be edited' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.payment_submissions
  for each row execute function app_private.tg_submissions_guard();
create trigger tg_forbid_delete before delete on public.payment_submissions
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.payment_submissions
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.payment_submissions');
call app_private.secure_table('public.payment_submissions');
create trigger tg_audit after insert or update or delete on public.payment_submissions
  for each row execute function app_private.tg_audit('entity_id', 'client_hash');

-- A draft invoice can never expose an active public link (Step 08 §8).
create function app_private.tg_public_links_insert_guard() returns trigger
language plpgsql as $$
begin
  if not exists (select 1 from public.invoices i where i.id = new.invoice_id and i.entity_id = new.entity_id
                 and i.status = 'issued') then
    raise exception 'A public link exists only for an issued invoice' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_insert_guard before insert on public.invoice_public_links
  for each row execute function app_private.tg_public_links_insert_guard();

-- ------------------------------------------------------------ derived figures
-- Settled amount of one invoice, as of a date (allocations dated on or before it that were not reversed by then).
create function app_private.invoice_settled(p_invoice uuid, p_as_of date default null)
returns table (settled numeric, base_settled numeric)
language sql stable as $$
  select coalesce(sum(a.amount), 0), coalesce(sum(a.base_ar_amount), 0)
  from public.payment_allocations a
  where a.invoice_id = p_invoice
    and (p_as_of is null
         and a.status = 'active'
         or p_as_of is not null and a.allocation_date <= p_as_of
            and (a.status = 'active' or a.reversed_date > p_as_of))
$$;

-- What remains of a payment's advance (amount and base value): the advance minus credit applications and minus
-- confirmed refunds of the advance. The refund tables arrive in part 3, hence plpgsql (late binding).
create function app_private.payment_advance_state(p_payment uuid)
returns table (rem_amount numeric, rem_base numeric)
language plpgsql stable as $$
begin
  return query
  select p.advance_amount
           - coalesce((select sum(a.amount) from public.payment_allocations a
                       where a.payment_id = p.id and a.kind = 'credit' and a.status = 'active'), 0)
           - coalesce((select sum(ri.amount) from public.refund_items ri
                       join public.refunds r on r.id = ri.refund_id
                       where r.payment_id = p.id and r.status = 'confirmed' and ri.allocation_id is null), 0),
         p.advance_base
           - coalesce((select sum(a.advance_base_used) from public.payment_allocations a
                       where a.payment_id = p.id and a.kind = 'credit' and a.status = 'active'), 0)
           - coalesce((select sum(ri.base_amount) from public.refund_items ri
                       join public.refunds r on r.id = ri.refund_id
                       where r.payment_id = p.id and r.status = 'confirmed' and ri.allocation_id is null), 0)
  from public.payments p where p.id = p_payment;
end
$$;

-- What remains refundable on one allocation (amount and base receivable value).
create function app_private.allocation_refund_state(p_allocation uuid)
returns table (rem_amount numeric, rem_base numeric)
language plpgsql stable as $$
begin
  return query
  select a.amount - coalesce((select sum(ri.amount) from public.refund_items ri
                              join public.refunds r on r.id = ri.refund_id
                              where ri.allocation_id = a.id and r.status = 'confirmed'), 0),
         a.base_ar_amount - coalesce((select sum(ri.base_amount) from public.refund_items ri
                                      join public.refunds r on r.id = ri.refund_id
                                      where ri.allocation_id = a.id and r.status = 'confirmed'), 0)
  from public.payment_allocations a where a.id = p_allocation;
end
$$;

-- Positions of the Entity's invoices at a date: settlement and overdue are DERIVED here, never stored (Step 07 §3).
-- A cancelled/void invoice counts as issued before the day it was closed and as zero afterwards.
create function app_private.invoice_positions(p_entity uuid, p_as_of date default null)
returns table (
  invoice_id uuid, invoice_number text, customer_id uuid, currency public.currency_code, status text,
  issue_date date, due_date date, total numeric, settled numeric, outstanding numeric, base_total numeric,
  base_settled numeric, base_outstanding numeric, refunded numeric, settlement_status text, refund_status text,
  is_overdue boolean, days_overdue integer)
language plpgsql stable as $$
declare
  v_asof date := coalesce(p_as_of, app_private.entity_today(p_entity));
begin
  return query
  with base as (
    select i.*,
           (i.status in ('cancelled', 'void') and i.closed_date <= v_asof) as is_closed,
           s.settled as s_settled, s.base_settled as s_base_settled,
           coalesce((select sum(ri.amount) from public.refund_items ri
                     join public.refunds r on r.id = ri.refund_id
                     join public.payment_allocations a on a.id = ri.allocation_id
                     where a.invoice_id = i.id and r.refund_date <= v_asof
                       and (r.status = 'confirmed' or (r.status = 'reversed' and r.reversed_date > v_asof))), 0) as s_refunded
    from public.invoices i
    cross join lateral app_private.invoice_settled(i.id, v_asof) s
    where i.entity_id = p_entity and i.invoice_number is not null and i.issue_date <= v_asof
  )
  select b.id, b.invoice_number, b.customer_id, b.currency,
         case when b.status in ('cancelled', 'void') and not b.is_closed then 'issued' else b.status end,
         b.issue_date, b.due_date, b.total::numeric, b.s_settled,
         case when b.is_closed then 0 else b.total - b.s_settled end,
         b.base_total::numeric, b.s_base_settled,
         case when b.is_closed then 0 else b.base_total - b.s_base_settled end,
         b.s_refunded,
         case when b.is_closed then null
              when b.total - b.s_settled = 0 then 'paid'
              when b.s_settled = 0 then 'unpaid'
              else 'partial' end,
         case when b.s_refunded = 0 then 'none'
              when b.s_refunded >= b.s_settled then 'full'
              else 'partial' end,
         (not b.is_closed and b.total - b.s_settled > 0 and b.due_date < v_asof),
         case when not b.is_closed and b.total - b.s_settled > 0 and b.due_date < v_asof then v_asof - b.due_date else 0 end
  from base b;
end
$$;

-- ------------------------------------------------------------ AR and advance control (Step 04 §13)
-- Sub-ledger (from invoices and allocations) against the General Ledger, restricted to journals that the sales
-- workflow itself produced (and their reversals): opening balances and other sources are shown separately.
create function app_private.is_sales_journal(p_journal uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.journal_entries j
    where j.id = p_journal
      and (j.source_type in ('invoice', 'payment', 'payment_credit', 'refund')
           or exists (select 1 from public.journal_entries o
                      where o.id = j.reverses_journal_id
                        and o.source_type in ('invoice', 'payment', 'payment_credit', 'refund'))))
$$;

create function app_private.ar_control(p_entity uuid, p_as_of date default null)
returns table (
  sub_ledger numeric, ledger_sales numeric, ledger_total numeric,
  advance_sub_ledger numeric, advance_ledger_sales numeric, advance_ledger_total numeric)
language plpgsql stable as $$
declare
  v_asof date := coalesce(p_as_of, app_private.entity_today(p_entity));
  v_sub numeric;
  v_ledger_sales numeric;
  v_ledger_total numeric;
  v_adv_sub numeric;
  v_adv_sales numeric;
  v_adv_total numeric;
begin
  select coalesce(sum(p.base_outstanding), 0) into v_sub from app_private.invoice_positions(p_entity, v_asof) p;

  select coalesce(sum(l.debit - l.credit), 0),
         coalesce(sum(l.debit - l.credit) filter (where app_private.is_sales_journal(j.id)), 0)
    into v_ledger_total, v_ledger_sales
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = 'ACCOUNTS_RECEIVABLE' and j.status = 'posted' and j.entry_date <= v_asof;

  select coalesce(sum(l.credit - l.debit), 0),
         coalesce(sum(l.credit - l.debit) filter (where app_private.is_sales_journal(j.id)), 0)
    into v_adv_total, v_adv_sales
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = 'CUSTOMER_ADVANCE' and j.status = 'posted' and j.entry_date <= v_asof;

  select coalesce((select sum(p.advance_base) from public.payments p
                   where p.entity_id = p_entity and p.payment_date <= v_asof
                     and (p.status = 'confirmed' or p.reversed_date > v_asof)), 0)
       - coalesce((select sum(a.advance_base_used) from public.payment_allocations a
                   where a.entity_id = p_entity and a.kind = 'credit' and a.allocation_date <= v_asof
                     and (a.status = 'active' or a.reversed_date > v_asof)), 0)
       - coalesce((select sum(ri.base_amount) from public.refund_items ri
                   join public.refunds r on r.id = ri.refund_id
                   where r.entity_id = p_entity and ri.allocation_id is null and r.refund_date <= v_asof
                     and (r.status = 'confirmed' or (r.status = 'reversed' and r.reversed_date > v_asof))), 0)
    into v_adv_sub;

  return query select v_sub, v_ledger_sales, v_ledger_total, v_adv_sub, v_adv_sales, v_adv_total;
end
$$;

-- Frozen facts for customer-facing documents (receipts). The customer's tax identifier is deliberately absent.
create function app_private.document_parties(p_entity uuid, p_customer uuid, p_account uuid, p_channel uuid)
returns jsonb
language plpgsql stable as $$
declare
  e public.entities%rowtype;
  pr public.entity_profiles%rowtype;
  c public.contacts%rowtype;
  fa public.financial_accounts%rowtype;
  ch public.payment_channels%rowtype;
begin
  select * into e from public.entities where id = p_entity;
  select * into pr from public.entity_profiles where entity_id = p_entity;
  select * into c from public.contacts where id = p_customer and entity_id = p_entity;
  select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
  if p_channel is not null then
    select * into ch from public.payment_channels where id = p_channel and entity_id = p_entity;
  end if;
  return jsonb_build_object(
    'issuer', jsonb_build_object(
      'entity_type', e.entity_type, 'legal_name', e.legal_name, 'brand_name', e.brand_name,
      'address_line', pr.address_line, 'city', pr.city, 'province', pr.province, 'postal_code', pr.postal_code,
      'country_code', pr.country_code, 'contact_email', pr.contact_email, 'contact_phone', pr.contact_phone,
      'website', pr.website),
    'customer', jsonb_build_object(
      'display_name', c.display_name, 'legal_name', c.legal_name, 'address_line', c.address_line, 'city', c.city,
      'country_code', c.country_code),
    'account', jsonb_build_object(
      'institution_name', fa.institution_name, 'kind', fa.kind,
      'account_masked', case when fa.account_number is null then null
                             else repeat('*', greatest(length(fa.account_number) - 4, 0)) || right(fa.account_number, 4) end),
    'channel', ch.name);
end
$$;

-- ------------------------------------------------------------ confirming a payment (the one writer)
-- Assumes the caller checked permission, idempotency and approval rules. `p_allocations` is a list of
-- {invoice_id, amount}; amounts are in the payment currency, which must equal the invoices' and the account's.
create function app_private.confirm_payment_core(
  p_entity uuid, p_customer uuid, p_account uuid, p_date date, p_amount numeric, p_rate numeric,
  p_allocations jsonb, p_reference text, p_payer text, p_channel uuid, p_submission uuid,
  p_allow_advance boolean, p_note text)
returns uuid
language plpgsql as $$
declare
  e public.entities%rowtype;
  fa public.financial_accounts%rowtype;
  c public.contacts%rowtype;
  r record;
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
  v_alloc_ids uuid[] := '{}';
  v_alloc_amts numeric[] := '{}';
  v_alloc_bases numeric[] := '{}';
  v_alloc_invoices uuid[] := '{}';
  v_alloc_sum numeric := 0;
  v_base_ar_sum numeric := 0;
  v_base_ar numeric;
  v_adv numeric;
  v_adv_base numeric := 0;
  v_cash_base numeric;
  v_alloc_cash_base numeric;
  v_fx numeric := 0;
  v_ar uuid;
  v_adv_acct uuid;
  v_fx_acct uuid;
  v_payment uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  k integer;
begin
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_base := e.base_currency;
  v_bscale := app_private.currency_scale(v_base);
  v_today := app_private.entity_today(p_entity);

  select * into c from public.contacts where id = p_customer and entity_id = p_entity;
  if not found or c.kind not in ('customer', 'both') then
    raise exception 'INVALID: the payer is unknown or is not a customer of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
  if not found or not fa.is_active then
    raise exception 'INVALID: the receiving account is unknown or inactive' using errcode = 'invalid_parameter_value';
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
  if p_channel is not null and not exists (
       select 1 from public.payment_channels ch where ch.id = p_channel and ch.entity_id = p_entity and ch.is_active) then
    raise exception 'INVALID: the payment channel is unknown or inactive' using errcode = 'invalid_parameter_value';
  end if;

  -- Parse the allocation list.
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'INVALID: allocations must be a list' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_allocations) > 100 then
    raise exception 'INVALID: a payment can be allocated to at most 100 invoices' using errcode = 'invalid_parameter_value';
  end if;
  for v_elem in select value from jsonb_array_elements(p_allocations) loop
    v_n := v_n + 1;
    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'INVALID: allocation % is not an object', v_n using errcode = 'invalid_parameter_value';
    end if;
    begin
      v_id := (v_elem ->> 'invoice_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'INVALID: allocation % has an invalid invoice', v_n using errcode = 'invalid_parameter_value';
    end;
    if v_id is null then
      raise exception 'INVALID: allocation % needs an invoice', v_n using errcode = 'invalid_parameter_value';
    end if;
    if v_id = any (v_ids) then
      raise exception 'INVALID: an invoice can appear only once in the allocations' using errcode = 'invalid_parameter_value';
    end if;
    v_amt := app_private.parse_amount(v_elem ->> 'amount', format('allocation %s amount', v_n));
    if v_amt <= 0 or app_private.round_amount(v_amt, v_ascale, 'down') <> v_amt then
      raise exception 'INVALID: allocation % must be positive and allows % decimals for %', v_n, v_ascale, fa.currency
        using errcode = 'invalid_parameter_value';
    end if;
    v_ids := v_ids || v_id;
    v_amts := v_amts || v_amt;
  end loop;

  -- Lock the invoices in a fixed order (two payments over the same invoices can never deadlock), then validate
  -- and split each allocation against what is outstanding NOW.
  v_n := 0;
  for r in
    select i.id, i.invoice_number, i.status, i.customer_id, i.currency, i.issue_date, i.total, i.base_total, x.amt
    from public.invoices i
    join unnest(v_ids, v_amts) as x(id, amt) on x.id = i.id
    where i.entity_id = p_entity
    order by i.id
    for update of i
  loop
    v_n := v_n + 1;
    if r.status <> 'issued' then
      raise exception 'CONFLICT: invoice % is % and cannot receive a payment', coalesce(r.invoice_number, 'draft'), r.status
        using errcode = 'integrity_constraint_violation';
    end if;
    if r.customer_id <> p_customer then
      raise exception 'INVALID: invoice % belongs to a different customer', r.invoice_number using errcode = 'invalid_parameter_value';
    end if;
    if r.currency <> fa.currency then
      raise exception 'INVALID: invoice % is in % but the receiving account is in %', r.invoice_number, r.currency, fa.currency
        using errcode = 'invalid_parameter_value';
    end if;
    if p_date < r.issue_date then
      raise exception 'INVALID: the payment date is before the issue date of invoice %', r.invoice_number
        using errcode = 'invalid_parameter_value';
    end if;
    select s.settled, s.base_settled into v_settled, v_base_settled from app_private.invoice_settled(r.id) s;
    v_rem_amount := r.total - v_settled;
    v_rem_base := r.base_total - v_base_settled;
    if r.amt > v_rem_amount then
      raise exception 'INVALID: the allocation of % exceeds what is outstanding (%) on invoice %', r.amt, v_rem_amount, r.invoice_number
        using errcode = 'invalid_parameter_value';
    end if;
    v_base_ar := app_private.prorate_remaining(v_rem_amount, v_rem_base, r.amt, v_bscale);
    v_alloc_invoices := v_alloc_invoices || r.id;
    v_alloc_amts := v_alloc_amts || r.amt;
    v_alloc_bases := v_alloc_bases || v_base_ar;
    v_alloc_sum := v_alloc_sum + r.amt;
    v_base_ar_sum := v_base_ar_sum + v_base_ar;
  end loop;
  if v_n <> coalesce(array_length(v_ids, 1), 0) then
    raise exception 'INVALID: an invoice in the allocations does not exist in this Entity' using errcode = 'invalid_parameter_value';
  end if;

  if v_alloc_sum > p_amount then
    raise exception 'INVALID: the allocations (%) exceed the payment (%)', v_alloc_sum, p_amount
      using errcode = 'invalid_parameter_value';
  end if;
  v_adv := p_amount - v_alloc_sum;
  if v_adv > 0 then
    if not coalesce(p_allow_advance, false) then
      raise exception 'INVALID: the payment exceeds the selected invoices by %; allocate it or explicitly keep the rest as a customer advance', v_adv
        using errcode = 'invalid_parameter_value';
    end if;
    v_adv_acct := app_private.customer_advance_account(p_entity);
    if v_adv_acct is null then
      raise exception 'CONFLICT: this Entity has no customer-advance account, so an overpayment cannot be kept'
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;

  v_cash_base := case when fa.currency = v_base then p_amount else app_private.round_amount(p_amount * p_rate, v_bscale, 'half_up') end;
  v_alloc_cash_base := case when fa.currency = v_base then v_alloc_sum
                            else app_private.round_amount(v_alloc_sum * p_rate, v_bscale, 'half_up') end;
  if v_cash_base <= 0 then
    raise exception 'INVALID: the payment is too small to book in %', v_base using errcode = 'invalid_parameter_value';
  end if;
  v_adv_base := v_cash_base - v_alloc_cash_base;
  if v_adv > 0 and v_adv_base <= 0 then
    raise exception 'INVALID: the advance is too small to book in %', v_base using errcode = 'invalid_parameter_value';
  end if;
  v_fx := v_alloc_cash_base - v_base_ar_sum;
  if v_alloc_sum > 0 then
    perform app_private.assert_fx_reasonable(v_fx, v_alloc_cash_base);
  end if;
  if v_fx <> 0 then
    v_fx_acct := app_private.fx_account(p_entity);
    if v_fx_acct is null then
      raise exception 'CONFLICT: this Entity has no FX gain/loss account' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  select a.id into v_ar from public.ledger_accounts a
  where a.entity_id = p_entity and a.system_key = 'ACCOUNTS_RECEIVABLE' and a.status = 'active';

  perform app_private.ensure_sales_numbering(p_entity);
  v_number := app_private.allocate_document_number(p_entity, 'payment_receipt', p_date);
  v_desc := format('Payment %s - %s', v_number, c.display_name);

  v_lines := app_private.add_line(v_lines, fa.ledger_account_id, v_cash_base, 0, v_desc,
    app_private.orig_fields(fa.currency, v_base, p_amount, p_rate, v_cash_base));
  for k in 1 .. coalesce(array_length(v_alloc_invoices, 1), 0) loop
    select i.invoice_number, i.exchange_rate, i.currency into r from public.invoices i where i.id = v_alloc_invoices[k];
    v_lines := app_private.add_line(v_lines, v_ar, 0, v_alloc_bases[k], v_desc || ' / ' || r.invoice_number,
      app_private.orig_fields(r.currency, v_base, v_alloc_amts[k], r.exchange_rate, v_alloc_bases[k]));
  end loop;
  v_lines := app_private.add_line(v_lines, v_adv_acct, 0, v_adv_base, 'Customer advance: ' || v_desc,
    app_private.orig_fields(fa.currency, v_base, v_adv, p_rate, v_adv_base));
  v_lines := app_private.add_line(v_lines, v_fx_acct, case when v_fx < 0 then -v_fx else 0 end,
    case when v_fx > 0 then v_fx else 0 end, 'FX difference: ' || v_desc);

  v_journal := app_private.post_system_journal(
    p_entity, 'payment', v_payment, 'payment.confirm', 'payment.v1', p_date, v_desc, v_lines);
  perform app_private.record_movement(p_entity, p_account, 'in', p_amount, v_cash_base, p_rate, p_date,
    'payment', v_payment, 'principal', v_journal, v_desc);

  insert into public.payments
    (id, entity_id, payment_number, customer_id, financial_account_id, currency, amount, exchange_rate, base_amount,
     payment_date, reference, payer_name, payment_channel_id, submission_id, allocated_amount, advance_amount,
     advance_base, fx_difference, note, receipt_snapshot, journal_id)
  values
    (v_payment, p_entity, v_number, p_customer, p_account, fa.currency, p_amount, p_rate, v_cash_base, p_date,
     nullif(btrim(coalesce(p_reference, '')), ''), nullif(btrim(coalesce(p_payer, '')), ''), p_channel, p_submission,
     v_alloc_sum, v_adv, case when v_adv > 0 then v_adv_base else 0 end, v_fx,
     nullif(btrim(coalesce(p_note, '')), ''), app_private.document_parties(p_entity, p_customer, p_account, p_channel),
     v_journal);

  for k in 1 .. coalesce(array_length(v_alloc_invoices, 1), 0) loop
    insert into public.payment_allocations
      (entity_id, payment_id, invoice_id, kind, amount, base_ar_amount, allocation_date, journal_id)
    values (p_entity, v_payment, v_alloc_invoices[k], 'payment', v_alloc_amts[k], v_alloc_bases[k], p_date, v_journal);
  end loop;

  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_entity, 'PaymentConfirmed', 'payment', v_payment,
          jsonb_build_object('payment_number', v_number, 'amount', p_amount, 'currency', fa.currency));
  return v_payment;
end
$$;

create function public.record_payment(
  p_entity uuid, p_key text, p_customer uuid, p_account uuid, p_date date, p_amount numeric,
  p_allocations jsonb, p_rate numeric default null, p_reference text default null, p_payer_name text default null,
  p_channel uuid default null, p_allow_advance boolean default false, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.confirm_payment') then
    raise exception 'FORBIDDEN: missing invoices.confirm_payment' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('payment.record', p_entity, p_key,
    md5(jsonb_build_object('customer', p_customer, 'account', p_account, 'date', p_date, 'amount', p_amount,
                           'alloc', p_allocations, 'rate', p_rate, 'ref', p_reference, 'payer', p_payer_name,
                           'channel', p_channel, 'adv', coalesce(p_allow_advance, false), 'note', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform app_private.assert_maker_checker(p_entity, 'payments', 'confirm',
                                           app_private.approval_base_amount(p_entity, p_amount, p_rate), auth.uid(),
                                           'confirm this payment');
  v_id := app_private.confirm_payment_core(p_entity, p_customer, p_account, p_date, p_amount, p_rate, p_allocations,
                                           p_reference, p_payer_name, p_channel, null, p_allow_advance, p_note);
  perform app_private.idem_complete('payment.record', p_entity, p_key, 'payments', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ submissions ("Saya Sudah Bayar", Step 07 §4)
-- Validates and stores a claim; a claim identical to one still pending returns that one (no duplicate work).
-- Used by the public token RPC and by the staff workflow. It never touches the ledger.
create function app_private.insert_submission(
  p_invoice uuid, p_source text, p_amount numeric, p_date date, p_payer text, p_reference text, p_channel uuid,
  p_note text, p_client_hash text, p_created_by uuid)
returns table (submission_id uuid, was_existing boolean)
language plpgsql as $$
declare
  i public.invoices%rowtype;
  v_today date;
  v_scale integer;
  v_settled numeric;
  v_base_settled numeric;
  v_fp text;
  v_existing uuid;
  v_id uuid;
begin
  select * into i from public.invoices where id = p_invoice for share;
  if not found or i.status <> 'issued' then
    raise exception 'CONFLICT: this invoice does not accept payments' using errcode = 'integrity_constraint_violation';
  end if;
  select s.settled, s.base_settled into v_settled, v_base_settled from app_private.invoice_settled(i.id) s;
  if i.total - v_settled <= 0 then
    raise exception 'CONFLICT: this invoice is already paid' using errcode = 'integrity_constraint_violation';
  end if;
  v_scale := app_private.currency_scale(i.currency);
  v_today := app_private.entity_today(i.entity_id);
  if p_amount is null or not app_private.is_finite(p_amount) or p_amount <= 0
     or app_private.round_amount(p_amount, v_scale, 'down') <> p_amount then
    raise exception 'INVALID: enter the amount paid (at most % decimals)', v_scale using errcode = 'invalid_parameter_value';
  end if;
  if p_amount > i.total - v_settled then
    raise exception 'INVALID: the amount is more than what is outstanding on this invoice' using errcode = 'invalid_parameter_value';
  end if;
  if p_date is null or p_date > v_today or p_date < i.issue_date then
    raise exception 'INVALID: the payment date must be between the invoice date and today' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(p_payer, '')) > 200 or length(coalesce(p_reference, '')) > 200 or length(coalesce(p_note, '')) > 1000 then
    raise exception 'INVALID: a text field is too long' using errcode = 'invalid_parameter_value';
  end if;
  if p_channel is not null and not exists (
       select 1 from public.payment_channels ch where ch.id = p_channel and ch.entity_id = i.entity_id and ch.is_active) then
    raise exception 'INVALID: unknown payment channel' using errcode = 'invalid_parameter_value';
  end if;

  v_fp := md5(concat_ws('|', p_invoice::text, p_amount::text, p_date::text, lower(btrim(coalesce(p_reference, '')))));
  select s.id into v_existing from public.payment_submissions s
  where s.invoice_id = p_invoice and s.fingerprint = v_fp and s.status = 'pending' order by s.created_at limit 1;
  if v_existing is not null then
    return query select v_existing, true;
    return;
  end if;
  insert into public.payment_submissions
    (entity_id, invoice_id, source, amount, currency, payment_date, payer_name, payer_reference, payment_channel_id,
     note, fingerprint, client_hash, created_by)
  values
    (i.entity_id, p_invoice, p_source, p_amount, i.currency, p_date, nullif(btrim(coalesce(p_payer, '')), ''),
     nullif(btrim(coalesce(p_reference, '')), ''), p_channel, nullif(btrim(coalesce(p_note, '')), ''), v_fp,
     p_client_hash, p_created_by)
  returning id into v_id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (i.entity_id, 'PaymentSubmitted', 'payment_submission', v_id,
          jsonb_build_object('invoice_number', i.invoice_number, 'amount', p_amount, 'currency', i.currency));
  return query select v_id, false;
end
$$;

create function public.create_payment_claim(
  p_invoice uuid, p_key text, p_amount numeric, p_date date, p_payer_name text default null,
  p_reference text default null, p_channel uuid default null, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_replay uuid;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.edit') then
    raise exception 'FORBIDDEN: missing invoices.edit' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('payment.claim', i.entity_id, p_key,
    md5(jsonb_build_object('invoice', p_invoice, 'amount', p_amount, 'date', p_date, 'payer', p_payer_name,
                           'ref', p_reference, 'channel', p_channel, 'note', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select x.submission_id into v_id
  from app_private.insert_submission(p_invoice, 'staff', p_amount, p_date, p_payer_name, p_reference, p_channel,
                                     p_note, null, auth.uid()) x;
  perform app_private.idem_complete('payment.claim', i.entity_id, p_key, 'payment_submissions', v_id);
  return v_id;
end
$$;

-- Confirms a pending claim into a real payment allocated to its invoice. The reviewer chooses the receiving
-- account (defaulting to the invoice's payment account) and may correct the date or the amount actually received.
create function public.confirm_payment_submission(
  p_submission uuid, p_key text, p_account uuid default null, p_date date default null, p_amount numeric default null,
  p_rate numeric default null, p_allow_advance boolean default false, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.payment_submissions%rowtype;
  i public.invoices%rowtype;
  v_replay uuid;
  v_payment uuid;
  v_account uuid;
  v_amount numeric;
  v_settled numeric;
  v_base_settled numeric;
  v_alloc numeric;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into s from public.payment_submissions where id = p_submission;
  if not found or not app_authz.has_permission(s.entity_id, 'invoices.confirm_payment') then
    raise exception 'FORBIDDEN: missing invoices.confirm_payment' using errcode = 'insufficient_privilege';
  end if;
  -- Lock order everywhere is invoice, then payment/submission: cancelling or voiding the invoice rejects its
  -- pending claims, so confirming must not hold a claim while it waits for the invoice.
  perform 1 from public.invoices where id = s.invoice_id and entity_id = s.entity_id for update;
  select * into s from public.payment_submissions where id = p_submission for update;

  v_replay := app_private.idem_begin('payment_submission.confirm', s.entity_id, p_key,
    md5(jsonb_build_object('s', p_submission, 'account', p_account, 'date', p_date, 'amount', p_amount, 'rate', p_rate,
                           'adv', coalesce(p_allow_advance, false), 'note', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if s.status <> 'pending' then
    raise exception 'CONFLICT: this claim was already reviewed (%)', s.status using errcode = 'integrity_constraint_violation';
  end if;
  select * into i from public.invoices where id = s.invoice_id;
  if i.status <> 'issued' then
    raise exception 'CONFLICT: the invoice is % and cannot receive a payment', i.status using errcode = 'integrity_constraint_violation';
  end if;
  v_account := coalesce(p_account, i.payment_account_id);
  if v_account is null then
    raise exception 'INVALID: choose the account that received the money' using errcode = 'invalid_parameter_value';
  end if;
  v_amount := coalesce(p_amount, s.amount);
  perform app_private.assert_maker_checker(s.entity_id, 'payments', 'confirm',
    app_private.approval_base_amount(s.entity_id, v_amount, p_rate), s.created_by, 'confirm this payment');

  select x.settled, x.base_settled into v_settled, v_base_settled from app_private.invoice_settled(i.id) x;
  v_alloc := least(v_amount, i.total - v_settled);
  v_payment := app_private.confirm_payment_core(
    s.entity_id, i.customer_id, v_account, coalesce(p_date, s.payment_date), v_amount, p_rate,
    case when v_alloc > 0 then jsonb_build_array(jsonb_build_object('invoice_id', i.id, 'amount', v_alloc))
         else '[]'::jsonb end,
    s.payer_reference, s.payer_name, s.payment_channel_id, s.id, p_allow_advance, coalesce(p_note, s.note));
  update public.payment_submissions
  set status = 'confirmed', payment_id = v_payment, reviewed_by = auth.uid(), reviewed_at = now()
  where id = s.id;

  perform app_private.idem_complete('payment_submission.confirm', s.entity_id, p_key, 'payments', v_payment);
  return v_payment;
end
$$;

create function public.reject_payment_submission(p_submission uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.payment_submissions%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into s from public.payment_submissions where id = p_submission;
  if not found or not app_authz.has_permission(s.entity_id, 'invoices.confirm_payment') then
    raise exception 'FORBIDDEN: missing invoices.confirm_payment' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 3 then
    raise exception 'INVALID: a rejection needs a reason' using errcode = 'invalid_parameter_value';
  end if;
  select * into s from public.payment_submissions where id = p_submission for update;
  if s.status <> 'pending' then
    raise exception 'CONFLICT: this claim was already reviewed (%)', s.status using errcode = 'integrity_constraint_violation';
  end if;
  update public.payment_submissions
  set status = 'rejected', review_reason = v_reason, reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_submission;
  return 'rejected';
end
$$;

create function public.mark_submission_duplicate(p_submission uuid, p_of uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.payment_submissions%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into s from public.payment_submissions where id = p_submission;
  if not found or not app_authz.has_permission(s.entity_id, 'invoices.confirm_payment') then
    raise exception 'FORBIDDEN: missing invoices.confirm_payment' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 3 or p_of is null or p_of = p_submission then
    raise exception 'INVALID: name the other claim and give a reason' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.payment_submissions o
                 where o.id = p_of and o.entity_id = s.entity_id and o.invoice_id = s.invoice_id) then
    raise exception 'INVALID: the other claim must belong to the same invoice' using errcode = 'invalid_parameter_value';
  end if;
  select * into s from public.payment_submissions where id = p_submission for update;
  if s.status <> 'pending' then
    raise exception 'CONFLICT: this claim was already reviewed (%)', s.status using errcode = 'integrity_constraint_violation';
  end if;
  update public.payment_submissions
  set status = 'duplicate', duplicate_of = p_of, review_reason = v_reason, reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_submission;
  return 'duplicate';
end
$$;

-- ------------------------------------------------------------ applying a customer advance to an invoice
create function public.apply_payment_credit(
  p_payment uuid, p_invoice uuid, p_amount numeric, p_key text, p_date date default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p public.payments%rowtype;
  i public.invoices%rowtype;
  v_replay uuid;
  v_date date;
  v_today date;
  v_bscale integer;
  v_base public.currency_code;
  v_adv_amount numeric;
  v_adv_base numeric;
  v_settled numeric;
  v_base_settled numeric;
  v_used_base numeric;
  v_ar_base numeric;
  v_fx numeric;
  v_ar uuid;
  v_adv_acct uuid;
  v_fx_acct uuid;
  v_alloc uuid := gen_random_uuid();
  v_journal uuid;
  v_lines jsonb := '[]'::jsonb;
  v_desc text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into p from public.payments where id = p_payment;
  if not found or not app_authz.has_permission(p.entity_id, 'invoices.confirm_payment') then
    raise exception 'FORBIDDEN: missing invoices.confirm_payment' using errcode = 'insufficient_privilege';
  end if;
  -- Invoice first, then payment: the same order every command uses, so none of them can deadlock.
  select * into i from public.invoices where id = p_invoice and entity_id = p.entity_id for update;
  if not found then
    raise exception 'INVALID: the invoice is unknown in this Entity' using errcode = 'invalid_parameter_value';
  end if;
  select * into p from public.payments where id = p_payment for update;

  v_replay := app_private.idem_begin('payment.credit', p.entity_id, p_key,
    md5(jsonb_build_object('payment', p_payment, 'invoice', p_invoice, 'amount', p_amount, 'date', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;

  v_today := app_private.entity_today(p.entity_id);
  v_date := coalesce(p_date, v_today);
  perform app_private.assert_business_date(v_date);
  select e.base_currency into v_base from public.entities e where e.id = p.entity_id;
  v_bscale := app_private.currency_scale(v_base);
  if p.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed payment can be applied (now %)', p.status using errcode = 'integrity_constraint_violation';
  end if;
  if i.status <> 'issued' or i.customer_id <> p.customer_id or i.currency <> p.currency then
    raise exception 'INVALID: the invoice must be an issued invoice of the same customer in %', p.currency
      using errcode = 'invalid_parameter_value';
  end if;
  if v_date > v_today or v_date < p.payment_date or v_date < i.issue_date then
    raise exception 'INVALID: the application date must be between the payment and invoice dates and today'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_amount is null or not app_private.is_finite(p_amount) or p_amount <= 0
     or app_private.round_amount(p_amount, app_private.currency_scale(p.currency), 'down') <> p_amount then
    raise exception 'INVALID: the amount must be positive and allows % decimals for %',
      app_private.currency_scale(p.currency), p.currency using errcode = 'invalid_parameter_value';
  end if;

  select s.rem_amount, s.rem_base into v_adv_amount, v_adv_base from app_private.payment_advance_state(p.id) s;
  if p_amount > v_adv_amount then
    raise exception 'INVALID: only % of this payment is still available as a customer advance', v_adv_amount
      using errcode = 'invalid_parameter_value';
  end if;
  select s.settled, s.base_settled into v_settled, v_base_settled from app_private.invoice_settled(i.id) s;
  if p_amount > i.total - v_settled then
    raise exception 'INVALID: the amount exceeds what is outstanding (%) on invoice %', i.total - v_settled, i.invoice_number
      using errcode = 'invalid_parameter_value';
  end if;

  v_used_base := app_private.prorate_remaining(v_adv_amount, v_adv_base, p_amount, v_bscale);
  v_ar_base := app_private.prorate_remaining(i.total - v_settled, i.base_total - v_base_settled, p_amount, v_bscale);
  -- The advance was carried at the payment rate, the receivable at the invoice rate.
  v_fx := v_used_base - v_ar_base;
  perform app_private.assert_fx_reasonable(v_fx, greatest(v_used_base, 1));
  v_adv_acct := app_private.customer_advance_account(p.entity_id);
  select a.id into v_ar from public.ledger_accounts a
  where a.entity_id = p.entity_id and a.system_key = 'ACCOUNTS_RECEIVABLE' and a.status = 'active';
  if v_fx <> 0 then
    v_fx_acct := app_private.fx_account(p.entity_id);
    if v_fx_acct is null then
      raise exception 'CONFLICT: this Entity has no FX gain/loss account' using errcode = 'integrity_constraint_violation';
    end if;
  end if;

  v_desc := format('Apply advance of %s to %s', p.payment_number, i.invoice_number);
  v_lines := app_private.add_line(v_lines, v_adv_acct, v_used_base, 0, v_desc);
  v_lines := app_private.add_line(v_lines, v_ar, 0, v_ar_base, v_desc,
    app_private.orig_fields(i.currency, v_base, p_amount, i.exchange_rate, v_ar_base));
  v_lines := app_private.add_line(v_lines, v_fx_acct, case when v_fx < 0 then -v_fx else 0 end,
    case when v_fx > 0 then v_fx else 0 end, 'FX difference: ' || v_desc);
  v_journal := app_private.post_system_journal(
    p.entity_id, 'payment_credit', v_alloc, 'payment_credit.apply', 'payment_credit.v1', v_date, v_desc, v_lines);

  insert into public.payment_allocations
    (id, entity_id, payment_id, invoice_id, kind, amount, base_ar_amount, advance_base_used, fx_difference,
     allocation_date, journal_id)
  values (v_alloc, p.entity_id, p.id, i.id, 'credit', p_amount, v_ar_base, v_used_base, v_fx, v_date, v_journal);

  perform app_private.idem_complete('payment.credit', p.entity_id, p_key, 'payment_allocations', v_alloc);
  return v_alloc;
end
$$;

-- ------------------------------------------------------------ reversing a credit application / a payment
create function public.reverse_credit_application(p_allocation uuid, p_key text, p_date date, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  a public.payment_allocations%rowtype;
  p public.payments%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into a from public.payment_allocations where id = p_allocation;
  if not found or a.kind <> 'credit' or not app_authz.has_permission(a.entity_id, 'invoices.confirm_payment') then
    raise exception 'FORBIDDEN: missing invoices.confirm_payment' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 or p_date > app_private.entity_today(a.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of at least 5 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform 1 from public.invoices where id = a.invoice_id and entity_id = a.entity_id for update;
  select * into p from public.payments where id = a.payment_id for update;
  select * into a from public.payment_allocations where id = p_allocation for update;

  v_replay := app_private.idem_begin('payment.credit_reverse', a.entity_id, p_key,
    md5(jsonb_build_object('a', p_allocation, 'date', p_date, 'reason', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if a.status <> 'active' then
    raise exception 'CONFLICT: this application was already reversed' using errcode = 'integrity_constraint_violation';
  end if;
  if exists (select 1 from public.refund_items ri join public.refunds r on r.id = ri.refund_id
             where ri.allocation_id = a.id and r.status = 'confirmed') then
    raise exception 'CONFLICT: a refund was made from this application; reverse the refund first'
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(a.journal_id, p_date, v_reason);
  update public.payment_allocations
  set status = 'reversed', reversed_at = now(), reversed_date = p_date, reversal_journal_id = v_rev
  where id = a.id;
  perform app_private.idem_complete('payment.credit_reverse', a.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

create function public.reverse_payment(p_payment uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p public.payments%rowtype;
  a public.payment_allocations%rowtype;
  m public.money_movements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
  v_arev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into p from public.payments where id = p_payment;
  if not found or not app_authz.has_permission(p.entity_id, 'invoices.confirm_payment') then
    raise exception 'FORBIDDEN: missing invoices.confirm_payment' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 or p_date > app_private.entity_today(p.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of at least 5 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  -- Invoices first (fixed order), then the payment: the order every command uses.
  perform 1 from public.invoices i
  where i.entity_id = p.entity_id
    and i.id in (select x.invoice_id from public.payment_allocations x where x.payment_id = p.id)
  order by i.id for update;
  select * into p from public.payments where id = p_payment for update;

  v_replay := app_private.idem_begin('payment.reverse', p.entity_id, p_key,
    md5(jsonb_build_object('payment', p_payment, 'date', p_date, 'reason', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed payment can be reversed (now %)', p.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if exists (select 1 from public.refunds r where r.payment_id = p.id and r.status = 'confirmed') then
    raise exception 'CONFLICT: this payment has confirmed refunds; reverse them first' using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < p.payment_date then
    raise exception 'INVALID: a reversal cannot be dated before the payment' using errcode = 'invalid_parameter_value';
  end if;
  perform 1 from public.financial_accounts where id = p.financial_account_id and entity_id = p.entity_id for no key update;

  perform set_config('app.audit_reason', v_reason, true);
  -- Credit applications made from this payment go first (newest first), each with its own journal.
  for a in
    select * from public.payment_allocations
    where payment_id = p.id and kind = 'credit' and status = 'active' order by created_at desc, id
  loop
    v_arev := app_private.reverse_journal_core(a.journal_id, p_date, v_reason);
    update public.payment_allocations
    set status = 'reversed', reversed_at = now(), reversed_date = p_date, reversal_journal_id = v_arev
    where id = a.id;
  end loop;

  v_rev := app_private.reverse_journal_core(p.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = p.entity_id and source_type = 'payment' and source_id = p.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(
      p.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'payment', p.id, m.component, v_rev,
      'Reversal: ' || v_reason, m.id);
  end loop;
  update public.payment_allocations
  set status = 'reversed', reversed_at = now(), reversed_date = p_date, reversal_journal_id = v_rev
  where payment_id = p.id and kind = 'payment' and status = 'active';
  update public.payments
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date,
      reversed_by = auth.uid(), reverse_reason = v_reason
  where id = p.id;

  perform app_private.idem_complete('payment.reverse', p.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

-- ------------------------------------------------------------ cancel / void / correct (Step 07 §3)
-- Draft -> cancelled: no accounting effect. Issued -> cancelled or void: the issuing journal is reversed by a
-- linked reversal, the public link is revoked and pending claims are rejected. An invoice that has active
-- payment allocations cannot be closed: its payments must be reversed first, so no cash is ever orphaned.
-- Assumes the caller holds the invoice row lock and checked permission and idempotency.
create function app_private.close_invoice_core(
  p_invoice uuid, p_target text, p_reason text, p_date date, p_replacement uuid default null)
returns void
language plpgsql as $$
declare
  i public.invoices%rowtype;
  v_today date;
  v_date date;
  v_rev uuid;
  v_n bigint;
  v_min date;
begin
  select * into i from public.invoices where id = p_invoice;
  v_today := app_private.entity_today(i.entity_id);
  v_date := coalesce(p_date, v_today);
  perform set_config('app.audit_reason', p_reason, true);

  if i.status = 'draft' then
    if p_target <> 'cancelled' then
      raise exception 'INVALID: a draft invoice is cancelled, not voided' using errcode = 'invalid_parameter_value';
    end if;
    update public.invoices
    set status = 'cancelled', closed_at = now(), closed_by = auth.uid(), closed_date = v_today, closed_reason = p_reason,
        replaced_by_invoice_id = p_replacement
    where id = i.id;
    return;
  end if;

  if i.status <> 'issued' then
    raise exception 'CONFLICT: the invoice is already %', i.status using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(v_date);
  if v_date > v_today then
    raise exception 'INVALID: the date cannot be in the future' using errcode = 'invalid_parameter_value';
  end if;
  select count(*) into v_n from public.payment_allocations a where a.invoice_id = i.id and a.status = 'active';
  if v_n > 0 then
    raise exception 'CONFLICT: this invoice has % active payment allocation(s); reverse those payments first', v_n
      using errcode = 'integrity_constraint_violation';
  end if;
  -- Closing is dated after every payment and reversal on the invoice, so the receivable never goes negative on
  -- any day in between (the sub-ledger and the ledger agree as of every date).
  select greatest(i.issue_date, coalesce(max(a.allocation_date), i.issue_date), coalesce(max(a.reversed_date), i.issue_date))
    into v_min from public.payment_allocations a where a.invoice_id = i.id;
  if v_date < v_min then
    raise exception 'INVALID: the date cannot be before the last payment activity on this invoice (%)', v_min
      using errcode = 'invalid_parameter_value';
  end if;

  v_rev := app_private.reverse_journal_core(i.journal_id, v_date, p_reason);
  update public.invoice_public_links
  set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), revoked_reason = 'invoice ' || p_target
  where invoice_id = i.id and status = 'active';
  update public.payment_submissions
  set status = 'rejected', review_reason = 'The invoice was ' || p_target, reviewed_by = auth.uid(), reviewed_at = now()
  where invoice_id = i.id and status = 'pending';
  update public.invoices
  set status = p_target, reversal_journal_id = v_rev, closed_at = now(), closed_by = auth.uid(), closed_date = v_date,
      closed_reason = p_reason, replaced_by_invoice_id = p_replacement
  where id = i.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (i.entity_id, case p_target when 'void' then 'InvoiceVoided' else 'InvoiceCancelled' end, 'invoice', i.id,
          jsonb_build_object('invoice_number', i.invoice_number));
end
$$;

create function public.cancel_invoice(p_invoice uuid, p_key text, p_reason text, p_date date default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not (app_authz.has_permission(i.entity_id, 'invoices.edit')
                       or app_authz.has_permission(i.entity_id, 'invoices.void')) then
    raise exception 'FORBIDDEN: missing invoices.void' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 5 then
    raise exception 'INVALID: a cancellation needs a reason of at least 5 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into i from public.invoices where id = p_invoice for update;
  if not app_authz.has_permission(i.entity_id, case when i.status = 'draft' then 'invoices.edit' else 'invoices.void' end) then
    raise exception 'FORBIDDEN: missing invoices.void' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('invoice.close', i.entity_id, p_key,
    md5(jsonb_build_object('i', p_invoice, 't', 'cancelled', 'r', v_reason, 'd', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform app_private.close_invoice_core(p_invoice, 'cancelled', v_reason, p_date);
  perform app_private.idem_complete('invoice.close', i.entity_id, p_key, 'invoices', p_invoice);
  return p_invoice;
end
$$;

create function public.void_invoice(p_invoice uuid, p_key text, p_reason text, p_date date default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.void') then
    raise exception 'FORBIDDEN: missing invoices.void' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 5 then
    raise exception 'INVALID: voiding needs a reason of at least 5 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into i from public.invoices where id = p_invoice for update;
  v_replay := app_private.idem_begin('invoice.close', i.entity_id, p_key,
    md5(jsonb_build_object('i', p_invoice, 't', 'void', 'r', v_reason, 'd', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if i.status <> 'issued' then
    raise exception 'CONFLICT: only an issued invoice can be voided (now %)', i.status using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.close_invoice_core(p_invoice, 'void', v_reason, p_date);
  perform app_private.idem_complete('invoice.close', i.entity_id, p_key, 'invoices', p_invoice);
  return p_invoice;
end
$$;

-- Correction by replacement: the original is voided (reversal journal, link revoked) and a new DRAFT copy is
-- created that points back to it. The copy keeps lines, customer and dates so the user only edits what was wrong.
create function public.correct_invoice(p_invoice uuid, p_key text, p_reason text, p_date date default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_new uuid;
  v_lines jsonb;
  v_prep jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.void')
     or not app_authz.has_permission(i.entity_id, 'invoices.create') then
    raise exception 'FORBIDDEN: correcting an invoice needs invoices.void and invoices.create'
      using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 5 then
    raise exception 'INVALID: a correction needs a reason of at least 5 characters' using errcode = 'invalid_parameter_value';
  end if;
  select * into i from public.invoices where id = p_invoice for update;
  v_replay := app_private.idem_begin('invoice.correct', i.entity_id, p_key,
    md5(jsonb_build_object('i', p_invoice, 'r', v_reason, 'd', p_date)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if i.status <> 'issued' then
    raise exception 'CONFLICT: only an issued invoice can be corrected (now %)', i.status using errcode = 'integrity_constraint_violation';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'product_id', l.product_id, 'description', l.description, 'quantity', l.quantity, 'unit_price', l.unit_price,
      'discount_type', l.discount_type, 'discount_value', l.discount_value, 'category_id', l.category_id)
      order by l.line_no), '[]'::jsonb)
    into v_lines from public.invoice_lines l where l.invoice_id = i.id;
  -- The lines were valid when issued: a product deactivated since then must not block the correction.
  v_prep := app_private.invoice_prepare_lines(i.entity_id, i.currency, v_lines, true);
  insert into public.invoices
    (entity_id, customer_id, currency, exchange_rate, issue_date, due_date, payment_account_id, payment_channel_id,
     notes, terms, payment_note, internal_note, subtotal, discount_total, total, replaces_invoice_id)
  values
    (i.entity_id, i.customer_id, i.currency, i.exchange_rate, i.issue_date, i.due_date, i.payment_account_id,
     i.payment_channel_id, i.notes, i.terms, i.payment_note,
     left('Replaces ' || i.invoice_number || ': ' || v_reason, 2000),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'discount_total')::numeric, (v_prep ->> 'total')::numeric, i.id)
  returning id into v_new;
  perform app_private.invoice_write_lines(i.entity_id, v_new, v_prep);

  perform app_private.close_invoice_core(p_invoice, 'void', v_reason, p_date, v_new);
  perform app_private.idem_complete('invoice.correct', i.entity_id, p_key, 'invoices', v_new);
  return v_new;
end
$$;

-- The due date is the one commercial term that may change after issue (Step 07 §3): audited, with a reason,
-- and never before the issue date. The frozen snapshot on the document is unaffected.
create function public.update_invoice_due_date(p_invoice uuid, p_due_date date, p_reason text) returns date
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.edit') then
    raise exception 'FORBIDDEN: missing invoices.edit' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 3 or p_due_date is null then
    raise exception 'INVALID: a new due date and a reason are required' using errcode = 'invalid_parameter_value';
  end if;
  select * into i from public.invoices where id = p_invoice for update;
  if i.status <> 'issued' then
    raise exception 'CONFLICT: only an issued invoice has a due date to change (now %)', i.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_business_date(p_due_date);
  if p_due_date < i.issue_date then
    raise exception 'INVALID: the due date cannot be before the issue date' using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.invoices set due_date = p_due_date where id = i.id;
  return p_due_date;
end
$$;

-- ------------------------------------------------------------ reading: positions and control
create function public.list_invoice_positions(
  p_entity uuid, p_filter text default null, p_customer uuid default null, p_as_of date default null)
returns table (
  invoice_id uuid, invoice_number text, customer_id uuid, customer_name text, currency text, status text,
  issue_date date, due_date date, total text, settled text, outstanding text, base_outstanding text,
  refunded text, settlement_status text, refund_status text, is_overdue boolean, days_overdue integer)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.view') then
    raise exception 'FORBIDDEN: missing invoices.view' using errcode = 'insufficient_privilege';
  end if;
  if p_filter is not null and p_filter not in ('open', 'overdue', 'paid', 'unpaid', 'partial', 'closed') then
    raise exception 'INVALID: unknown filter' using errcode = 'invalid_parameter_value';
  end if;
  return query
  select p.invoice_id, p.invoice_number, p.customer_id, c.display_name, p.currency::text, p.status, p.issue_date,
         p.due_date, p.total::text, p.settled::text, p.outstanding::text, p.base_outstanding::text, p.refunded::text,
         p.settlement_status, p.refund_status, p.is_overdue, p.days_overdue
  from app_private.invoice_positions(p_entity, p_as_of) p
  join public.contacts c on c.id = p.customer_id and c.entity_id = p_entity
  where (p_customer is null or p.customer_id = p_customer)
    and case p_filter
          when 'open' then p.status = 'issued' and p.outstanding > 0
          when 'overdue' then p.is_overdue
          when 'paid' then p.settlement_status = 'paid'
          when 'unpaid' then p.settlement_status = 'unpaid'
          when 'partial' then p.settlement_status = 'partial'
          when 'closed' then p.status in ('cancelled', 'void')
          else true end
  order by p.issue_date desc, p.invoice_number desc;
end
$$;

create function public.ar_control_report(p_entity uuid, p_as_of date default null)
returns table (
  sub_ledger text, ledger_sales text, ledger_total text, difference text, other_ledger text,
  advance_sub_ledger text, advance_ledger_sales text, advance_ledger_total text, advance_difference text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.view') then
    raise exception 'FORBIDDEN: missing invoices.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select c.sub_ledger::text, c.ledger_sales::text, c.ledger_total::text, (c.ledger_sales - c.sub_ledger)::text,
         (c.ledger_total - c.ledger_sales)::text, c.advance_sub_ledger::text, c.advance_ledger_sales::text,
         c.advance_ledger_total::text, (c.advance_ledger_sales - c.advance_sub_ledger)::text
  from app_private.ar_control(p_entity, p_as_of) c;
end
$$;

-- ------------------------------------------------------------ period close checks (final form for P5)
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
end
$$;
-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.payments');
create policy payments_select on public.payments for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view'));
call app_private.expose_select('public.payment_allocations');
create policy payment_allocations_select on public.payment_allocations for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view'));
call app_private.expose_select('public.payment_submissions', array['client_hash']);
create policy payment_submissions_select on public.payment_submissions for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view'));

revoke all on function app_private.prorate_remaining(numeric, numeric, numeric, integer) from public;
revoke all on function app_private.orig_fields(public.currency_code, public.currency_code, numeric, numeric, numeric) from public;
revoke all on function app_private.add_line(jsonb, uuid, numeric, numeric, text, jsonb) from public;
revoke all on function app_private.customer_advance_account(uuid) from public;
revoke all on function app_private.fx_account(uuid) from public;
revoke all on function app_private.assert_fx_reasonable(numeric, numeric) from public;
revoke all on function app_private.document_parties(uuid, uuid, uuid, uuid) from public;
revoke all on function app_private.tg_payments_guard() from public;
revoke all on function app_private.tg_allocations_guard() from public;
revoke all on function app_private.tg_allocations_capacity() from public;
revoke all on function app_private.tg_submissions_guard() from public;
revoke all on function app_private.tg_public_links_insert_guard() from public;
revoke all on function app_private.invoice_settled(uuid, date) from public;
revoke all on function app_private.payment_advance_state(uuid) from public;
revoke all on function app_private.allocation_refund_state(uuid) from public;
revoke all on function app_private.invoice_positions(uuid, date) from public;
revoke all on function app_private.is_sales_journal(uuid) from public;
revoke all on function app_private.ar_control(uuid, date) from public;
revoke all on function app_private.confirm_payment_core(uuid, uuid, uuid, date, numeric, numeric, jsonb, text, text, uuid, uuid, boolean, text) from public;
revoke all on function app_private.insert_submission(uuid, text, numeric, date, text, text, uuid, text, text, uuid) from public;
revoke all on function app_private.close_invoice_core(uuid, text, text, date, uuid) from public;
revoke all on function app_private.period_blockers(uuid) from public;

revoke all on function public.record_payment(uuid, text, uuid, uuid, date, numeric, jsonb, numeric, text, text, uuid, boolean, text) from public, anon;
revoke all on function public.create_payment_claim(uuid, text, numeric, date, text, text, uuid, text) from public, anon;
revoke all on function public.confirm_payment_submission(uuid, text, uuid, date, numeric, numeric, boolean, text) from public, anon;
revoke all on function public.reject_payment_submission(uuid, text) from public, anon;
revoke all on function public.mark_submission_duplicate(uuid, uuid, text) from public, anon;
revoke all on function public.apply_payment_credit(uuid, uuid, numeric, text, date) from public, anon;
revoke all on function public.reverse_credit_application(uuid, text, date, text) from public, anon;
revoke all on function public.reverse_payment(uuid, text, date, text) from public, anon;
revoke all on function public.cancel_invoice(uuid, text, text, date) from public, anon;
revoke all on function public.void_invoice(uuid, text, text, date) from public, anon;
revoke all on function public.correct_invoice(uuid, text, text, date) from public, anon;
revoke all on function public.update_invoice_due_date(uuid, date, text) from public, anon;
revoke all on function public.list_invoice_positions(uuid, text, uuid, date) from public, anon;
revoke all on function public.ar_control_report(uuid, date) from public, anon;
grant execute on function public.record_payment(uuid, text, uuid, uuid, date, numeric, jsonb, numeric, text, text, uuid, boolean, text) to authenticated;
grant execute on function public.create_payment_claim(uuid, text, numeric, date, text, text, uuid, text) to authenticated;
grant execute on function public.confirm_payment_submission(uuid, text, uuid, date, numeric, numeric, boolean, text) to authenticated;
grant execute on function public.reject_payment_submission(uuid, text) to authenticated;
grant execute on function public.mark_submission_duplicate(uuid, uuid, text) to authenticated;
grant execute on function public.apply_payment_credit(uuid, uuid, numeric, text, date) to authenticated;
grant execute on function public.reverse_credit_application(uuid, text, date, text) to authenticated;
grant execute on function public.reverse_payment(uuid, text, date, text) to authenticated;
grant execute on function public.cancel_invoice(uuid, text, text, date) to authenticated;
grant execute on function public.void_invoice(uuid, text, text, date) to authenticated;
grant execute on function public.correct_invoice(uuid, text, text, date) to authenticated;
grant execute on function public.update_invoice_due_date(uuid, date, text) to authenticated;
grant execute on function public.list_invoice_positions(uuid, text, uuid, date) to authenticated;
grant execute on function public.ar_control_report(uuid, date) to authenticated;
