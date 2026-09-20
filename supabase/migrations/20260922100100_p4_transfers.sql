-- P4 (Step 15 §8): same-Entity transfers with paired money movements, explicit fee and FX components.
-- Authority: Step 04 §5 (cash, bank & transfers), Step 07 §9 (transfer workflow), Step 08 §9 (transfer
-- integrity), Step 03 §7-§8 (financial account mapping; PT <-> Personal boundary), Step 06 §7 (maker-checker).
--
-- What a transfer is
--   * Money moves between two financial accounts of the SAME Entity. Nothing is earned or spent: the journal
--     debits the destination account and credits the source account, plus two explicit optional components -
--     the bank fee (debit Bank Fee Expense, credit the source) and the FX difference (against FX gain/loss).
--   * PT <-> Personal is never a generic transfer (Step 03 §8). The two accounts are resolved inside one
--     Entity, and the database also refuses a cross-Entity pair structurally (composite foreign keys).
--   * Draft has no accounting or cash effect. Confirming posts the journal and the movements in ONE transaction.
--   * A confirmed transfer is corrected only by reversing it (the original is retained).

-- The shared numbering framework gets a scope of its own for transfers.
alter table public.numbering_sequences drop constraint numbering_sequences_scope_check;
alter table public.numbering_sequences add constraint numbering_sequences_scope_check
  check (scope in ('invoice', 'payment_receipt', 'refund_receipt', 'bill', 'journal', 'transfer', 'other'));

-- ------------------------------------------------------------ transfers
create table public.transfers (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  transfer_number text,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'reversed', 'cancelled')),
  transfer_date date not null,
  from_account_id uuid not null,
  to_account_id uuid not null,
  -- Principal leaving the source (source currency) and arriving at the destination (destination currency).
  amount_out public.money_amount not null check (amount_out > 0),
  amount_in public.money_amount not null check (amount_in > 0),
  -- Explicit bank fee, charged to the source account in the source currency.
  fee_amount public.money_amount not null default 0 check (fee_amount >= 0),
  -- Rate snapshots (base currency per unit); present exactly for foreign-currency accounts.
  rate_out public.fx_rate,
  rate_in public.fx_rate,
  -- Base-currency values and the separately identifiable FX difference (positive = gain, negative = loss).
  base_out public.money_amount not null check (base_out > 0),
  base_in public.money_amount not null check (base_in > 0),
  base_fee public.money_amount not null default 0 check (base_fee >= 0),
  fx_difference public.money_amount not null default 0,
  description text,
  reference text,
  journal_id uuid,
  reversal_journal_id uuid,
  confirmed_at timestamptz,
  confirmed_by uuid,
  cancelled_at timestamptz,
  reversed_at timestamptz,
  reverse_reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, from_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, to_account_id) references public.financial_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reversal_journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  constraint transfer_distinct_accounts check (from_account_id <> to_account_id),
  -- What arrives (in base value) is what left plus the explicit FX difference: nothing else can hide in between.
  constraint transfer_fx_identity check (base_in = base_out + fx_difference),
  constraint transfer_state_consistent check (
    case status
      when 'draft' then journal_id is null and transfer_number is null and reversal_journal_id is null
      when 'cancelled' then journal_id is null and transfer_number is null and reversal_journal_id is null
      when 'confirmed' then journal_id is not null and transfer_number is not null and reversal_journal_id is null
      else journal_id is not null and transfer_number is not null and reversal_journal_id is not null
    end)
);
create unique index transfers_number_uq on public.transfers (entity_id, transfer_number) where transfer_number is not null;
create index transfers_entity_date_idx on public.transfers (entity_id, transfer_date);
create index transfers_from_idx on public.transfers (entity_id, from_account_id);
create index transfers_to_idx on public.transfers (entity_id, to_account_id);

