-- P7 part 4 (Step 05 §12, Step 15 §11, Step 16 §15): the tax lifecycle after determination - payment, filing evidence,
-- reconciliation and the control against the General Ledger.
--
--   * tax_payments            settle the tax liability that documents recognised (Dr Tax Payable). For VAT the payment
--                             can offset creditable input VAT (Cr Tax Asset) so only the net leaves the bank. A late
--                             payment penalty is a separate expense. Payment never creates an expense for a liability
--                             that was already recognised.
--   * tax_filings             the return as filed (period, reference, reported amounts), append-only with amendments.
--   * tax_reconciliations     a stored comparison of ledger, payments and filing for a period; differences stay visible.
--   * tax control             the tax sub-ledger against Tax Payable / Tax Asset in the General Ledger.
--   * evidence documents      payment proofs and filing receipts are linked to the payment or the filing; the source
--                             transactions are never rewritten by any of this.

-- ------------------------------------------------------------ numbering of tax payments
alter table public.numbering_sequences drop constraint numbering_sequences_scope_check;
alter table public.numbering_sequences add constraint numbering_sequences_scope_check
  check (scope in ('invoice', 'payment_receipt', 'refund_receipt', 'bill', 'bill_payment', 'expense', 'journal',
                   'transfer', 'tax_payment', 'other'));

create function app_private.ensure_tax_numbering(p_entity uuid) returns void
language plpgsql as $$
begin
  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (p_entity, 'tax_payment', 'TAXPAY')
  on conflict (entity_id, scope) do nothing;
end
$$;

-- ------------------------------------------------------------ tax payments
create table public.tax_payments (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  payment_number text not null,
  status text not null default 'confirmed' check (status in ('confirmed', 'reversed')),
  tax_type text not null check (tax_type in ('vat', 'wht_pph23', 'final_umkm')),
  tax_period date not null check (tax_period = date_trunc('month', tax_period)::date),
  payment_date date not null,
  currency public.currency_code not null,
  -- The liability settled (Dr Tax Payable), the creditable input VAT used against it (Cr Tax Asset, VAT only), and a
  -- late-payment penalty booked as its own expense.
  payable_applied public.money_amount not null check (payable_applied > 0),
  asset_applied public.money_amount not null default 0 check (asset_applied >= 0),
  penalty_amount public.money_amount not null default 0 check (penalty_amount >= 0),
  -- What actually left the account: payable - offset + penalty.
  cash_amount public.money_amount not null check (cash_amount >= 0),
  financial_account_id uuid,
  -- A billing code / NTPN / bank reference; a free note for the reviewer.
  reference text check (reference is null or length(reference) <= 200),
  note text check (note is null or length(note) <= 1000),
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
  foreign key (entity_id, financial_account_id, currency)
    references public.financial_accounts (entity_id, id, currency) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint tax_payment_offset_shape check (
    (tax_type = 'vat' or asset_applied = 0) and asset_applied <= payable_applied),
  constraint tax_payment_cash_shape check (
    cash_amount = payable_applied - asset_applied + penalty_amount
    and ((cash_amount > 0) = (financial_account_id is not null))),
  constraint tax_payment_state_consistent check (
    (status = 'confirmed' and reversal_journal_id is null and reversed_at is null)
    or (status = 'reversed' and reversal_journal_id is not null and reversed_at is not null
        and reversed_date is not null and reverse_reason is not null))
);
create unique index tax_payments_number_uq on public.tax_payments (entity_id, payment_number);
create index tax_payments_period_idx on public.tax_payments (entity_id, tax_type, tax_period, status);
create index tax_payments_date_idx on public.tax_payments (entity_id, payment_date);

create function app_private.tg_tax_payments_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'reversal_journal_id', 'reversed_at', 'reversed_date', 'reversed_by',
                                   'reverse_reason', 'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'reversed' then
    raise exception 'A reversed tax payment cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'The facts of a confirmed tax payment cannot be changed; reverse it instead'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.tax_payments
  for each row execute function app_private.tg_tax_payments_guard();
create trigger tg_forbid_delete before delete on public.tax_payments
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_payments
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_payments');
call app_private.secure_table('public.tax_payments');
create trigger tg_audit after insert or update or delete on public.tax_payments
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ the position of one tax type and period
-- Ledger accruals and confirmed payments as of a date. A reversal entry belongs to the period of its own date, so a
-- period that was paid and then partly reversed shows a negative outstanding (a credit), never a hidden change.
create function app_private.tax_period_amounts(p_entity uuid, p_type text, p_period date, p_as_of date)
returns table (accrued_payable numeric, accrued_asset numeric, paid_payable numeric, applied_asset numeric,
               cash_paid numeric, penalty_paid numeric)
language sql stable as $$
  select
    coalesce((select sum(e.amount) from public.tax_ledger_entries e
              where e.entity_id = p_entity and e.tax_type = p_type and e.tax_period = p_period
                and e.direction = 'payable' and e.entry_date <= p_as_of), 0),
    coalesce((select sum(e.amount) from public.tax_ledger_entries e
              where e.entity_id = p_entity and e.tax_type = p_type and e.tax_period = p_period
                and e.direction = 'asset' and e.entry_date <= p_as_of), 0),
    coalesce(sum(p.payable_applied), 0),
    coalesce(sum(p.asset_applied), 0),
    coalesce(sum(p.cash_amount), 0),
    coalesce(sum(p.penalty_amount), 0)
  from public.tax_payments p
  where p.entity_id = p_entity and p.tax_type = p_type and p.tax_period = p_period
    and p.payment_date <= p_as_of and (p.status = 'confirmed' or p.reversed_date > p_as_of)
$$;

-- Input VAT that a new VAT payment for a period can still use: everything credited up to that period and not yet
-- offset, and never more than the Entity's total unused input VAT.
create function app_private.tax_asset_available(p_entity uuid, p_period date, p_as_of date) returns numeric
language sql stable as $$
  select greatest(0, least(
    coalesce((select sum(e.amount) from public.tax_ledger_entries e
              where e.entity_id = p_entity and e.tax_type = 'vat' and e.direction = 'asset'
                and e.tax_period <= p_period and e.entry_date <= p_as_of), 0)
    - coalesce((select sum(p.asset_applied) from public.tax_payments p
                where p.entity_id = p_entity and p.tax_type = 'vat' and p.tax_period <= p_period
                  and p.payment_date <= p_as_of and (p.status = 'confirmed' or p.reversed_date > p_as_of)), 0),
    coalesce((select sum(e.amount) from public.tax_ledger_entries e
              where e.entity_id = p_entity and e.tax_type = 'vat' and e.direction = 'asset' and e.entry_date <= p_as_of), 0)
    - coalesce((select sum(p.asset_applied) from public.tax_payments p
                where p.entity_id = p_entity and p.tax_type = 'vat'
                  and p.payment_date <= p_as_of and (p.status = 'confirmed' or p.reversed_date > p_as_of)), 0)))
