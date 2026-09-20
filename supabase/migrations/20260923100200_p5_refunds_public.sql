-- P5 (Step 15 §9) part 3: refunds, the public token surface, receipts/documents and AR aging.
-- Authority: Step 04 §3 (refund posting), Step 07 §4/§7/§8 (public payment workflow, payment and refund
-- workflows), Step 08 §8/§9 (refund limits, public tokens), Step 11 §8-§11/§21 (public page, receipts, token scope),
-- Step 17 §16 (public token security).
--
-- Model
--   * A refund always references ONE confirmed payment and takes its money from designated sources: an allocation
--     of that payment to an invoice (the sale is reduced through the contra-revenue account; the receivable stays
--     settled) and/or the unapplied customer advance (the liability is reduced). The refundable amount is
--     recalculated inside the confirming transaction, under a lock on the payment.
--   * The public surface is two token-scoped functions callable by the anonymous role. Nothing else is granted to
--     it. A public claim can never reach the ledger.

-- ------------------------------------------------------------ refunds
create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  refund_number text,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'rejected', 'cancelled', 'reversed')),
  payment_id uuid not null,
  customer_id uuid not null,
  financial_account_id uuid not null,
  currency public.currency_code not null,
  amount public.money_amount not null check (amount > 0),
  exchange_rate public.fx_rate,
  -- Cash side in base currency; fixed at confirmation.
  base_amount public.money_amount check (base_amount is null or base_amount > 0),
  refund_date date not null,
  -- Internal reason. The customer sees only `customer_reason`, and only if the user chose to set one (Step 11 §11).
  reason text not null check (length(btrim(reason)) between 3 and 1000),
  customer_reason text check (customer_reason is null or length(customer_reason) <= 500),
  reference text check (reference is null or length(reference) <= 200),
  receipt_snapshot jsonb,
  journal_id uuid,
  reversal_journal_id uuid,
  confirmed_at timestamptz,
  confirmed_by uuid,
  closed_at timestamptz,
  closed_by uuid,
  closed_reason text,
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
  foreign key (entity_id, payment_id) references public.payments (entity_id, id) on delete restrict,
  foreign key (entity_id, customer_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, financial_account_id, currency)
    references public.financial_accounts (entity_id, id, currency) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint refund_state_consistent check (
    case status
      when 'draft' then refund_number is null and journal_id is null and reversal_journal_id is null
        and base_amount is null and confirmed_at is null and closed_at is null and receipt_snapshot is null
      when 'confirmed' then refund_number is not null and journal_id is not null and base_amount is not null
        and confirmed_at is not null and reversal_journal_id is null and closed_at is null and receipt_snapshot is not null
      when 'reversed' then refund_number is not null and journal_id is not null and base_amount is not null
        and reversal_journal_id is not null and reversed_at is not null and reversed_date is not null
        and reverse_reason is not null and receipt_snapshot is not null
      else journal_id is null and refund_number is null and closed_at is not null and closed_reason is not null
    end)
);
create unique index refunds_number_uq on public.refunds (entity_id, refund_number) where refund_number is not null;
create index refunds_payment_idx on public.refunds (entity_id, payment_id, status);
create index refunds_entity_date_idx on public.refunds (entity_id, refund_date);

create function app_private.tg_refunds_guard() returns trigger
language plpgsql as $$
begin
  if (new.payment_id, new.customer_id, new.financial_account_id, new.currency, new.amount, new.exchange_rate,
      new.refund_date, new.reason, new.customer_reason, new.reference, new.created_at, new.created_by)
     is distinct from
     (old.payment_id, old.customer_id, old.financial_account_id, old.currency, old.amount, old.exchange_rate,
      old.refund_date, old.reason, old.customer_reason, old.reference, old.created_at, old.created_by) then
    raise exception 'The content of a refund cannot be changed; cancel the draft or reverse the refund'
      using errcode = 'integrity_constraint_violation';
  end if;
  if old.status in ('rejected', 'cancelled', 'reversed') then
    raise exception 'A % refund cannot change any more', old.status using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status
     and (old.status, new.status) not in
         (('draft', 'confirmed'), ('draft', 'rejected'), ('draft', 'cancelled'), ('confirmed', 'reversed')) then
    raise exception 'A refund cannot move from % to %', old.status, new.status using errcode = 'integrity_constraint_violation';
  end if;
  if old.status = 'confirmed' and new.status = 'confirmed'
     and (new.journal_id, new.refund_number, new.base_amount) is distinct from (old.journal_id, old.refund_number, old.base_amount) then
    raise exception 'The posting of a confirmed refund cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.refunds
  for each row execute function app_private.tg_refunds_guard();
create trigger tg_forbid_delete before delete on public.refunds
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.refunds
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.refunds');
call app_private.secure_table('public.refunds');
create trigger tg_audit after insert or update or delete on public.refunds
  for each row execute function app_private.tg_audit('entity_id');

-- Where the refunded money comes from: an allocation of the payment (a sale is reduced) or, when the allocation
-- is null, the unapplied customer advance.
create table public.refund_items (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  refund_id uuid not null,
  allocation_id uuid,
  amount public.money_amount not null check (amount > 0),
  -- Base value debited (contra-revenue or advance); fixed at confirmation.
  base_amount public.money_amount check (base_amount is null or base_amount >= 0),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, refund_id) references public.refunds (entity_id, id) on delete restrict,
  foreign key (entity_id, allocation_id) references public.payment_allocations (entity_id, id) on delete restrict
);
create unique index refund_items_alloc_uq on public.refund_items (refund_id, allocation_id) where allocation_id is not null;
create unique index refund_items_advance_uq on public.refund_items (refund_id) where allocation_id is null;
create index refund_items_allocation_idx on public.refund_items (entity_id, allocation_id);