-- The economic content of a transfer never changes after creation; only its lifecycle moves, and never out of a
-- terminal state (Step 07 §9).
create function app_private.tg_transfers_guard() returns trigger
language plpgsql as $$
begin
  if (new.transfer_date, new.from_account_id, new.to_account_id, new.amount_out, new.amount_in, new.fee_amount,
      new.rate_out, new.rate_in, new.base_out, new.base_in, new.base_fee, new.fx_difference, new.description,
      new.reference, new.created_at, new.created_by)
     is distinct from
     (old.transfer_date, old.from_account_id, old.to_account_id, old.amount_out, old.amount_in, old.fee_amount,
      old.rate_out, old.rate_in, old.base_out, old.base_in, old.base_fee, old.fx_difference, old.description,
      old.reference, old.created_at, old.created_by) then
    raise exception 'The content of a transfer cannot be changed; cancel the draft or reverse the transfer'
      using errcode = 'integrity_constraint_violation';
  end if;
  if old.status in ('cancelled', 'reversed') then
    raise exception 'A % transfer cannot change any more', old.status using errcode = 'integrity_constraint_violation';
  end if;
  if new.status <> old.status
     and (old.status, new.status) not in (('draft', 'confirmed'), ('draft', 'cancelled'), ('confirmed', 'reversed')) then
    raise exception 'A transfer cannot move from % to %', old.status, new.status
      using errcode = 'integrity_constraint_violation';
  end if;
  if old.status = 'confirmed' and new.status = 'confirmed'
     and (new.journal_id is distinct from old.journal_id or new.transfer_number is distinct from old.transfer_number) then
    raise exception 'The posting of a confirmed transfer cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.transfers
  for each row execute function app_private.tg_transfers_guard();
create trigger tg_forbid_delete before delete on public.transfers
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.transfers
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.transfers');
call app_private.secure_table('public.transfers');
create trigger tg_audit after insert or update or delete on public.transfers
  for each row execute function app_private.tg_audit('entity_id');
call app_private.expose_select('public.transfers');
create policy transfers_select on public.transfers for select to authenticated
  using (app_authz.has_permission(entity_id, 'money.view'));

-- ------------------------------------------------------------ figures
-- Validates a transfer's amounts and rates against its two accounts and returns the base-currency figures.
-- The FX difference is explicit and bounded: a mistyped rate must not be able to conjure a large gain or loss
-- (Step 04 §14: the engine never hides a material difference).
create function app_private.transfer_figures(
  p_entity uuid, p_from uuid, p_to uuid, p_amount_out numeric, p_amount_in numeric, p_fee numeric,
  p_rate_out numeric, p_rate_in numeric)
returns table (amount_in numeric, base_out numeric, base_in numeric, base_fee numeric, fx_difference numeric)
language plpgsql stable as $$
declare
  v_base public.currency_code;
  v_from_cur public.currency_code;
  v_to_cur public.currency_code;
  v_in numeric;
  v_fee numeric := coalesce(p_fee, 0);
  v_base_out numeric;
  v_base_in numeric;
  v_base_fee numeric;