$$;

-- Defence in depth for the capacity rule: whatever writes a payment, the settled amount of a period never exceeds
-- what the ledger accrued for it, and the input VAT used never exceeds what was credited.
create function app_private.tg_tax_payments_capacity() returns trigger
language plpgsql as $$
declare
  v_applied numeric;
begin
  if new.status <> 'confirmed' then
    return new;
  end if;
  select coalesce(sum(p.payable_applied), 0) into v_applied from public.tax_payments p
  where p.entity_id = new.entity_id and p.tax_type = new.tax_type and p.tax_period = new.tax_period
    and p.status = 'confirmed';
  if v_applied > (select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e
                  where e.entity_id = new.entity_id and e.tax_type = new.tax_type and e.tax_period = new.tax_period
                    and e.direction = 'payable') then
    raise exception 'INVALID: the payments of % for % would exceed the tax recognised for that period', new.tax_type,
      to_char(new.tax_period, 'YYYY-MM') using errcode = 'invalid_parameter_value';
  end if;
  if new.asset_applied > 0 and (
       select coalesce(sum(p.asset_applied), 0) from public.tax_payments p
       where p.entity_id = new.entity_id and p.tax_type = 'vat' and p.status = 'confirmed')
     > (select coalesce(sum(e.amount), 0) from public.tax_ledger_entries e
        where e.entity_id = new.entity_id and e.tax_type = 'vat' and e.direction = 'asset') then
    raise exception 'INVALID: the input VAT offset would exceed the input VAT credited' using errcode = 'invalid_parameter_value';
  end if;
  return new;
end
$$;
create constraint trigger tg_capacity after insert on public.tax_payments
  deferrable initially immediate for each row execute function app_private.tg_tax_payments_capacity();

-- ------------------------------------------------------------ recording a payment
create function public.tax_record_payment(
  p_entity uuid, p_key text, p_tax_type text, p_period date, p_date date, p_account uuid, p_payable text,
  p_asset_offset text default '0', p_penalty text default '0', p_reference text default null, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e public.entities%rowtype;
  fa public.financial_accounts%rowtype;
  v_replay uuid;
  v_today date;
  v_scale integer;
  v_payable numeric;
  v_asset numeric;
  v_penalty numeric;
  v_cash numeric;
  a record;
  v_outstanding numeric;
  v_avail numeric;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid := gen_random_uuid();
  v_number text;
  v_desc text;
  v_lines jsonb := '[]'::jsonb;
  v_journal uuid;
  v_label text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.mark_filed') then
    raise exception 'FORBIDDEN: recording a tax payment needs tax.mark_filed' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.payment', p_entity, p_key,
    md5(jsonb_build_object('t', p_tax_type, 'p', p_period, 'd', p_date, 'a', p_account, 'pay', p_payable,
                           'off', p_asset_offset, 'pen', p_penalty, 'r', p_reference, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into e from public.entities where id = p_entity;
  if not found or e.status <> 'active' then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_today := app_private.entity_today(p_entity);
  v_scale := app_private.currency_scale(e.base_currency);
  if p_tax_type is null or p_tax_type not in ('vat', 'wht_pph23', 'final_umkm') then
    raise exception 'INVALID: the tax type is vat, wht_pph23 or final_umkm' using errcode = 'invalid_parameter_value';
  end if;
  if p_period is null or p_period <> date_trunc('month', p_period)::date then
    raise exception 'INVALID: the tax period is the first day of a month' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  if p_date > v_today then
    raise exception 'INVALID: a payment cannot be dated in the future' using errcode = 'invalid_parameter_value';
  end if;
  if p_date < p_period then
    raise exception 'INVALID: a payment cannot be dated before its tax period starts' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(v_ref, '')) > 200 or length(coalesce(v_note, '')) > 1000 then
    raise exception 'INVALID: the reference is limited to 200 and the note to 1000 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_payable := app_private.parse_amount(p_payable, 'the tax paid');
  v_asset := app_private.parse_amount(coalesce(nullif(btrim(p_asset_offset), ''), '0'), 'the input VAT offset');
  v_penalty := app_private.parse_amount(coalesce(nullif(btrim(p_penalty), ''), '0'), 'the penalty');
  if v_payable <= 0 or v_asset < 0 or v_penalty < 0
     or app_private.round_amount(v_payable, v_scale, 'down') <> v_payable
     or app_private.round_amount(v_asset, v_scale, 'down') <> v_asset
     or app_private.round_amount(v_penalty, v_scale, 'down') <> v_penalty then
    raise exception 'INVALID: the tax paid must be positive, the offset and penalty not negative, all with at most % decimals', v_scale
      using errcode = 'invalid_parameter_value';
  end if;
  if v_asset > 0 and p_tax_type <> 'vat' then
    raise exception 'INVALID: only VAT can be settled against input VAT' using errcode = 'invalid_parameter_value';
  end if;
  if v_asset > v_payable then
    raise exception 'INVALID: the input VAT offset cannot exceed the VAT paid against; excess input VAT stays as a credit'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_penalty > 0 and length(coalesce(v_note, '')) < 5 then
    raise exception 'INVALID: a penalty needs a note that explains it (for example the assessment number)'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_maker_checker(p_entity, 'tax', 'pay', v_payable + v_penalty - v_asset, auth.uid(), 'record this tax payment');

  v_cash := v_payable - v_asset + v_penalty;
  if v_cash > 0 then
    select * into fa from public.financial_accounts where id = p_account and entity_id = p_entity;
    if not found or not fa.is_active then
      raise exception 'INVALID: the paying account is unknown or inactive' using errcode = 'invalid_parameter_value';
    end if;
    if fa.currency <> e.base_currency then
      raise exception 'INVALID: tax is paid from an account in the Entity''s base currency (%)', e.base_currency
        using errcode = 'invalid_parameter_value';
    end if;
  elsif p_account is not null then
    raise exception 'INVALID: no account is needed when the whole payment is offset against input VAT'
      using errcode = 'invalid_parameter_value';
  end if;

  -- One writer at a time per tax type and period, so two payments can never settle the same liability twice.
  perform pg_advisory_xact_lock(hashtextextended('tax_payment:' || p_entity::text || ':' || p_tax_type || ':' || p_period::text, 0));
  select * into a from app_private.tax_period_amounts(p_entity, p_tax_type, p_period, v_today);
  v_outstanding := a.accrued_payable - a.paid_payable;
  if v_payable > v_outstanding then
    raise exception 'INVALID: % for % has % outstanding; the payment of % exceeds it', p_tax_type, to_char(p_period, 'YYYY-MM'),
      trim_scale(greatest(v_outstanding, 0)), trim_scale(v_payable) using errcode = 'invalid_parameter_value';
  end if;
  if v_asset > 0 then
    v_avail := app_private.tax_asset_available(p_entity, p_period, v_today);
    if v_asset > v_avail then
      raise exception 'INVALID: only % of input VAT is available to offset', trim_scale(v_avail) using errcode = 'invalid_parameter_value';
    end if;
  end if;

  if v_cash > 0 then
    perform 1 from public.financial_accounts where id = p_account and entity_id = p_entity for no key update;
  end if;
  perform app_private.ensure_tax_numbering(p_entity);
  v_number := app_private.allocate_document_number(p_entity, 'tax_payment', p_date);
  v_label := case p_tax_type when 'vat' then 'VAT' when 'wht_pph23' then 'PPh 23' else 'PPh Final' end;
  v_desc := format('Tax payment %s - %s %s', v_number, v_label, to_char(p_period, 'YYYY-MM'));

  v_lines := v_lines || jsonb_build_object('account_key', 'TAX_PAYABLE', 'debit', v_payable, 'credit', 0, 'description', v_desc);
  if v_penalty > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'TAX_PENALTY_EXPENSE', 'debit', v_penalty, 'credit', 0,
      'description', 'Penalty: ' || v_desc);
  end if;
  if v_asset > 0 then
    v_lines := v_lines || jsonb_build_object('account_key', 'TAX_ASSET', 'debit', 0, 'credit', v_asset,
      'description', 'Input VAT offset: ' || v_desc);
  end if;
  if v_cash > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', fa.ledger_account_id, 'debit', 0, 'credit', v_cash, 'description', v_desc);
  end if;
  v_journal := app_private.post_system_journal(p_entity, 'tax_payment', v_id, 'tax_payment.confirm', 'tax_payment.v1', p_date, v_desc, v_lines);
  if v_cash > 0 then
    perform app_private.record_movement(p_entity, p_account, 'out', v_cash, v_cash, null, p_date, 'tax_payment', v_id,
      'principal', v_journal, v_desc);
  end if;
  insert into public.tax_payments
    (id, entity_id, payment_number, tax_type, tax_period, payment_date, currency, payable_applied, asset_applied,
     penalty_amount, cash_amount, financial_account_id, reference, note, journal_id)
  values
    (v_id, p_entity, v_number, p_tax_type, p_period, p_date, e.base_currency, v_payable, v_asset, v_penalty, v_cash,
     case when v_cash > 0 then p_account end, v_ref, v_note, v_journal);
  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_entity, 'TaxPaymentRecorded', 'tax_payment', v_id,
          jsonb_build_object('payment_number', v_number, 'tax_type', p_tax_type, 'period', to_char(p_period, 'YYYY-MM')));
  perform app_private.idem_complete('tax.payment', p_entity, p_key, 'tax_payments', v_id);
  return v_id;