create function app_private.tg_refund_items_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
begin
  select r.status into v_status from public.refunds r
  where r.id = new.refund_id and r.entity_id = new.entity_id for share;
  if v_status is distinct from 'draft' then
    raise exception 'The items of a % refund are frozen', coalesce(v_status, 'missing')
      using errcode = 'integrity_constraint_violation';
  end if;
  if tg_op = 'UPDATE' and ((new.refund_id, new.allocation_id, new.amount, new.created_at)
                           is distinct from (old.refund_id, old.allocation_id, old.amount, old.created_at)
                           or old.base_amount is not null) then
    raise exception 'A refund item can only receive its base value once, at confirmation'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.refund_items
  for each row execute function app_private.tg_refund_items_guard();
create trigger tg_forbid_delete before delete on public.refund_items
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.refund_items
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.refund_items');
call app_private.secure_table('public.refund_items');
create trigger tg_audit after insert or update or delete on public.refund_items
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ refund figures
-- Checks every item of a refund against what is refundable NOW and returns the base values. With p_apply the
-- values are written to the items (confirmation); without it nothing changes (a draft's preliminary check).
-- Callers hold the lock on the payment.
create function app_private.refund_compute(p_refund uuid, p_apply boolean)
returns table (contra_base numeric, advance_base numeric)
language plpgsql as $$
declare
  r public.refunds%rowtype;
  it record;
  a public.payment_allocations%rowtype;
  v_rem_amount numeric;
  v_rem_base numeric;
  v_base numeric;
  v_bscale integer;
  v_contra numeric := 0;
  v_adv numeric := 0;
begin
  select * into r from public.refunds where id = p_refund;
  v_bscale := app_private.currency_scale(app_private.entity_base_currency(r.entity_id));
  for it in select * from public.refund_items where refund_id = p_refund order by allocation_id nulls last, id loop
    if it.allocation_id is not null then
      select * into a from public.payment_allocations where id = it.allocation_id and entity_id = r.entity_id;
      if not found or a.payment_id <> r.payment_id or a.status <> 'active' then
        raise exception 'INVALID: a refund item does not belong to an active allocation of this payment'
          using errcode = 'invalid_parameter_value';
      end if;
      if r.refund_date < a.allocation_date then
        raise exception 'INVALID: the refund date cannot be before the allocation it refunds (%)', a.allocation_date
          using errcode = 'invalid_parameter_value';
      end if;
      select s.rem_amount, s.rem_base into v_rem_amount, v_rem_base from app_private.allocation_refund_state(a.id) s;
      if it.amount > v_rem_amount then
        raise exception 'INVALID: only % can still be refunded from this allocation', v_rem_amount
          using errcode = 'invalid_parameter_value';
      end if;
      v_base := app_private.prorate_remaining(v_rem_amount, v_rem_base, it.amount, v_bscale);
      v_contra := v_contra + v_base;
    else
      select s.rem_amount, s.rem_base into v_rem_amount, v_rem_base from app_private.payment_advance_state(r.payment_id) s;
      if v_rem_amount <= 0 or it.amount > v_rem_amount then
        raise exception 'INVALID: only % of the customer advance can still be refunded', greatest(v_rem_amount, 0)
          using errcode = 'invalid_parameter_value';
      end if;
      v_base := app_private.prorate_remaining(v_rem_amount, v_rem_base, it.amount, v_bscale);
      v_adv := v_adv + v_base;
    end if;
    if p_apply then
      update public.refund_items set base_amount = v_base where id = it.id;
    end if;
  end loop;
  return query select v_contra, v_adv;
end
$$;

-- Books a draft refund. Assumes the caller holds the payment lock and checked permission and idempotency.
create function app_private.confirm_refund_core(p_refund uuid) returns uuid
language plpgsql as $$
declare
  r public.refunds%rowtype;
  p public.payments%rowtype;
  fa public.financial_accounts%rowtype;
  e public.entities%rowtype;
  v_contra_base numeric;
  v_adv_base numeric;
  v_cash_base numeric;
  v_fx numeric;
  v_bscale integer;
  v_today date;
  v_contra uuid;
  v_adv_acct uuid;
  v_fx_acct uuid;
  v_lines jsonb := '[]'::jsonb;
  v_desc text;
  v_journal uuid;
  v_number text;
  v_payment_number text;
begin
  select * into r from public.refunds where id = p_refund;
  select * into p from public.payments where id = r.payment_id;
  select * into e from public.entities where id = r.entity_id;
  if r.status <> 'draft' then
    raise exception 'CONFLICT: only a draft refund can be confirmed (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  if p.status <> 'confirmed' then
    raise exception 'CONFLICT: the payment is % and cannot be refunded', p.status using errcode = 'integrity_constraint_violation';
  end if;
  v_today := app_private.entity_today(r.entity_id);
  v_bscale := app_private.currency_scale(e.base_currency);
  if r.refund_date > v_today or r.refund_date < p.payment_date then
    raise exception 'INVALID: the refund date must be between the payment date and today' using errcode = 'invalid_parameter_value';
  end if;
  select * into fa from public.financial_accounts where id = r.financial_account_id and entity_id = r.entity_id;
  if not fa.is_active then
    raise exception 'CONFLICT: the paying-out account is inactive' using errcode = 'integrity_constraint_violation';
  end if;

  select c.contra_base, c.advance_base into v_contra_base, v_adv_base from app_private.refund_compute(r.id, true) c;
  v_cash_base := case when r.currency = e.base_currency then r.amount
                      else app_private.round_amount(r.amount * r.exchange_rate, v_bscale, 'half_up') end;
  if v_cash_base <= 0 then
    raise exception 'INVALID: the refund is too small to book in %', e.base_currency using errcode = 'invalid_parameter_value';
  end if;
  v_fx := v_cash_base - (v_contra_base + v_adv_base);
  perform app_private.assert_fx_reasonable(v_fx, v_cash_base);

  if v_contra_base > 0 then
    v_contra := app_private.sales_contra_account(r.entity_id);
    if v_contra is null then
      raise exception 'CONFLICT: this Entity has no account to book refunds of sales on' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  if v_adv_base > 0 then
    v_adv_acct := app_private.customer_advance_account(r.entity_id);
    if v_adv_acct is null then
      raise exception 'CONFLICT: this Entity has no customer-advance account' using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  if v_fx <> 0 then
    v_fx_acct := app_private.fx_account(r.entity_id);
    if v_fx_acct is null then
      raise exception 'CONFLICT: this Entity has no FX gain/loss account' using errcode = 'integrity_constraint_violation';
    end if;
  end if;

  perform app_private.ensure_sales_numbering(r.entity_id);
  v_number := app_private.allocate_document_number(r.entity_id, 'refund_receipt', r.refund_date);
  v_payment_number := p.payment_number;
  v_desc := format('Refund %s of payment %s', v_number, v_payment_number);

  v_lines := app_private.add_line(v_lines, v_contra, v_contra_base, 0, v_desc);
  v_lines := app_private.add_line(v_lines, v_adv_acct, v_adv_base, 0, 'Customer advance: ' || v_desc);
  v_lines := app_private.add_line(v_lines, v_fx_acct, case when v_fx > 0 then v_fx else 0 end,
    case when v_fx < 0 then -v_fx else 0 end, 'FX difference: ' || v_desc);
  v_lines := app_private.add_line(v_lines, fa.ledger_account_id, 0, v_cash_base, v_desc,
    app_private.orig_fields(r.currency, e.base_currency, r.amount, r.exchange_rate, v_cash_base));

  v_journal := app_private.post_system_journal(
    r.entity_id, 'refund', r.id, 'refund.confirm', 'refund.v1', r.refund_date, v_desc, v_lines);
  perform app_private.record_movement(r.entity_id, r.financial_account_id, 'out', r.amount, v_cash_base, r.exchange_rate,
    r.refund_date, 'refund', r.id, 'principal', v_journal, v_desc);

  update public.refunds
  set status = 'confirmed', refund_number = v_number, journal_id = v_journal, base_amount = v_cash_base,
      confirmed_at = now(), confirmed_by = auth.uid(),
      receipt_snapshot = app_private.document_parties(r.entity_id, r.customer_id, r.financial_account_id, null)
  where id = r.id;
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (r.entity_id, 'RefundConfirmed', 'refund', r.id,
          jsonb_build_object('refund_number', v_number, 'amount', r.amount, 'currency', r.currency));
  return v_journal;
end
$$;

-- ------------------------------------------------------------ refund commands
create function public.create_refund(
  p_payment uuid, p_key text, p_account uuid, p_date date, p_items jsonb, p_rate numeric default null,
  p_reason text default null, p_customer_reason text default null, p_reference text default null,
  p_confirm boolean default false)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p public.payments%rowtype;
  fa public.financial_accounts%rowtype;
  v_base public.currency_code;
  v_replay uuid;
  v_id uuid;
  v_elem jsonb;
  v_n integer := 0;
  v_total numeric := 0;
  v_amt numeric;
  v_alloc uuid;
  v_seen uuid[] := '{}';
  v_advance_seen boolean := false;
  v_scale integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into p from public.payments where id = p_payment;
  if not found or not app_authz.has_permission(p.entity_id, 'refunds.create') then
    raise exception 'FORBIDDEN: missing refunds.create' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_confirm, false) and not app_authz.has_permission(p.entity_id, 'refunds.confirm') then
    raise exception 'FORBIDDEN: confirming a refund needs refunds.confirm' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('refund.create', p.entity_id, p_key,
    md5(jsonb_build_object('payment', p_payment, 'account', p_account, 'date', p_date, 'items', p_items, 'rate', p_rate,
                           'reason', p_reason, 'creason', p_customer_reason, 'ref', p_reference,
                           'confirm', coalesce(p_confirm, false))::text));
  if v_replay is not null then
    return v_replay;
  end if;

  -- The payment is locked for the whole command: refunds, credit applications and reversals of one payment
  -- serialise, so the refundable amount cannot be raced.
  select * into p from public.payments where id = p_payment for update;
  if p.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed payment can be refunded (now %)', p.status using errcode = 'integrity_constraint_violation';
  end if;
  select e.base_currency into v_base from public.entities e where e.id = p.entity_id;
  select * into fa from public.financial_accounts where id = p_account and entity_id = p.entity_id;
  if not found or not fa.is_active or fa.currency <> p.currency then
    raise exception 'INVALID: the paying-out account must be an active account in % of this Entity', p.currency
      using errcode = 'invalid_parameter_value';
  end if;
  if (p.currency = v_base) <> (p_rate is null) then
    raise exception 'INVALID: an exchange rate is required for a foreign-currency refund, and only then'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_rate is not null and (not app_private.is_finite(p_rate) or p_rate <= 0 or p_rate >= 10::numeric ^ 10
                             or app_private.round_amount(p_rate, 10, 'down') <> p_rate) then
    raise exception 'INVALID: the exchange rate must be positive with at most 10 decimals' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date is null or p_date > app_private.entity_today(p.entity_id) or p_date < p.payment_date then
    raise exception 'INVALID: the refund date must be between the payment date and today' using errcode = 'invalid_parameter_value';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then
    raise exception 'INVALID: a refund needs a reason' using errcode = 'invalid_parameter_value';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 100 then
    raise exception 'INVALID: a refund needs between 1 and 100 items' using errcode = 'invalid_parameter_value';
  end if;
  v_scale := app_private.currency_scale(p.currency);

  -- First pass: shape and total. The per-source availability is checked by refund_compute below.
  for v_elem in select value from jsonb_array_elements(p_items) loop
    v_n := v_n + 1;
    if jsonb_typeof(v_elem) <> 'object' then
      raise exception 'INVALID: item % is not an object', v_n using errcode = 'invalid_parameter_value';
    end if;
    v_amt := app_private.parse_amount(v_elem ->> 'amount', format('item %s amount', v_n));
    if v_amt <= 0 or app_private.round_amount(v_amt, v_scale, 'down') <> v_amt then
      raise exception 'INVALID: item % must be positive and allows % decimals for %', v_n, v_scale, p.currency
        using errcode = 'invalid_parameter_value';
    end if;
    if coalesce(v_elem ->> 'source', '') = 'advance' then
      if v_advance_seen then
        raise exception 'INVALID: the customer advance can appear only once' using errcode = 'invalid_parameter_value';
      end if;
      v_advance_seen := true;
    else
      begin
        v_alloc := (v_elem ->> 'allocation_id')::uuid;
      exception when invalid_text_representation then
        raise exception 'INVALID: item % has an invalid allocation', v_n using errcode = 'invalid_parameter_value';
      end;
      if v_alloc is null or v_alloc = any (v_seen) then
        raise exception 'INVALID: item % needs its own allocation or source "advance"', v_n using errcode = 'invalid_parameter_value';
      end if;
      v_seen := v_seen || v_alloc;
    end if;
    v_total := v_total + v_amt;
  end loop;

  insert into public.refunds
    (entity_id, payment_id, customer_id, financial_account_id, currency, amount, exchange_rate, refund_date, reason,
     customer_reason, reference)
  values
    (p.entity_id, p.id, p.customer_id, p_account, p.currency, v_total, p_rate, p_date, btrim(p_reason),
     nullif(btrim(coalesce(p_customer_reason, '')), ''), nullif(btrim(coalesce(p_reference, '')), ''))
  returning id into v_id;
  insert into public.refund_items (entity_id, refund_id, allocation_id, amount)
  select p.entity_id, v_id,
         case when coalesce(x ->> 'source', '') = 'advance' then null else (x ->> 'allocation_id')::uuid end,
         (x ->> 'amount')::numeric
  from jsonb_array_elements(p_items) x;
  -- Preliminary check against what is refundable now (a draft may still be refused later).
  perform app_private.refund_compute(v_id, false);

  if coalesce(p_confirm, false) then
    perform app_private.assert_maker_checker(p.entity_id, 'refunds', 'confirm',
      app_private.round_amount(v_total * coalesce(p_rate, 1), 4, 'half_up'), auth.uid(), 'confirm this refund');
    perform app_private.confirm_refund_core(v_id);
  end if;
  perform app_private.idem_complete('refund.create', p.entity_id, p_key, 'refunds', v_id);
  return v_id;