begin
  select e.base_currency into v_base from public.entities e where e.id = p_entity;
  select fa.currency into v_from_cur from public.financial_accounts fa where fa.id = p_from and fa.entity_id = p_entity;
  select fa.currency into v_to_cur from public.financial_accounts fa where fa.id = p_to and fa.entity_id = p_entity;

  if p_amount_out is null or not app_private.is_finite(p_amount_out) or p_amount_out <= 0
     or p_amount_out >= 10::numeric ^ 16 then
    raise exception 'INVALID: the transfer amount must be a positive number' using errcode = 'invalid_parameter_value';
  end if;
  if not app_private.is_finite(v_fee) or v_fee < 0 or v_fee >= 10::numeric ^ 16 then
    raise exception 'INVALID: the fee must be zero or a positive number' using errcode = 'invalid_parameter_value';
  end if;
  v_in := coalesce(p_amount_in, case when v_from_cur = v_to_cur then p_amount_out end);
  if v_in is null or not app_private.is_finite(v_in) or v_in <= 0 or v_in >= 10::numeric ^ 16 then
    raise exception 'INVALID: the amount received is required when the accounts use different currencies'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_from_cur = v_to_cur and v_in <> p_amount_out then
    raise exception 'INVALID: with the same currency on both sides the amount received equals the amount sent'
      using errcode = 'invalid_parameter_value';
  end if;
  if app_private.round_amount(p_amount_out, app_private.currency_scale(v_from_cur), 'down') <> p_amount_out
     or app_private.round_amount(v_fee, app_private.currency_scale(v_from_cur), 'down') <> v_fee then
    raise exception 'INVALID: amount and fee allow % decimals for %', app_private.currency_scale(v_from_cur), v_from_cur
      using errcode = 'invalid_parameter_value';
  end if;
  if app_private.round_amount(v_in, app_private.currency_scale(v_to_cur), 'down') <> v_in then
    raise exception 'INVALID: the amount received allows % decimals for %', app_private.currency_scale(v_to_cur), v_to_cur
      using errcode = 'invalid_parameter_value';
  end if;

  -- Rate snapshots: required exactly for foreign-currency accounts.
  if (v_from_cur = v_base) <> (p_rate_out is null) then
    raise exception 'INVALID: an exchange rate is required for a foreign-currency source account, and only then'
      using errcode = 'invalid_parameter_value';
  end if;
  if (v_to_cur = v_base) <> (p_rate_in is null) then
    raise exception 'INVALID: an exchange rate is required for a foreign-currency destination account, and only then'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_rate_out is not null and app_private.round_amount(p_rate_out, 10, 'down') <> p_rate_out
     or p_rate_in is not null and app_private.round_amount(p_rate_in, 10, 'down') <> p_rate_in then
    raise exception 'INVALID: exchange rates allow 10 decimals' using errcode = 'invalid_parameter_value';
  end if;

  if v_from_cur = v_to_cur and v_from_cur <> v_base and p_rate_out <> p_rate_in then
    raise exception 'INVALID: with the same foreign currency on both sides one exchange rate applies (a transfer creates no exchange gain)'
      using errcode = 'invalid_parameter_value';
  end if;

  v_base_out := case when v_from_cur = v_base then p_amount_out else app_private.convert_amount(p_amount_out, p_rate_out, v_base) end;
  v_base_fee := case when v_from_cur = v_base then v_fee else app_private.convert_amount(v_fee, p_rate_out, v_base) end;
  v_base_in := case when v_to_cur = v_base then v_in else app_private.convert_amount(v_in, p_rate_in, v_base) end;
  if v_base_out <= 0 or v_base_in <= 0 or (v_fee > 0 and v_base_fee <= 0) then
    raise exception 'INVALID: the amount or fee is too small to book in %', v_base using errcode = 'invalid_parameter_value';
  end if;
  if abs(v_base_in - v_base_out) * 5 > v_base_out then
    raise exception 'INVALID: the FX difference exceeds 20%% of the amount; check the exchange rates'
      using errcode = 'invalid_parameter_value';
  end if;

  return query select v_in, v_base_out, v_base_in, v_base_fee, v_base_in - v_base_out;
end
$$;

-- Bank fees go to Bank Fee Expense; a Personal Entity has no such account in its default COA, so its fees use
-- Other Personal Expenses (documented decision).
create function app_private.fee_expense_account(p_entity uuid) returns uuid
language sql stable as $$
  select a.id from public.ledger_accounts a
  where a.entity_id = p_entity and a.status = 'active' and not a.is_group
    and a.system_key in ('BANK_FEE_EXPENSE', 'OTHER_PERSONAL_EXPENSE')
  order by (a.system_key = 'BANK_FEE_EXPENSE') desc
  limit 1
$$;

-- ------------------------------------------------------------ confirmation (posting)
-- Posts the transfer journal and its paired movements in the caller's transaction. Assumes the caller holds the
-- lock on the transfer row and has already checked authorization and the approval rule.
create function app_private.confirm_transfer_core(p_transfer uuid) returns uuid
language plpgsql as $$
declare
  t public.transfers%rowtype;
  v_from public.financial_accounts%rowtype;
  v_to public.financial_accounts%rowtype;
  v_base public.currency_code;
  v_lines jsonb := '[]'::jsonb;
  v_fee_account uuid;
  v_fx_account uuid;
  v_number text;
  v_journal uuid;
  v_desc text;
  v_orig_out jsonb := '{}'::jsonb;
  v_orig_in jsonb := '{}'::jsonb;
  v_orig_fee jsonb := '{}'::jsonb;