end
$$;

create function public.tax_reverse_payment(p_payment uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p public.tax_payments%rowtype;
  m public.money_movements%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into p from public.tax_payments where id = p_payment;
  if not found or not app_authz.has_permission(p.entity_id, 'tax.mark_filed') then
    raise exception 'FORBIDDEN: reversing a tax payment needs tax.mark_filed' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 or length(v_reason) > 1000 or p_date > app_private.entity_today(p.entity_id) then
    raise exception 'INVALID: a reversal needs a date (not in the future) and a reason of 5 to 1000 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  perform pg_advisory_xact_lock(hashtextextended('tax_payment:' || p.entity_id::text || ':' || p.tax_type || ':' || p.tax_period::text, 0));
  select * into p from public.tax_payments where id = p_payment for update;
  v_replay := app_private.idem_begin('tax.payment_reverse', p.entity_id, p_key,
    md5(jsonb_build_object('payment', p_payment, 'date', p_date, 'reason', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if p.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed payment can be reversed (now %)', p.status using errcode = 'integrity_constraint_violation';
  end if;
  if p_date < p.payment_date then
    raise exception 'INVALID: a reversal cannot be dated before the payment' using errcode = 'invalid_parameter_value';
  end if;
  if p.financial_account_id is not null then
    perform 1 from public.financial_accounts where id = p.financial_account_id and entity_id = p.entity_id for no key update;
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(p.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = p.entity_id and source_type = 'tax_payment' and source_id = p.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(p.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'tax_payment', p.id, m.component, v_rev, 'Reversal: ' || v_reason, m.id);
  end loop;
  update public.tax_payments
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reversed_date = p_date,
      reversed_by = auth.uid(), reverse_reason = v_reason
  where id = p.id;
  perform app_private.idem_complete('tax.payment_reverse', p.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

-- ------------------------------------------------------------ filings (the return as filed)
create table public.tax_filings (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  tax_type text not null check (tax_type in ('vat', 'wht_pph23', 'final_umkm')),
  tax_period date not null check (tax_period = date_trunc('month', tax_period)::date),
  filing_kind text not null check (filing_kind in ('original', 'amendment')),
  revision integer not null check (revision >= 0),
  filed_date date not null,
  -- Receipt / BPE / filing reference issued by the tax administration.
  reference text not null check (length(btrim(reference)) between 3 and 200),
  -- What the return reported: the tax base, the tax payable, and (VAT) the input VAT credited.
  reported_base public.money_amount not null default 0 check (reported_base >= 0),
  reported_tax public.money_amount not null default 0 check (reported_tax >= 0),
  reported_credit public.money_amount not null default 0 check (reported_credit >= 0),
  note text check (note is null or length(note) <= 1000),
  status text not null default 'filed' check (status in ('filed', 'superseded')),
  superseded_at timestamptz,
  superseded_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  constraint tax_filing_kind_revision check ((filing_kind = 'original') = (revision = 0)),
  constraint tax_filing_credit_vat_only check (tax_type = 'vat' or reported_credit = 0),
  constraint tax_filing_superseded_shape check ((status = 'superseded') = (superseded_at is not null and superseded_by is not null))
);
create unique index tax_filings_live_uq on public.tax_filings (entity_id, tax_type, tax_period) where status = 'filed';
create unique index tax_filings_revision_uq on public.tax_filings (entity_id, tax_type, tax_period, revision);
create index tax_filings_period_idx on public.tax_filings (entity_id, tax_period, tax_type);

create function app_private.tg_tax_filings_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'superseded_at', 'superseded_by', 'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'superseded' then
    raise exception 'A superseded filing cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'A filing cannot be edited; record an amendment instead' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.tax_filings
  for each row execute function app_private.tg_tax_filings_guard();
create trigger tg_forbid_delete before delete on public.tax_filings
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_filings
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_filings');
call app_private.secure_table('public.tax_filings');
create trigger tg_audit after insert or update or delete on public.tax_filings
  for each row execute function app_private.tg_audit('entity_id');

-- The return is recorded as evidence; it never changes a source transaction. An amendment keeps the original in
-- view and becomes the live filing of the period.
create function public.tax_record_filing(
  p_entity uuid, p_key text, p_tax_type text, p_period date, p_filed_date date, p_reference text,
  p_reported_base text, p_reported_tax text, p_reported_credit text default '0', p_amendment boolean default false,
  p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_today date;
  v_ref text := btrim(coalesce(p_reference, ''));
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_base numeric;
  v_tax numeric;
  v_credit numeric;
  v_live public.tax_filings%rowtype;
  v_id uuid := gen_random_uuid();
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.mark_filed') then
    raise exception 'FORBIDDEN: recording a filing needs tax.mark_filed' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.filing', p_entity, p_key,
    md5(jsonb_build_object('t', p_tax_type, 'p', p_period, 'd', p_filed_date, 'r', v_ref, 'b', p_reported_base,
                           'x', p_reported_tax, 'c', p_reported_credit, 'a', coalesce(p_amendment, false), 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  v_today := app_private.entity_today(p_entity);
  if p_tax_type is null or p_tax_type not in ('vat', 'wht_pph23', 'final_umkm') then
    raise exception 'INVALID: the tax type is vat, wht_pph23 or final_umkm' using errcode = 'invalid_parameter_value';
  end if;
  if p_period is null or p_period <> date_trunc('month', p_period)::date then
    raise exception 'INVALID: the tax period is the first day of a month' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_filed_date);
  if p_filed_date > v_today or p_filed_date < p_period then
    raise exception 'INVALID: the filing date cannot be in the future or before its tax period' using errcode = 'invalid_parameter_value';
  end if;
  if length(v_ref) not between 3 and 200 then
    raise exception 'INVALID: the filing reference (receipt number) is required, 3 to 200 characters' using errcode = 'invalid_parameter_value';
  end if;
  v_base := app_private.parse_amount(coalesce(nullif(btrim(p_reported_base), ''), '0'), 'the reported base');
  v_tax := app_private.parse_amount(coalesce(nullif(btrim(p_reported_tax), ''), '0'), 'the reported tax');
  v_credit := app_private.parse_amount(coalesce(nullif(btrim(p_reported_credit), ''), '0'), 'the reported credit');
  if v_base < 0 or v_tax < 0 or v_credit < 0 or (p_tax_type <> 'vat' and v_credit <> 0) then
    raise exception 'INVALID: reported amounts cannot be negative, and only a VAT return has a credit' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('tax_filing:' || p_entity::text || ':' || p_tax_type || ':' || p_period::text, 0));
  select * into v_live from public.tax_filings
  where entity_id = p_entity and tax_type = p_tax_type and tax_period = p_period and status = 'filed';
  if found and not coalesce(p_amendment, false) then
    raise exception 'CONFLICT: this period is already filed (%); record an amendment to change it', v_live.reference
      using errcode = 'integrity_constraint_violation';
  end if;
  if not found and coalesce(p_amendment, false) then
    raise exception 'INVALID: there is no filing of this period to amend' using errcode = 'invalid_parameter_value';
  end if;
  if v_live.id is not null and length(coalesce(v_note, '')) < 5 then
    raise exception 'INVALID: an amendment needs a note that says what changed' using errcode = 'invalid_parameter_value';
  end if;
  if v_live.id is not null and p_filed_date < v_live.filed_date then
    raise exception 'INVALID: an amendment cannot be dated before the filing it amends' using errcode = 'invalid_parameter_value';
  end if;
  -- The earlier filing steps aside first (one live filing per period), then the new one takes its place.
  if v_live.id is not null then
    update public.tax_filings set status = 'superseded', superseded_at = now(), superseded_by = v_id where id = v_live.id;
  end if;
  insert into public.tax_filings
    (id, entity_id, tax_type, tax_period, filing_kind, revision, filed_date, reference, reported_base, reported_tax,
     reported_credit, note)
  values
    (v_id, p_entity, p_tax_type, p_period, case when v_live.id is not null then 'amendment' else 'original' end,
     case when v_live.id is not null then v_live.revision + 1 else 0 end, p_filed_date, v_ref, v_base, v_tax, v_credit, v_note);
  perform app_private.idem_complete('tax.filing', p_entity, p_key, 'tax_filings', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ evidence documents for payments and filings
-- Proofs of payment and filing receipts use the same document registry as purchases. A link is never removed:
-- tax evidence is part of the record (Step 08 §18).
alter table public.document_links drop constraint document_links_target_type_check;
alter table public.document_links add constraint document_links_target_type_check
  check (target_type in ('bill', 'expense', 'tax_filing', 'tax_payment'));
alter table public.document_links drop constraint document_links_purpose_check;
alter table public.document_links add constraint document_links_purpose_check
  check (purpose in ('vendor_invoice', 'receipt', 'contract', 'other', 'filing_receipt', 'payment_proof',
                     'withholding_slip', 'tax_invoice'));

create or replace function app_private.tg_document_links_guard() returns trigger
language plpgsql as $$
declare
  v_status text;
  v_lock constant text[] := array['status', 'removed_at', 'removed_by', 'removed_reason', 'updated_at', 'updated_by',
                                   'version'];
begin
  if tg_op = 'INSERT' then
    if new.target_type = 'bill' then
      select b.status into v_status from public.bills b
      where b.id = new.target_id and b.entity_id = new.entity_id for share;
    elsif new.target_type = 'expense' then
      select x.status into v_status from public.expenses x
      where x.id = new.target_id and x.entity_id = new.entity_id for share;
    elsif new.target_type = 'tax_filing' then
      select f.status into v_status from public.tax_filings f
      where f.id = new.target_id and f.entity_id = new.entity_id for share;
    else
      select p.status into v_status from public.tax_payments p
      where p.id = new.target_id and p.entity_id = new.entity_id for share;
    end if;
    if v_status is null then
      raise exception 'INVALID: the % does not exist in this Entity', new.target_type using errcode = 'invalid_parameter_value';
    end if;
    -- Evidence may still be added to a superseded filing or a reversed payment: it belongs to the record.
    if v_status in ('cancelled', 'void', 'reversed') and new.target_type in ('bill', 'expense') then
      raise exception 'CONFLICT: a % % takes no more documents', v_status, new.target_type
        using errcode = 'integrity_constraint_violation';
    end if;
    return new;
  end if;
  if old.status = 'removed' then
    raise exception 'A removed document link cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'A document link cannot be edited; remove it and add a new one' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;

create function public.tax_link_evidence(p_document uuid, p_target_type text, p_target_id uuid, p_purpose text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  d public.documents%rowtype;
  v_entity uuid;
  v_purpose text;
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_target_type not in ('tax_filing', 'tax_payment') then
    raise exception 'INVALID: tax evidence attaches to a tax filing or a tax payment' using errcode = 'invalid_parameter_value';
  end if;
  select * into d from public.documents where id = p_document;
  v_entity := case p_target_type
    when 'tax_filing' then (select f.entity_id from public.tax_filings f where f.id = p_target_id)
    else (select p.entity_id from public.tax_payments p where p.id = p_target_id) end;
  if d.id is null or v_entity is null or v_entity <> d.entity_id
     or not app_authz.has_permission(d.entity_id, 'tax.mark_filed') then
    -- Registering a document (documents.upload) and attaching it to a tax record (tax.mark_filed) are separate rights.
    raise exception 'FORBIDDEN: attaching tax evidence needs tax.mark_filed' using errcode = 'insufficient_privilege';
  end if;
  v_purpose := coalesce(p_purpose, case p_target_type when 'tax_filing' then 'filing_receipt' else 'payment_proof' end);
  if v_purpose not in ('filing_receipt', 'payment_proof', 'withholding_slip', 'tax_invoice', 'other') then
    raise exception 'INVALID: the purpose is filing_receipt, payment_proof, withholding_slip, tax_invoice or other'
      using errcode = 'invalid_parameter_value';
  end if;
  select l.id into v_id from public.document_links l
  where l.document_id = d.id and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active';
  if v_id is not null then
    return v_id;
  end if;
  begin
    insert into public.document_links (entity_id, document_id, target_type, target_id, purpose)
    values (d.entity_id, d.id, p_target_type, p_target_id, v_purpose) returning id into v_id;
  exception when unique_violation then
    select l.id into v_id from public.document_links l
    where l.document_id = d.id and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active';
  end;
  return v_id;
end
$$;

create function public.tax_list_evidence(p_entity uuid, p_target_type text, p_target_id uuid)
returns table (link_id uuid, document_id uuid, file_name text, mime_type text, size_bytes bigint, sha256 text, purpose text,
               created_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') or not app_authz.has_permission(p_entity, 'documents.view') then
    raise exception 'FORBIDDEN: missing tax.view or documents.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select l.id, d.id, d.file_name, d.mime_type, d.size_bytes, d.sha256, l.purpose, l.created_at
  from public.document_links l
  join public.documents d on d.id = l.document_id and d.entity_id = l.entity_id
  where l.entity_id = p_entity and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active'
  order by l.created_at, l.id;
end
$$;

-- Evidence of a tax filing or payment cannot be unlinked (the purchase function keeps its own rules).
create or replace function public.unlink_document(p_link uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.document_links%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.document_links where id = p_link;
  if not found or not app_authz.has_permission(l.entity_id, 'documents.upload')
     or not (app_authz.has_permission(l.entity_id, 'bills.create') or app_authz.has_permission(l.entity_id, 'bills.edit')) then
    raise exception 'FORBIDDEN: removing a document needs documents.upload and bills.create' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 3 and 1000 then
    raise exception 'INVALID: a reason is required' using errcode = 'invalid_parameter_value';
  end if;
  select * into l from public.document_links where id = p_link for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: this document link is already removed' using errcode = 'integrity_constraint_violation';
  end if;
  if l.target_type in ('tax_filing', 'tax_payment') then
    raise exception 'CONFLICT: evidence of a tax payment or filing is part of the record and cannot be removed'
      using errcode = 'integrity_constraint_violation';
  end if;
  if l.target_type = 'bill' then
    select b.status into v_status from public.bills b where b.id = l.target_id and b.entity_id = l.entity_id for share;
  else
    select x.status into v_status from public.expenses x where x.id = l.target_id and x.entity_id = l.entity_id for share;
  end if;
  if v_status not in ('draft', 'submitted') then
    raise exception 'CONFLICT: evidence of a % % is part of the record and cannot be removed', v_status, l.target_type
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.document_links
  set status = 'removed', removed_at = now(), removed_by = auth.uid(), removed_reason = left(v_reason, 500)
  where id = l.id;
  return 'removed';
end
$$;

-- ------------------------------------------------------------ reconciliation of a period
create table public.tax_reconciliations (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  tax_type text not null check (tax_type in ('vat', 'wht_pph23', 'final_umkm')),
  tax_period date not null check (tax_period = date_trunc('month', tax_period)::date),
  outcome text not null check (outcome in ('reconciled', 'differences_noted')),
  -- The figures compared, and the differences found (empty when reconciled).
  figures jsonb not null,
  differences jsonb not null default '[]'::jsonb,
  note text check (note is null or length(note) <= 1000),
  filing_id uuid,
  status text not null default 'current' check (status in ('current', 'superseded')),
  superseded_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, filing_id) references public.tax_filings (entity_id, id) on delete restrict,
  constraint tax_recon_outcome_shape check ((outcome = 'reconciled') = (jsonb_array_length(differences) = 0)),
  constraint tax_recon_superseded_shape check ((status = 'superseded') = (superseded_at is not null))
);
create unique index tax_reconciliations_current_uq on public.tax_reconciliations (entity_id, tax_type, tax_period)
  where status = 'current';

create function app_private.tg_tax_reconciliations_guard() returns trigger
language plpgsql as $$
declare
  v_lock constant text[] := array['status', 'superseded_at', 'updated_at', 'updated_by', 'version'];
begin
  if old.status = 'superseded' then
    raise exception 'A superseded reconciliation cannot change any more' using errcode = 'integrity_constraint_violation';
  end if;
  if (to_jsonb(new) - v_lock) is distinct from (to_jsonb(old) - v_lock) then
    raise exception 'A reconciliation cannot be edited; record a new one' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.tax_reconciliations
  for each row execute function app_private.tg_tax_reconciliations_guard();
create trigger tg_forbid_delete before delete on public.tax_reconciliations
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.tax_reconciliations
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.tax_reconciliations');
call app_private.secure_table('public.tax_reconciliations');
create trigger tg_audit after insert or update or delete on public.tax_reconciliations
  for each row execute function app_private.tg_audit('entity_id');

-- The figures of a period: ledger, payments and the live filing side by side.
create function app_private.tax_period_figures(p_entity uuid, p_type text, p_period date, p_as_of date) returns jsonb
language plpgsql stable as $$
declare
  a record;
  f public.tax_filings%rowtype;
  v_base numeric;
begin
  select * into a from app_private.tax_period_amounts(p_entity, p_type, p_period, p_as_of);
  select * into f from public.tax_filings
  where entity_id = p_entity and tax_type = p_type and tax_period = p_period and status = 'filed';
  select coalesce(sum(d.base_amount), 0) into v_base from public.tax_determinations d
  where d.entity_id = p_entity and d.tax_type = p_type and d.tax_period = p_period and d.superseded_at is null
    and d.direction = 'payable';
  return jsonb_build_object(
    'accrued_payable', a.accrued_payable::text, 'accrued_asset', a.accrued_asset::text, 'base', v_base::text,
    'paid_payable', a.paid_payable::text, 'applied_asset', a.applied_asset::text, 'cash_paid', a.cash_paid::text,
    'penalty_paid', a.penalty_paid::text, 'outstanding_payable', (a.accrued_payable - a.paid_payable)::text,
    'filing_id', f.id, 'filed_reference', f.reference, 'filed_date', f.filed_date, 'filing_revision', f.revision,
    'reported_base', f.reported_base::text, 'reported_tax', f.reported_tax::text, 'reported_credit', f.reported_credit::text);
end
$$;

create function app_private.tax_period_differences(p_entity uuid, p_type text, p_period date, p_as_of date) returns jsonb
language plpgsql stable as $$
declare
  f jsonb := app_private.tax_period_figures(p_entity, p_type, p_period, p_as_of);
  v_out jsonb := '[]'::jsonb;
  v_pay numeric := (f ->> 'accrued_payable')::numeric;
  v_asset numeric := (f ->> 'accrued_asset')::numeric;
  v_outstanding numeric := (f ->> 'outstanding_payable')::numeric;
begin
  if f ->> 'filing_id' is null then
    v_out := v_out || jsonb_build_object('code', 'filing_missing', 'text', 'No filing is recorded for this period', 'amount', null);
  else
    if (f ->> 'reported_tax')::numeric <> v_pay then
      v_out := v_out || jsonb_build_object('code', 'filed_tax_differs',
        'text', format('The filing reports tax of %s; the tax ledger holds %s', trim_scale((f ->> 'reported_tax')::numeric), trim_scale(v_pay)),
        'amount', ((f ->> 'reported_tax')::numeric - v_pay)::text);
    end if;
    if p_type = 'vat' and (f ->> 'reported_credit')::numeric <> v_asset then
      v_out := v_out || jsonb_build_object('code', 'filed_credit_differs',
        'text', format('The filing credits input VAT of %s; the tax ledger holds %s', trim_scale((f ->> 'reported_credit')::numeric), trim_scale(v_asset)),
        'amount', ((f ->> 'reported_credit')::numeric - v_asset)::text);
    end if;
    if (f ->> 'reported_base')::numeric <> (f ->> 'base')::numeric then
      v_out := v_out || jsonb_build_object('code', 'filed_base_differs',
        'text', format('The filing reports a base of %s; the determinations hold %s', trim_scale((f ->> 'reported_base')::numeric), trim_scale((f ->> 'base')::numeric)),
        'amount', ((f ->> 'reported_base')::numeric - (f ->> 'base')::numeric)::text);
    end if;
  end if;
  if v_outstanding > 0 then
    v_out := v_out || jsonb_build_object('code', 'unpaid', 'text', format('%s of the tax for this period is not paid yet', trim_scale(v_outstanding)),
      'amount', v_outstanding::text);
  elsif v_outstanding < 0 then
    v_out := v_out || jsonb_build_object('code', 'overpaid', 'text', format('%s more was paid than the tax ledger holds', trim_scale(-v_outstanding)),
      'amount', v_outstanding::text);
  end if;
  return v_out;
end
$$;

create function public.tax_reconcile_period(
  p_entity uuid, p_key text, p_tax_type text, p_period date, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_today date;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_fig jsonb;
  v_diff jsonb;
  v_id uuid := gen_random_uuid();
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.mark_filed') then
    raise exception 'FORBIDDEN: reconciling a tax period needs tax.mark_filed' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('tax.reconcile', p_entity, p_key,
    md5(jsonb_build_object('t', p_tax_type, 'p', p_period, 'n', p_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_tax_type is null or p_tax_type not in ('vat', 'wht_pph23', 'final_umkm') then
    raise exception 'INVALID: the tax type is vat, wht_pph23 or final_umkm' using errcode = 'invalid_parameter_value';
  end if;
  if p_period is null or p_period <> date_trunc('month', p_period)::date then
    raise exception 'INVALID: the tax period is the first day of a month' using errcode = 'invalid_parameter_value';
  end if;
  v_today := app_private.entity_today(p_entity);
  if p_period > v_today then
    raise exception 'INVALID: a period that has not started cannot be reconciled' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('tax_reconcile:' || p_entity::text || ':' || p_tax_type || ':' || p_period::text, 0));
  v_fig := app_private.tax_period_figures(p_entity, p_tax_type, p_period, v_today);
  if (v_fig ->> 'accrued_payable')::numeric = 0 and (v_fig ->> 'accrued_asset')::numeric = 0
     and (v_fig ->> 'paid_payable')::numeric = 0 and v_fig ->> 'filing_id' is null then
    raise exception 'INVALID: there is nothing to reconcile for this period' using errcode = 'invalid_parameter_value';
  end if;
  v_diff := app_private.tax_period_differences(p_entity, p_tax_type, p_period, v_today);
  if jsonb_array_length(v_diff) > 0 and length(coalesce(v_note, '')) < 10 then
    raise exception 'INVALID: the period has % difference(s) (first: %); a note of at least 10 characters explains them',
      jsonb_array_length(v_diff), v_diff -> 0 ->> 'text' using errcode = 'invalid_parameter_value';
  end if;
  update public.tax_reconciliations set status = 'superseded', superseded_at = now()
  where entity_id = p_entity and tax_type = p_tax_type and tax_period = p_period and status = 'current';
  insert into public.tax_reconciliations (id, entity_id, tax_type, tax_period, outcome, figures, differences, note, filing_id)
  values (v_id, p_entity, p_tax_type, p_period, case when jsonb_array_length(v_diff) = 0 then 'reconciled' else 'differences_noted' end,
          v_fig, v_diff, v_note, nullif(v_fig ->> 'filing_id', '')::uuid);
  perform app_private.idem_complete('tax.reconcile', p_entity, p_key, 'tax_reconciliations', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ reading the position of a period
create function public.tax_period_position(p_entity uuid, p_tax_type text, p_period date, p_as_of date default null)
returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_asof date;
  v_fig jsonb;
  v_rec public.tax_reconciliations%rowtype;
  v_evidence bigint;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  if p_tax_type is null or p_tax_type not in ('vat', 'wht_pph23', 'final_umkm')
     or p_period is null or p_period <> date_trunc('month', p_period)::date then
    raise exception 'INVALID: a tax type and the first day of a month are required' using errcode = 'invalid_parameter_value';
  end if;
  v_asof := coalesce(p_as_of, app_private.entity_today(p_entity));
  v_fig := app_private.tax_period_figures(p_entity, p_tax_type, p_period, v_asof);
  select * into v_rec from public.tax_reconciliations
  where entity_id = p_entity and tax_type = p_tax_type and tax_period = p_period and status = 'current';
  select count(*) into v_evidence from public.document_links l
  where l.entity_id = p_entity and l.status = 'active'
    and ((l.target_type = 'tax_filing' and l.target_id = nullif(v_fig ->> 'filing_id', '')::uuid)
         or (l.target_type = 'tax_payment' and l.target_id in (
              select p.id from public.tax_payments p
              where p.entity_id = p_entity and p.tax_type = p_tax_type and p.tax_period = p_period and p.status = 'confirmed')));
  return v_fig || jsonb_build_object(
    'tax_type', p_tax_type, 'tax_period', p_period, 'as_of', v_asof,
    'asset_available', case when p_tax_type = 'vat' then app_private.tax_asset_available(p_entity, p_period, v_asof)::text end,
    'evidence_count', v_evidence,
    'differences', app_private.tax_period_differences(p_entity, p_tax_type, p_period, v_asof),
    'reconciliation', case when v_rec.id is null then null else jsonb_build_object(
        'id', v_rec.id, 'outcome', v_rec.outcome, 'note', v_rec.note, 'at', v_rec.created_at,
        -- Stale: what was compared no longer equals what the books hold now.
        'stale', (v_rec.figures - 'outstanding_payable') is distinct from (v_fig - 'outstanding_payable')) end);
end
$$;

create function public.tax_list_payments(
  p_entity uuid, p_tax_type text default null, p_period date default null, p_limit integer default 100)
returns table (payment_id uuid, payment_number text, status text, tax_type text, tax_period date, payment_date date,
               payable_applied text, asset_applied text, penalty_amount text, cash_amount text,
               financial_account_id uuid, reference text, journal_id uuid, reversal_journal_id uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select p.id, p.payment_number, p.status, p.tax_type, p.tax_period, p.payment_date, p.payable_applied::text, p.asset_applied::text,
         p.penalty_amount::text, p.cash_amount::text, p.financial_account_id, p.reference, p.journal_id, p.reversal_journal_id
  from public.tax_payments p
  where p.entity_id = p_entity and (p_tax_type is null or p.tax_type = p_tax_type) and (p_period is null or p.tax_period = p_period)
  order by p.payment_date desc, p.payment_number desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end
$$;

-- ------------------------------------------------------------ the tax control against the General Ledger
-- Journals the tax workflow itself produced (documents, tax payments, final-tax accruals) and their reversals take
-- part in the comparison; anything else posted to the tax accounts (manual journals, opening balances) is shown in
-- the "other" column, so the control never hides it (Step 08 §19: tax ledger reconciles to GL, with explicit
-- reconciling items).
create function app_private.is_tax_journal(p_journal uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.journal_entries j
    where j.id = p_journal
      and (j.source_type in ('invoice', 'bill', 'expense', 'tax_payment', 'tax_period')
           or exists (select 1 from public.journal_entries o
                      where o.id = j.reverses_journal_id and o.source_type in ('invoice', 'bill', 'expense', 'tax_payment', 'tax_period'))))
$$;

create function app_private.tax_control(p_entity uuid, p_as_of date default null)
returns table (account_key text, sub_ledger numeric, ledger_workflow numeric, ledger_other numeric, ledger_total numeric)
language plpgsql stable as $$
declare
  v_asof date := coalesce(p_as_of, app_private.entity_today(p_entity));
  v_pay_sub numeric;
  v_asset_sub numeric;
  v_pay_wf numeric;
  v_pay_tot numeric;
  v_asset_wf numeric;
  v_asset_tot numeric;
begin
  select coalesce(sum(e.amount), 0) into v_pay_sub from public.tax_ledger_entries e
  where e.entity_id = p_entity and e.direction = 'payable' and e.entry_date <= v_asof;
  v_pay_sub := v_pay_sub - coalesce((select sum(p.payable_applied) from public.tax_payments p
      where p.entity_id = p_entity and p.payment_date <= v_asof and (p.status = 'confirmed' or p.reversed_date > v_asof)), 0);
  select coalesce(sum(e.amount), 0) into v_asset_sub from public.tax_ledger_entries e
  where e.entity_id = p_entity and e.direction = 'asset' and e.entry_date <= v_asof;
  v_asset_sub := v_asset_sub - coalesce((select sum(p.asset_applied) from public.tax_payments p
      where p.entity_id = p_entity and p.payment_date <= v_asof and (p.status = 'confirmed' or p.reversed_date > v_asof)), 0);

  select coalesce(sum(l.credit - l.debit), 0),
         coalesce(sum(l.credit - l.debit) filter (where app_private.is_tax_journal(j.id)), 0)
    into v_pay_tot, v_pay_wf
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = 'TAX_PAYABLE' and j.status = 'posted' and j.entry_date <= v_asof;
  select coalesce(sum(l.debit - l.credit), 0),
         coalesce(sum(l.debit - l.credit) filter (where app_private.is_tax_journal(j.id)), 0)
    into v_asset_tot, v_asset_wf
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = 'TAX_ASSET' and j.status = 'posted' and j.entry_date <= v_asof;

  return query
  select 'TAX_PAYABLE'::text, v_pay_sub, v_pay_wf, v_pay_tot - v_pay_wf, v_pay_tot
  union all
  select 'TAX_ASSET'::text, v_asset_sub, v_asset_wf, v_asset_tot - v_asset_wf, v_asset_tot;
end
$$;

create function public.tax_control_report(p_entity uuid, p_as_of date default null)
returns table (account_key text, sub_ledger text, ledger_workflow text, ledger_other text, ledger_total text, difference text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') or not app_authz.has_permission(p_entity, 'accounting.view') then
    raise exception 'FORBIDDEN: the tax control needs tax.view and accounting.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select c.account_key, c.sub_ledger::text, c.ledger_workflow::text, c.ledger_other::text, c.ledger_total::text,
         (c.sub_ledger - c.ledger_workflow)::text
  from app_private.tax_control(p_entity, p_as_of) c;
end
$$;

-- ------------------------------------------------------------ the tax ledger as a report
create function public.tax_ledger_report(
  p_entity uuid, p_from date default null, p_to date default null, p_tax_type text default null, p_limit integer default 200)
returns table (entry_id uuid, entry_date date, tax_period date, tax_kind text, tax_type text, direction text, entry_kind text,
               amount text, source_type text, source_id uuid, determination_status text, journal_id uuid, description text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'tax.view') then
    raise exception 'FORBIDDEN: missing tax.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select e.id, e.entry_date, e.tax_period, e.tax_kind, e.tax_type, e.direction, e.entry_kind, e.amount::text,
         d.source_type, d.source_id, d.status, e.journal_id, e.description
  from public.tax_ledger_entries e
  join public.tax_determinations d on d.id = e.determination_id and d.entity_id = e.entity_id
  where e.entity_id = p_entity and (p_from is null or e.entry_date >= p_from) and (p_to is null or e.entry_date <= p_to)
    and (p_tax_type is null or e.tax_type = p_tax_type)
  order by e.entry_date desc, e.created_at desc, e.id
  limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.tax_payments');
create policy tax_payments_select on public.tax_payments for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));
call app_private.expose_select('public.tax_filings');
create policy tax_filings_select on public.tax_filings for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));
call app_private.expose_select('public.tax_reconciliations');
create policy tax_reconciliations_select on public.tax_reconciliations for select to authenticated
  using (app_authz.has_permission(entity_id, 'tax.view'));

revoke all on function app_private.ensure_tax_numbering(uuid) from public;
revoke all on function app_private.tg_tax_payments_guard() from public;
revoke all on function app_private.tg_tax_payments_capacity() from public;
revoke all on function app_private.tg_tax_filings_guard() from public;
revoke all on function app_private.tg_tax_reconciliations_guard() from public;
revoke all on function app_private.tax_period_amounts(uuid, text, date, date) from public;
revoke all on function app_private.tax_asset_available(uuid, date, date) from public;
revoke all on function app_private.tax_period_figures(uuid, text, date, date) from public;
revoke all on function app_private.tax_period_differences(uuid, text, date, date) from public;
revoke all on function app_private.is_tax_journal(uuid) from public;
revoke all on function app_private.tax_control(uuid, date) from public;

revoke all on function public.tax_record_payment(uuid, text, text, date, date, uuid, text, text, text, text, text) from public, anon;
revoke all on function public.tax_reverse_payment(uuid, text, date, text) from public, anon;
revoke all on function public.tax_record_filing(uuid, text, text, date, date, text, text, text, text, boolean, text) from public, anon;
revoke all on function public.tax_link_evidence(uuid, text, uuid, text) from public, anon;
revoke all on function public.tax_list_evidence(uuid, text, uuid) from public, anon;
revoke all on function public.tax_reconcile_period(uuid, text, text, date, text) from public, anon;
revoke all on function public.tax_period_position(uuid, text, date, date) from public, anon;
revoke all on function public.tax_list_payments(uuid, text, date, integer) from public, anon;
revoke all on function public.tax_control_report(uuid, date) from public, anon;
revoke all on function public.tax_ledger_report(uuid, date, date, text, integer) from public, anon;
grant execute on function public.tax_record_payment(uuid, text, text, date, date, uuid, text, text, text, text, text) to authenticated;
grant execute on function public.tax_reverse_payment(uuid, text, date, text) to authenticated;
grant execute on function public.tax_record_filing(uuid, text, text, date, date, text, text, text, text, boolean, text) to authenticated;
grant execute on function public.tax_link_evidence(uuid, text, uuid, text) to authenticated;
grant execute on function public.tax_list_evidence(uuid, text, uuid) to authenticated;
grant execute on function public.tax_reconcile_period(uuid, text, text, date, text) to authenticated;
grant execute on function public.tax_period_position(uuid, text, date, date) to authenticated;
grant execute on function public.tax_list_payments(uuid, text, date, integer) to authenticated;
grant execute on function public.tax_control_report(uuid, date) to authenticated;
grant execute on function public.tax_ledger_report(uuid, date, date, text, integer) to authenticated;