end
$$;

create function public.confirm_refund(p_refund uuid, p_key text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.refunds%rowtype;
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into r from public.refunds where id = p_refund;
  if not found or not app_authz.has_permission(r.entity_id, 'refunds.confirm') then
    raise exception 'FORBIDDEN: missing refunds.confirm' using errcode = 'insufficient_privilege';
  end if;
  perform 1 from public.payments where id = r.payment_id for update;
  select * into r from public.refunds where id = p_refund for update;
  v_replay := app_private.idem_begin('refund.confirm', r.entity_id, p_key, md5(p_refund::text));
  if v_replay is not null then
    return v_replay;
  end if;
  perform app_private.assert_maker_checker(r.entity_id, 'refunds', 'confirm',
    app_private.round_amount(r.amount * coalesce(r.exchange_rate, 1), 4, 'half_up'), r.created_by, 'confirm this refund');
  perform app_private.confirm_refund_core(p_refund);
  perform app_private.idem_complete('refund.confirm', r.entity_id, p_key, 'refunds', p_refund);
  return p_refund;
end
$$;

create function public.reject_refund(p_refund uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.refunds%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into r from public.refunds where id = p_refund;
  if not found or not app_authz.has_permission(r.entity_id, 'refunds.confirm') then
    raise exception 'FORBIDDEN: missing refunds.confirm' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 3 then
    raise exception 'INVALID: a rejection needs a reason' using errcode = 'invalid_parameter_value';
  end if;
  select * into r from public.refunds where id = p_refund for update;
  if r.status <> 'draft' then
    raise exception 'CONFLICT: only a draft refund can be rejected (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  update public.refunds set status = 'rejected', closed_at = now(), closed_by = auth.uid(), closed_reason = v_reason
  where id = p_refund;
  return 'rejected';
end
$$;

create function public.cancel_refund(p_refund uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.refunds%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into r from public.refunds where id = p_refund;
  if not found or not app_authz.has_permission(r.entity_id, 'refunds.create') then
    raise exception 'FORBIDDEN: missing refunds.create' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 3 then
    raise exception 'INVALID: a cancellation needs a reason' using errcode = 'invalid_parameter_value';
  end if;
  select * into r from public.refunds where id = p_refund for update;
  if r.status <> 'draft' then
    raise exception 'CONFLICT: only a draft refund can be cancelled (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  update public.refunds set status = 'cancelled', closed_at = now(), closed_by = auth.uid(), closed_reason = v_reason
  where id = p_refund;
  return 'cancelled';
end
$$;

create function public.reverse_refund(p_refund uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.refunds%rowtype;
  m public.money_movements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into r from public.refunds where id = p_refund;
  if not found or not app_authz.has_permission(r.entity_id, 'refunds.confirm') then
    raise exception 'FORBIDDEN: missing refunds.confirm' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 or p_date > app_private.entity_today(r.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of at least 5 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform 1 from public.payments where id = r.payment_id for update;
  select * into r from public.refunds where id = p_refund for update;
  v_replay := app_private.idem_begin('refund.reverse', r.entity_id, p_key,
    md5(jsonb_build_object('refund', p_refund, 'date', p_date, 'reason', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if r.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed refund can be reversed (now %)', r.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < r.refund_date then
    raise exception 'INVALID: a reversal cannot be dated before the refund' using errcode = 'invalid_parameter_value';
  end if;
  perform 1 from public.financial_accounts where id = r.financial_account_id and entity_id = r.entity_id for no key update;

  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(r.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = r.entity_id and source_type = 'refund' and source_id = r.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(
      r.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'refund', r.id, m.component, v_rev,
      'Reversal: ' || v_reason, m.id);
  end loop;
  update public.refunds
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date,
      reversed_by = auth.uid(), reverse_reason = v_reason
  where id = r.id;
  perform app_private.idem_complete('refund.reverse', r.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

-- What can still be refunded from one payment, by source.
create function public.payment_refund_options(p_payment uuid)
returns table (source text, allocation_id uuid, invoice_number text, refundable text, currency text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  p public.payments%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into p from public.payments where id = p_payment;
  if not found or not app_authz.has_permission(p.entity_id, 'refunds.view') then
    raise exception 'FORBIDDEN: missing refunds.view' using errcode = 'insufficient_privilege';
  end if;
  if p.status <> 'confirmed' then
    return;
  end if;
  return query
    select 'allocation'::text, a.id, i.invoice_number, s.rem_amount::text, p.currency::text
    from public.payment_allocations a
    join public.invoices i on i.id = a.invoice_id and i.entity_id = a.entity_id
    cross join lateral app_private.allocation_refund_state(a.id) s
    where a.payment_id = p.id and a.status = 'active' and s.rem_amount > 0
    order by a.created_at, a.id;
  return query
    select 'advance'::text, null::uuid, null::text, s.rem_amount::text, p.currency::text
    from app_private.payment_advance_state(p.id) s where s.rem_amount > 0;
end
$$;

-- Payments with their derived refund position.
create function public.list_payments(
  p_entity uuid, p_customer uuid default null, p_invoice uuid default null, p_limit integer default 100)
returns table (
  payment_id uuid, payment_number text, status text, payment_date date, customer_id uuid, customer_name text,
  currency text, amount text, allocated_amount text, advance_remaining text, refunded text, refundable text,
  refund_status text, reference text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.view') then
    raise exception 'FORBIDDEN: missing invoices.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select p.id, p.payment_number, p.status, p.payment_date, p.customer_id, c.display_name, p.currency::text,
         p.amount::text, p.allocated_amount::text,
         (select s.rem_amount from app_private.payment_advance_state(p.id) s)::text,
         x.refunded::text, (case when p.status = 'confirmed' then p.amount - x.refunded else 0 end)::text,
         case when x.refunded = 0 then 'none' when x.refunded >= p.amount then 'full' else 'partial' end,
         p.reference
  from public.payments p
  join public.contacts c on c.id = p.customer_id and c.entity_id = p.entity_id
  cross join lateral (
    select coalesce(sum(r.amount), 0) as refunded from public.refunds r
    where r.payment_id = p.id and r.status = 'confirmed') x
  where p.entity_id = p_entity and (p_customer is null or p.customer_id = p_customer)
    and (p_invoice is null or exists (select 1 from public.payment_allocations a where a.payment_id = p.id and a.invoice_id = p_invoice))
  order by p.payment_date desc, p.payment_number desc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
end
$$;

-- ------------------------------------------------------------ AR aging (Step 12; base currency)
create function public.ar_aging(p_entity uuid, p_as_of date default null, p_customer uuid default null)
returns table (
  customer_id uuid, customer_name text, not_due text, days_1_30 text, days_31_60 text, days_61_90 text,
  days_over_90 text, total text, invoice_count bigint)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.view') then
    raise exception 'FORBIDDEN: missing invoices.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select p.customer_id, c.display_name,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue = 0), 0)::text,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue between 1 and 30), 0)::text,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue between 31 and 60), 0)::text,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue between 61 and 90), 0)::text,
         coalesce(sum(p.base_outstanding) filter (where p.days_overdue > 90), 0)::text,
         sum(p.base_outstanding)::text, count(*)
  from app_private.invoice_positions(p_entity, p_as_of) p
  join public.contacts c on c.id = p.customer_id and c.entity_id = p_entity
  where p.status = 'issued' and p.outstanding > 0 and (p_customer is null or p.customer_id = p_customer)
  group by p.customer_id, c.display_name
  order by sum(p.base_outstanding) desc, c.display_name;
end
$$;

-- ------------------------------------------------------------ public links (authenticated management)
create function public.regenerate_invoice_link(p_invoice uuid, p_key text, p_expires_at timestamptz default null)
returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_replay uuid;
  v_id uuid;
  v_token text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.regenerate_link') then
    raise exception 'FORBIDDEN: missing invoices.regenerate_link' using errcode = 'insufficient_privilege';
  end if;
  select * into i from public.invoices where id = p_invoice for update;
  v_replay := app_private.idem_begin('invoice.link', i.entity_id, p_key,
    md5(jsonb_build_object('i', p_invoice, 'e', p_expires_at)::text));
  if v_replay is not null then
    select l.token into v_token from public.invoice_public_links l where l.id = v_replay;
    return v_token;
  end if;
  if i.status <> 'issued' then
    raise exception 'CONFLICT: only an issued invoice has a public link (now %)', i.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_expires_at is not null and (p_expires_at <= now() or p_expires_at > now() + interval '5 years') then
    raise exception 'INVALID: the expiry must be in the future and within 5 years' using errcode = 'invalid_parameter_value';
  end if;
  update public.invoice_public_links
  set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), revoked_reason = 'regenerated'
  where invoice_id = i.id and status = 'active';
  insert into public.invoice_public_links (entity_id, invoice_id, token, expires_at)
  values (i.entity_id, i.id, app_private.new_public_token(), p_expires_at)
  returning id, token into v_id, v_token;
  perform app_private.idem_complete('invoice.link', i.entity_id, p_key, 'invoice_public_links', v_id);
  return v_token;
end
$$;

create function public.revoke_invoice_link(p_invoice uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_n integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.regenerate_link') then
    raise exception 'FORBIDDEN: missing invoices.regenerate_link' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 3 then
    raise exception 'INVALID: revoking a link needs a reason' using errcode = 'invalid_parameter_value';
  end if;
  update public.invoice_public_links
  set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), revoked_reason = v_reason
  where invoice_id = i.id and entity_id = i.entity_id and status = 'active';
  get diagnostics v_n = row_count;
  return case when v_n > 0 then 'revoked' else 'no_active_link' end;
end
$$;

create function public.set_invoice_link_expiry(p_invoice uuid, p_expires_at timestamptz) returns timestamptz
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_n integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.regenerate_link') then
    raise exception 'FORBIDDEN: missing invoices.regenerate_link' using errcode = 'insufficient_privilege';
  end if;
  if p_expires_at is not null and (p_expires_at <= now() or p_expires_at > now() + interval '5 years') then
    raise exception 'INVALID: the expiry must be in the future and within 5 years' using errcode = 'invalid_parameter_value';
  end if;
  update public.invoice_public_links set expires_at = p_expires_at
  where invoice_id = i.id and entity_id = i.entity_id and status = 'active';
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'CONFLICT: this invoice has no active public link' using errcode = 'integrity_constraint_violation';
  end if;
  return p_expires_at;
end
$$;

-- ------------------------------------------------------------ documents (customer-facing facts only)
-- The frozen document of an invoice: snapshots for an issued invoice, live master data for a draft preview.
-- Internal notes, ledger ids and tax identifiers never appear.
create function app_private.invoice_document_json(p_invoice uuid, p_public boolean) returns jsonb
language plpgsql stable as $$
declare
  i public.invoices%rowtype;
  v_parties jsonb;
  v_settled numeric;
  v_base_settled numeric;
  v_refunded numeric;
  v_lines jsonb;
  v_payments jsonb;
  v_today date;
begin
  select * into i from public.invoices where id = p_invoice;
  v_today := app_private.entity_today(i.entity_id);
  v_parties := app_private.document_parties(i.entity_id, i.customer_id, i.payment_account_id, i.payment_channel_id);
  select s.settled, s.base_settled into v_settled, v_base_settled from app_private.invoice_settled(i.id) s;
  select coalesce(sum(ri.amount), 0) into v_refunded
  from public.refund_items ri
  join public.refunds r on r.id = ri.refund_id and r.status = 'confirmed'
  join public.payment_allocations a on a.id = ri.allocation_id
  where a.invoice_id = i.id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'line_no', l.line_no, 'description', l.description, 'quantity', l.quantity::text, 'unit_price', l.unit_price::text,
      'discount_type', l.discount_type, 'discount_value', l.discount_value::text, 'discount_amount', l.discount_amount::text,
      'tax_amount', l.tax_amount::text, 'line_total', l.line_total::text) order by l.line_no), '[]'::jsonb)
    into v_lines from public.invoice_lines l where l.invoice_id = i.id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'receipt_number', p.payment_number, 'payment_date', p.payment_date, 'amount', a.amount::text,
      'currency', p.currency) order by p.payment_date, p.payment_number), '[]'::jsonb)
    into v_payments
  from public.payment_allocations a join public.payments p on p.id = a.payment_id
  where a.invoice_id = i.id and a.status = 'active';

  return jsonb_build_object(
    'document', 'invoice',
    'invoice_number', i.invoice_number,
    'status', i.status,
    'issue_date', i.issue_date,
    'due_date', i.due_date,
    'currency', i.currency,
    'subtotal', i.subtotal::text, 'discount_total', i.discount_total::text, 'tax_total', i.tax_total::text,
    'total', i.total::text,
    'settled', v_settled::text,
    'outstanding', case when i.status = 'issued' then (i.total - v_settled)::text else '0' end,
    'settlement_status', case when i.status <> 'issued' then null
                              when i.total - v_settled = 0 then 'paid'
                              when v_settled = 0 then 'unpaid' else 'partial' end,
    'is_overdue', (i.status = 'issued' and i.total - v_settled > 0 and i.due_date < v_today),
    'refunded', v_refunded::text,
    'notes', i.notes, 'terms', i.terms, 'payment_note', i.payment_note,
    'issuer', coalesce(i.issuer_snapshot, v_parties -> 'issuer'),
    'customer', coalesce(i.customer_snapshot, v_parties -> 'customer'),
    -- Only intentionally configured receiving details are shown (Step 11 §7).
    'payment_instructions', i.payment_snapshot,
    'lines', v_lines,
    'payments', v_payments,
    'is_draft', i.status = 'draft');
end
$$;

create function public.invoice_document(p_invoice uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select entity_id into v_entity from public.invoices where id = p_invoice;
  if v_entity is null or not app_authz.has_permission(v_entity, 'invoices.view') then
    raise exception 'FORBIDDEN: missing invoices.view' using errcode = 'insufficient_privilege';
  end if;
  return app_private.invoice_document_json(p_invoice, false);
end
$$;

-- Receipt of a confirmed payment, from its frozen snapshot. A reversed payment is marked as such, never deleted.
create function app_private.payment_receipt_json(p_payment uuid, p_public boolean, p_invoice uuid default null) returns jsonb
language plpgsql stable as $$
declare
  p public.payments%rowtype;
  v_alloc jsonb;
  v_refunded numeric;
begin
  select * into p from public.payments where id = p_payment;
  select coalesce(jsonb_agg(jsonb_build_object(
      'invoice_number', i.invoice_number, 'amount', a.amount::text, 'kind', a.kind, 'status', a.status)
      order by a.created_at, a.id), '[]'::jsonb)
    into v_alloc
  from public.payment_allocations a join public.invoices i on i.id = a.invoice_id and i.entity_id = a.entity_id
  where a.payment_id = p.id and (p_invoice is null or a.invoice_id = p_invoice);
  select coalesce(sum(r.amount), 0) into v_refunded from public.refunds r where r.payment_id = p.id and r.status = 'confirmed';
  return jsonb_build_object(
    'document', 'payment_receipt',
    'receipt_number', p.payment_number,
    'status', p.status,
    'payment_date', p.payment_date,
    'amount', p.amount::text,
    'currency', p.currency,
    'reference', p.reference,
    'payer_name', p.payer_name,
    'issuer', p.receipt_snapshot -> 'issuer',
    'customer', p.receipt_snapshot -> 'customer',
    'method', jsonb_build_object('channel', p.receipt_snapshot #>> '{channel}',
                                 'institution', p.receipt_snapshot #>> '{account,institution_name}',
                                 'account_masked', p.receipt_snapshot #>> '{account,account_masked}'),
    'allocations', case when p_public then (select coalesce(jsonb_agg(x - 'status'), '[]'::jsonb) from jsonb_array_elements(v_alloc) x where x ->> 'status' = 'active')
                        else v_alloc end,
    'advance_amount', p.advance_amount::text,
    'refunded', v_refunded::text,
    'refundable', case when p.status = 'confirmed' then (p.amount - v_refunded)::text else '0' end);
end
$$;

create function public.payment_receipt_document(p_payment uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select entity_id into v_entity from public.payments where id = p_payment;
  if v_entity is null or not app_authz.has_permission(v_entity, 'invoices.view') then
    raise exception 'FORBIDDEN: missing invoices.view' using errcode = 'insufficient_privilege';
  end if;
  return app_private.payment_receipt_json(p_payment, false);
end
$$;

create function public.refund_receipt_document(p_refund uuid) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  r public.refunds%rowtype;
  p public.payments%rowtype;
  v_items jsonb;
  v_total numeric;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into r from public.refunds where id = p_refund;
  if not found or not app_authz.has_permission(r.entity_id, 'refunds.view') then
    raise exception 'FORBIDDEN: missing refunds.view' using errcode = 'insufficient_privilege';
  end if;
  if r.status not in ('confirmed', 'reversed') then
    raise exception 'CONFLICT: a refund receipt exists only for a confirmed refund (now %)', r.status
      using errcode = 'integrity_constraint_violation';
  end if;
  select * into p from public.payments where id = r.payment_id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'invoice_number', i.invoice_number, 'amount', ri.amount::text) order by ri.created_at, ri.id), '[]'::jsonb)
    into v_items
  from public.refund_items ri
  left join public.payment_allocations a on a.id = ri.allocation_id
  left join public.invoices i on i.id = a.invoice_id and i.entity_id = a.entity_id
  where ri.refund_id = r.id;
  select coalesce(sum(x.amount), 0) into v_total from public.refunds x where x.payment_id = p.id and x.status = 'confirmed';
  return jsonb_build_object(
    'document', 'refund_receipt',
    'refund_number', r.refund_number,
    'status', r.status,
    'refund_date', r.refund_date,
    'amount', r.amount::text,
    'currency', r.currency,
    'original_payment_number', p.payment_number,
    'original_payment_date', p.payment_date,
    'items', v_items,
    'customer_reason', r.customer_reason,
    'cumulative_refunded', v_total::text,
    'remaining_refundable', case when p.status = 'confirmed' then (p.amount - v_total)::text else '0' end,
    'issuer', r.receipt_snapshot -> 'issuer',
    'customer', r.receipt_snapshot -> 'customer',
    'method', jsonb_build_object('institution', r.receipt_snapshot #>> '{account,institution_name}',
                                 'account_masked', r.receipt_snapshot #>> '{account,account_masked}'));
end
$$;

-- ------------------------------------------------------------ the public token surface (anonymous role)
-- Resolves a token to its invoice. Unknown, revoked, expired and malformed tokens are indistinguishable.
create function app_private.public_link_lookup(p_token text) returns public.invoice_public_links
language plpgsql stable as $$
declare
  l public.invoice_public_links%rowtype;
begin
  if p_token is null or length(p_token) not between 40 and 120 or p_token !~ '^[A-Za-z0-9_-]+$' then
    return null;
  end if;
  select * into l from public.invoice_public_links k
  where k.token = p_token and k.status = 'active' and (k.expires_at is null or k.expires_at > now())
    and exists (select 1 from public.invoices i where i.id = k.invoice_id and i.entity_id = k.entity_id and i.status = 'issued');
  if not found then
    return null;
  end if;
  return l;
end
$$;

-- Read-only representation of the invoice for the customer: no ids, no internal notes, no ledger facts.
create function public.public_invoice_view(p_token text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  l public.invoice_public_links%rowtype;
  v_doc jsonb;
  v_pending boolean;
begin
  l := app_private.public_link_lookup(p_token);
  if l.id is null then
    return jsonb_build_object('state', 'unavailable');
  end if;
  v_doc := app_private.invoice_document_json(l.invoice_id, true);
  select exists (select 1 from public.payment_submissions s where s.invoice_id = l.invoice_id and s.status = 'pending')
    into v_pending;
  return jsonb_build_object(
    'state', 'ok',
    'invoice', v_doc - 'document' - 'is_draft',
    'pending_claim', v_pending,
    'can_claim', (v_doc ->> 'outstanding')::numeric > 0);
end
$$;

-- "Saya Sudah Bayar": stores a PENDING claim only. It has no cash or accounting effect until a person with
-- authority confirms it (Step 07 §4). `p_client` is a salted hash of the requester made by the server route.
create function public.public_submit_payment_claim(
  p_token text, p_amount numeric, p_date date, p_payer_name text, p_reference text, p_note text, p_client text)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.invoice_public_links%rowtype;
  v_n bigint;
  v_id uuid;
  v_existing boolean;
begin
  l := app_private.public_link_lookup(p_token);
  if l.id is null then
    raise exception 'UNAVAILABLE: this link is not valid' using errcode = 'insufficient_privilege';
  end if;
  if p_client is null or length(p_client) not between 16 and 128 then
    raise exception 'INVALID: the request could not be verified' using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('app.actor_type', 'public_token', true);
  perform set_config('app.actor_id', l.id::text, true);

  -- Abuse limits: per requester per hour, per invoice per day, and pending claims per invoice. The counts are
  -- serialised per invoice so that concurrent claims cannot all slip under a limit.
  perform pg_advisory_xact_lock(hashtextextended('public_claim:' || l.invoice_id::text, 0));
  select count(*) into v_n from public.payment_submissions s
  where s.client_hash = p_client and s.created_at > now() - interval '1 hour';
  if v_n >= 8 then
    raise exception 'THROTTLED: too many requests, try again later' using errcode = 'insufficient_privilege';
  end if;
  select count(*) into v_n from public.payment_submissions s
  where s.invoice_id = l.invoice_id and s.source = 'public' and s.created_at > now() - interval '1 day';
  if v_n >= 20 then
    raise exception 'THROTTLED: too many requests for this invoice today' using errcode = 'insufficient_privilege';
  end if;
  select count(*) into v_n from public.payment_submissions s where s.invoice_id = l.invoice_id and s.status = 'pending';
  if v_n >= 5 then
    raise exception 'THROTTLED: this invoice already has several claims awaiting verification' using errcode = 'insufficient_privilege';
  end if;

  select x.submission_id, x.was_existing into v_id, v_existing
  from app_private.insert_submission(
    l.invoice_id, 'public', p_amount, p_date,
    regexp_replace(coalesce(p_payer_name, ''), '[\x01-\x1f\x7f]', '', 'g'),
    regexp_replace(coalesce(p_reference, ''), '[\x01-\x1f\x7f]', '', 'g'),
    null,
    regexp_replace(coalesce(p_note, ''), '[\x01-\x1f\x7f]', '', 'g'),
    p_client, null) x;
  return jsonb_build_object('state', 'pending', 'already_received', v_existing);
end
$$;

-- A receipt for a payment allocated to the token's invoice: only what a payer may see.
create function public.public_receipt_view(p_token text, p_receipt_number text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  l public.invoice_public_links%rowtype;
  v_payment uuid;
begin
  l := app_private.public_link_lookup(p_token);
  if l.id is null then
    return jsonb_build_object('state', 'unavailable');
  end if;
  select p.id into v_payment
  from public.payments p
  join public.payment_allocations a on a.payment_id = p.id and a.invoice_id = l.invoice_id and a.status = 'active'
  where p.entity_id = l.entity_id and p.payment_number = p_receipt_number and p.status = 'confirmed'
  limit 1;
  if v_payment is null then
    return jsonb_build_object('state', 'unavailable');
  end if;
  return jsonb_build_object('state', 'ok', 'receipt',
    (app_private.payment_receipt_json(v_payment, true, l.invoice_id) - 'refundable' - 'advance_amount' - 'payer_name'));
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.refunds');
create policy refunds_select on public.refunds for select to authenticated
  using (app_authz.has_permission(entity_id, 'refunds.view'));
call app_private.expose_select('public.refund_items');
create policy refund_items_select on public.refund_items for select to authenticated
  using (app_authz.has_permission(entity_id, 'refunds.view'));

revoke all on function app_private.tg_refunds_guard() from public;
revoke all on function app_private.tg_refund_items_guard() from public;
revoke all on function app_private.refund_compute(uuid, boolean) from public;
revoke all on function app_private.confirm_refund_core(uuid) from public;
revoke all on function app_private.invoice_document_json(uuid, boolean) from public;
revoke all on function app_private.payment_receipt_json(uuid, boolean, uuid) from public;
revoke all on function app_private.public_link_lookup(text) from public;

revoke all on function public.create_refund(uuid, text, uuid, date, jsonb, numeric, text, text, text, boolean) from public, anon;
revoke all on function public.confirm_refund(uuid, text) from public, anon;
revoke all on function public.reject_refund(uuid, text) from public, anon;
revoke all on function public.cancel_refund(uuid, text) from public, anon;
revoke all on function public.reverse_refund(uuid, text, date, text) from public, anon;
revoke all on function public.payment_refund_options(uuid) from public, anon;
revoke all on function public.list_payments(uuid, uuid, uuid, integer) from public, anon;
revoke all on function public.ar_aging(uuid, date, uuid) from public, anon;
revoke all on function public.regenerate_invoice_link(uuid, text, timestamptz) from public, anon;
revoke all on function public.revoke_invoice_link(uuid, text) from public, anon;
revoke all on function public.set_invoice_link_expiry(uuid, timestamptz) from public, anon;
revoke all on function public.invoice_document(uuid) from public, anon;
revoke all on function public.payment_receipt_document(uuid) from public, anon;
revoke all on function public.refund_receipt_document(uuid) from public, anon;
grant execute on function public.create_refund(uuid, text, uuid, date, jsonb, numeric, text, text, text, boolean) to authenticated;
grant execute on function public.confirm_refund(uuid, text) to authenticated;
grant execute on function public.reject_refund(uuid, text) to authenticated;
grant execute on function public.cancel_refund(uuid, text) to authenticated;
grant execute on function public.reverse_refund(uuid, text, date, text) to authenticated;
grant execute on function public.payment_refund_options(uuid) to authenticated;
grant execute on function public.list_payments(uuid, uuid, uuid, integer) to authenticated;
grant execute on function public.ar_aging(uuid, date, uuid) to authenticated;
grant execute on function public.regenerate_invoice_link(uuid, text, timestamptz) to authenticated;
grant execute on function public.revoke_invoice_link(uuid, text) to authenticated;
grant execute on function public.set_invoice_link_expiry(uuid, timestamptz) to authenticated;
grant execute on function public.invoice_document(uuid) to authenticated;
grant execute on function public.payment_receipt_document(uuid) to authenticated;
grant execute on function public.refund_receipt_document(uuid) to authenticated;

-- The ONLY functions the anonymous role may run. Each is scoped by an unguessable token and reveals nothing else.
revoke all on function public.public_invoice_view(text) from public;
revoke all on function public.public_submit_payment_claim(text, numeric, date, text, text, text, text) from public;
revoke all on function public.public_receipt_view(text, text) from public;
grant execute on function public.public_invoice_view(text) to anon, authenticated;
grant execute on function public.public_submit_payment_claim(text, numeric, date, text, text, text, text) to anon, authenticated;
grant execute on function public.public_receipt_view(text, text) to anon, authenticated;