begin
  select * into t from public.transfers where id = p_transfer;
  select base_currency into v_base from public.entities where id = t.entity_id;

  -- Both accounts are locked in a fixed order so two opposite transfers can never deadlock.
  perform 1 from public.financial_accounts
  where entity_id = t.entity_id and id in (t.from_account_id, t.to_account_id)
  order by id for no key update;
  select * into v_from from public.financial_accounts where id = t.from_account_id;
  select * into v_to from public.financial_accounts where id = t.to_account_id;
  if not v_from.is_active or not v_to.is_active then
    raise exception 'CONFLICT: both financial accounts must be active to confirm a transfer'
      using errcode = 'integrity_constraint_violation';
  end if;

  v_desc := coalesce(nullif(btrim(coalesce(t.description, '')), ''), 'Transfer')
            || ' (' || v_from.name || ' -> ' || v_to.name || ')';
  if v_from.currency <> v_base then
    v_orig_out := jsonb_build_object('original_currency', v_from.currency, 'original_amount', t.amount_out, 'exchange_rate', t.rate_out);
  end if;
  if v_from.currency <> v_base then
    v_orig_fee := jsonb_build_object('original_currency', v_from.currency, 'original_amount', t.fee_amount, 'exchange_rate', t.rate_out);
  end if;
  if v_to.currency <> v_base then
    v_orig_in := jsonb_build_object('original_currency', v_to.currency, 'original_amount', t.amount_in, 'exchange_rate', t.rate_in);
  end if;

  v_lines := v_lines
    || (jsonb_build_object('account_id', v_to.ledger_account_id, 'debit', t.base_in, 'credit', 0, 'description', v_desc) || v_orig_in)
    || (jsonb_build_object('account_id', v_from.ledger_account_id, 'debit', 0, 'credit', t.base_out, 'description', v_desc) || v_orig_out);

  if t.base_fee > 0 then
    v_fee_account := app_private.fee_expense_account(t.entity_id);
    if v_fee_account is null then
      raise exception 'CONFLICT: this Entity has no bank fee expense account to book the fee on'
        using errcode = 'integrity_constraint_violation';
    end if;
    v_lines := v_lines
      || (jsonb_build_object('account_id', v_fee_account, 'debit', t.base_fee, 'credit', 0, 'description', 'Transfer fee: ' || v_desc) || v_orig_fee)
      || (jsonb_build_object('account_id', v_from.ledger_account_id, 'debit', 0, 'credit', t.base_fee, 'description', 'Transfer fee: ' || v_desc) || v_orig_fee);
  end if;
  if t.fx_difference <> 0 then
    select a.id into v_fx_account from public.ledger_accounts a
    where a.entity_id = t.entity_id and a.system_key = 'FX_GAIN_LOSS' and a.status = 'active';
    if v_fx_account is null then
      raise exception 'CONFLICT: this Entity has no FX gain/loss account' using errcode = 'integrity_constraint_violation';
    end if;
    v_lines := v_lines || jsonb_build_object(
      'account_id', v_fx_account,
      'debit', case when t.fx_difference < 0 then -t.fx_difference else 0 end,
      'credit', case when t.fx_difference > 0 then t.fx_difference else 0 end,
      'description', 'FX difference: ' || v_desc);
  end if;

  insert into public.numbering_sequences (entity_id, scope, prefix)
  values (t.entity_id, 'transfer', 'TRF')
  on conflict (entity_id, scope) do nothing;

  v_journal := app_private.post_system_journal(
    t.entity_id, 'transfer', t.id, 'transfer.v1', 'transfer.v1', t.transfer_date, v_desc, v_lines);

  perform app_private.record_movement(t.entity_id, t.from_account_id, 'out', t.amount_out, t.base_out, t.rate_out,
    t.transfer_date, 'transfer', t.id, 'principal', v_journal, v_desc);
  if t.base_fee > 0 then
    perform app_private.record_movement(t.entity_id, t.from_account_id, 'out', t.fee_amount, t.base_fee, t.rate_out,
      t.transfer_date, 'transfer', t.id, 'fee', v_journal, 'Transfer fee: ' || v_desc);
  end if;
  perform app_private.record_movement(t.entity_id, t.to_account_id, 'in', t.amount_in, t.base_in, t.rate_in,
    t.transfer_date, 'transfer', t.id, 'principal', v_journal, v_desc);

  v_number := app_private.allocate_document_number(t.entity_id, 'transfer', t.transfer_date);
  update public.transfers
  set status = 'confirmed', journal_id = v_journal, transfer_number = v_number,
      confirmed_at = now(), confirmed_by = auth.uid()
  where id = p_transfer;
  return v_journal;
end
$$;

-- Maker-checker (Step 06 §7): an effective approval rule for module "money", action "transfer" at or below the
-- amount may forbid approving one's own transfer. The OWNER may always approve their own event (Step 04 §11).
create function app_private.assert_transfer_approver(p_transfer uuid) returns void
language plpgsql stable as $$
declare
  t public.transfers%rowtype;
  v_rule public.approval_rules%rowtype;
begin
  select * into t from public.transfers where id = p_transfer;
  select r.* into v_rule from public.approval_rules r
  where r.entity_id = t.entity_id and r.module = 'money' and r.action = 'transfer'
    and r.effective_from <= (now() at time zone 'UTC')::date
    and (r.effective_to is null or r.effective_to >= (now() at time zone 'UTC')::date)
    and coalesce(r.min_amount, 0) <= t.base_out
  order by coalesce(r.min_amount, 0) desc
  limit 1;
  if found and v_rule.requires_approval and not v_rule.allow_self_approval
     and t.created_by is not distinct from auth.uid() and not app_authz.is_owner(t.entity_id) then
    raise exception 'FORBIDDEN: an approval rule requires a different person to confirm this transfer'
      using errcode = 'insufficient_privilege';
  end if;
end
$$;

-- ------------------------------------------------------------ public commands
create function public.create_transfer(
  p_entity uuid, p_key text, p_from uuid, p_to uuid, p_date date, p_amount_out numeric,
  p_amount_in numeric default null, p_fee numeric default 0, p_rate_out numeric default null,
  p_rate_in numeric default null, p_description text default null, p_reference text default null,
  p_confirm boolean default false)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
  f record;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'money.transfer_create') then
    raise exception 'FORBIDDEN: missing money.transfer_create' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_confirm, false) and not app_authz.has_permission(p_entity, 'money.transfer_approve') then
    raise exception 'FORBIDDEN: confirming a transfer needs money.transfer_approve' using errcode = 'insufficient_privilege';
  end if;
  perform app_private.assert_business_date(p_date);

  v_replay := app_private.idem_begin('transfer.create', p_entity, p_key,
    md5(jsonb_build_object('from', p_from, 'to', p_to, 'date', p_date, 'out', p_amount_out, 'in', p_amount_in,
                           'fee', coalesce(p_fee, 0), 'rate_out', p_rate_out, 'rate_in', p_rate_in,
                           'desc', p_description, 'ref', p_reference, 'confirm', coalesce(p_confirm, false))::text));
  if v_replay is not null then
    return v_replay;
  end if;

  if p_from is null or p_to is null or p_from = p_to then
    raise exception 'INVALID: a transfer needs two different financial accounts' using errcode = 'invalid_parameter_value';
  end if;
  -- Both accounts must belong to THIS Entity. The message is the same whether the account is unknown or lives
  -- in another Entity: nothing about other Entities is revealed, and PT <-> Personal is never a generic transfer.
  if (select count(*) from public.financial_accounts where entity_id = p_entity and id in (p_from, p_to)) <> 2 then
    raise exception 'INVALID: both accounts must belong to this Entity; money between PT and Personal needs its real economic basis (Step 03 §8)'
      using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.financial_accounts where id in (p_from, p_to) and not is_active) then
    raise exception 'CONFLICT: an inactive financial account cannot be used in a transfer'
      using errcode = 'integrity_constraint_violation';
  end if;

  select * into f from app_private.transfer_figures(p_entity, p_from, p_to, p_amount_out, p_amount_in, p_fee, p_rate_out, p_rate_in);
  insert into public.transfers
    (entity_id, transfer_date, from_account_id, to_account_id, amount_out, amount_in, fee_amount, rate_out, rate_in,
     base_out, base_in, base_fee, fx_difference, description, reference)
  values
    (p_entity, p_date, p_from, p_to, p_amount_out, f.amount_in, coalesce(p_fee, 0), p_rate_out, p_rate_in,
     f.base_out, f.base_in, f.base_fee, f.fx_difference,
     nullif(btrim(coalesce(p_description, '')), ''), nullif(btrim(coalesce(p_reference, '')), ''))
  returning id into v_id;

  if coalesce(p_confirm, false) then
    perform app_private.assert_transfer_approver(v_id);
    perform app_private.confirm_transfer_core(v_id);
  end if;

  perform app_private.idem_complete('transfer.create', p_entity, p_key, 'transfers', v_id);
  return v_id;
end
$$;

create function public.confirm_transfer(p_transfer uuid, p_key text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  t public.transfers%rowtype;
  v_replay uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into t from public.transfers where id = p_transfer;
  -- The same answer for "does not exist" and "not allowed": no existence leak across Entities.
  if not found or not app_authz.has_permission(t.entity_id, 'money.transfer_approve') then
    raise exception 'FORBIDDEN: missing money.transfer_approve' using errcode = 'insufficient_privilege';
  end if;
  select * into t from public.transfers where id = p_transfer for update;

  v_replay := app_private.idem_begin('transfer.confirm', t.entity_id, p_key, md5(p_transfer::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if t.status <> 'draft' then
    raise exception 'CONFLICT: only a draft transfer can be confirmed (now %)', t.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_transfer_approver(p_transfer);
  perform app_private.confirm_transfer_core(p_transfer);
  perform app_private.idem_complete('transfer.confirm', t.entity_id, p_key, 'transfers', p_transfer);
  return p_transfer;
end
$$;

create function public.cancel_transfer(p_transfer uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  t public.transfers%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into t from public.transfers where id = p_transfer;
  if not found or not app_authz.has_permission(t.entity_id, 'money.transfer_create') then
    raise exception 'FORBIDDEN: missing money.transfer_create' using errcode = 'insufficient_privilege';
  end if;
  select * into t from public.transfers where id = p_transfer for update;
  if t.status <> 'draft' then
    raise exception 'CONFLICT: only a draft transfer can be cancelled; reverse a confirmed one (now %)', t.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Draft transfer cancelled'), true);
  update public.transfers set status = 'cancelled', cancelled_at = now() where id = p_transfer;
  return 'cancelled';
end
$$;

-- Reversal is the only correction of a confirmed transfer (Step 04 §11): the reversal journal mirrors the
-- original and every original movement gets its mirror movement; the original stays on record.
create function public.reverse_transfer(p_transfer uuid, p_key text, p_date date, p_reason text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  t public.transfers%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_replay uuid;
  v_rev uuid;
  m public.money_movements%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into t from public.transfers where id = p_transfer;
  if not found or not app_authz.has_permission(t.entity_id, 'money.transfer_approve') then
    raise exception 'FORBIDDEN: missing money.transfer_approve' using errcode = 'insufficient_privilege';
  end if;
  if p_date is null or length(v_reason) < 5 then
    raise exception 'INVALID: a reversal needs a date and a reason of at least 5 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);
  select * into t from public.transfers where id = p_transfer for update;

  v_replay := app_private.idem_begin('transfer.reverse', t.entity_id, p_key,
    md5(jsonb_build_object('transfer', p_transfer, 'date', p_date, 'reason', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if t.status <> 'confirmed' then
    raise exception 'CONFLICT: only a confirmed transfer can be reversed (now %)', t.status
      using errcode = 'integrity_constraint_violation';
  end if;
  perform 1 from public.financial_accounts
  where entity_id = t.entity_id and id in (t.from_account_id, t.to_account_id) order by id for no key update;

  perform set_config('app.audit_reason', v_reason, true);
  v_rev := app_private.reverse_journal_core(t.journal_id, p_date, v_reason);
  for m in
    select * from public.money_movements
    where entity_id = t.entity_id and source_type = 'transfer' and source_id = t.id and reverses_movement_id is null
    order by created_at, id
  loop
    perform app_private.record_movement(
      t.entity_id, m.financial_account_id, case m.direction when 'in' then 'out' else 'in' end,
      m.amount, m.base_amount, m.exchange_rate, p_date, 'transfer', t.id, m.component, v_rev,
      'Reversal: ' || v_reason, m.id);
  end loop;
  update public.transfers
  set status = 'reversed', reversal_journal_id = v_rev, reversed_at = now(), reverse_reason = v_reason
  where id = p_transfer;

  perform app_private.idem_complete('transfer.reverse', t.entity_id, p_key, 'journal_entries', v_rev);
  return v_rev;
end
$$;

-- ------------------------------------------------------------ privileges
revoke all on function app_private.tg_transfers_guard() from public;
revoke all on function app_private.transfer_figures(uuid, uuid, uuid, numeric, numeric, numeric, numeric, numeric) from public;
revoke all on function app_private.fee_expense_account(uuid) from public;
revoke all on function app_private.confirm_transfer_core(uuid) from public;
revoke all on function app_private.assert_transfer_approver(uuid) from public;

revoke all on function public.create_transfer(uuid, text, uuid, uuid, date, numeric, numeric, numeric, numeric, numeric, text, text, boolean) from public, anon;
revoke all on function public.confirm_transfer(uuid, text) from public, anon;
revoke all on function public.cancel_transfer(uuid, text) from public, anon;
revoke all on function public.reverse_transfer(uuid, text, date, text) from public, anon;
grant execute on function public.create_transfer(uuid, text, uuid, uuid, date, numeric, numeric, numeric, numeric, numeric, text, text, boolean) to authenticated;
grant execute on function public.confirm_transfer(uuid, text) to authenticated;
grant execute on function public.cancel_transfer(uuid, text) to authenticated;
grant execute on function public.reverse_transfer(uuid, text, date, text) to authenticated;
