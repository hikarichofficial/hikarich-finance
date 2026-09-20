-- P4 (Step 15 §8): financial accounts and the authoritative money-movement layer.
-- Authority: Step 02 §4 (payments and money movements), Step 03 §7 (financial account -> COA mapping),
-- Step 04 §5 and §13 (cash/bank, derived balances), Step 08 §9 (payment/transfer integrity), Step 09 §13.
--
-- Model
--   * A financial account (bank / cash / e-wallet) is a real balance holder mapped one-to-one to a control
--     asset account of the same Entity. Its balance is DERIVED from money movements; nobody types a balance.
--   * A money movement is an immutable fact: money came in or went out of exactly one financial account, in
--     the account's own currency, with the base-currency value that its journal booked. Movements are
--     written only by trusted server code, in the same transaction as the journal that explains them.
--   * The journal is the accounting consequence, the movement is the cash consequence (Step 02 §5). The two
--     must agree: `money_control` compares them and period close refuses a mismatch (see P4 reconciliation).
--   * Corrections never edit a movement: a reversal is a new movement linked to the one it undoes.

-- ------------------------------------------------------------ composite key for currency-safe references
-- A movement can only reference a financial account together with that account's currency, so a movement can
-- never carry a different currency than its account.
alter table public.financial_accounts
  add constraint financial_accounts_entity_id_currency_key unique (entity_id, id, currency);

-- ------------------------------------------------------------ money movements
create table public.money_movements (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  financial_account_id uuid not null,
  currency public.currency_code not null,
  direction text not null check (direction in ('in', 'out')),
  -- Amount in the account's own currency, and the base-currency value booked by the journal.
  amount public.money_amount not null check (amount > 0),
  base_amount public.money_amount not null check (base_amount > 0),
  exchange_rate public.fx_rate,
  movement_date date not null,
  -- The economic event that caused the movement (a transfer, an adjustment, later a payment or refund).
  source_type text not null check (source_type ~ '^[a-z][a-z0-9_]*$'),
  source_id uuid not null,
  component text not null default 'principal' check (component in ('principal', 'fee', 'opening', 'adjustment')),
  journal_id uuid not null,
  reverses_movement_id uuid,
  description text,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  foreign key (entity_id, financial_account_id, currency)
    references public.financial_accounts (entity_id, id, currency) on delete restrict,
  foreign key (entity_id, journal_id) references public.journal_entries (entity_id, id) on delete restrict,
  foreign key (entity_id, reverses_movement_id) references public.money_movements (entity_id, id) on delete restrict,
  check (reverses_movement_id is null or reverses_movement_id <> id)
);
-- A movement can be reversed at most once.
create unique index money_movements_one_reversal_uq
  on public.money_movements (reverses_movement_id) where reverses_movement_id is not null;
create index money_movements_account_idx
  on public.money_movements (entity_id, financial_account_id, movement_date, created_at, id);
create index money_movements_source_idx on public.money_movements (entity_id, source_type, source_id);
create index money_movements_journal_idx on public.money_movements (entity_id, journal_id);

create trigger tg_forbid_update before update on public.money_movements
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.money_movements
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.money_movements
  for each statement execute function app_private.tg_forbid_truncate();
create trigger tg_stamp_created before insert on public.money_movements
  for each row execute function app_private.tg_stamp_created();
call app_private.secure_table('public.money_movements');

-- Reconciliation (added later in this phase) locks matched movements against reversal; until that table exists
-- nothing is matched. The function is replaced by the reconciliation migration.
create function app_private.movement_is_matched(p_movement uuid) returns boolean
language sql stable as $$ select false $$;

-- Hard invariants of a movement, checked for every writer (Step 08 §9): the amounts follow the currency rules,
-- the journal is a posted journal of the same Entity and date, and the journal really booked this movement on
-- the account's ledger account. A movement can therefore never exist without its accounting consequence.
create function app_private.tg_money_movements_guard() returns trigger
language plpgsql as $$
declare
  v_base public.currency_code;
  v_base_scale integer;
  v_scale integer;
  v_j public.journal_entries%rowtype;
  v_ledger uuid;
  v_booked numeric;
  v_used numeric;
  v_orig public.money_movements%rowtype;
begin
  select e.base_currency into v_base from public.entities e where e.id = new.entity_id;
  v_base_scale := app_private.currency_scale(v_base);
  v_scale := app_private.currency_scale(new.currency);

  if not app_private.is_finite(new.amount) or new.amount >= 10::numeric ^ 16
     or app_private.round_amount(new.amount, v_scale, 'down') <> new.amount then
    raise exception 'INVALID: the amount allows % decimals for %', v_scale, new.currency
      using errcode = 'invalid_parameter_value';
  end if;
  if new.base_amount >= 10::numeric ^ 16
     or app_private.round_amount(new.base_amount, v_base_scale, 'down') <> new.base_amount then
    raise exception 'INVALID: the base amount allows % decimals for %', v_base_scale, v_base
      using errcode = 'invalid_parameter_value';
  end if;
  if new.currency = v_base then
    if new.exchange_rate is not null or new.base_amount <> new.amount then
      raise exception 'INVALID: a base-currency movement has no rate and its base amount equals its amount'
        using errcode = 'invalid_parameter_value';
    end if;
  else
    if new.exchange_rate is null
       or app_private.round_amount(new.amount * new.exchange_rate, v_base_scale, 'half_up') <> new.base_amount then
      raise exception 'INVALID: the base amount must equal amount x rate for a foreign-currency movement'
        using errcode = 'invalid_parameter_value';
    end if;
  end if;

  select * into v_j from public.journal_entries where id = new.journal_id and entity_id = new.entity_id;
  if not found or v_j.status <> 'posted' then
    raise exception 'INVALID: a money movement needs a posted journal of the same Entity'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_j.entry_date <> new.movement_date then
    raise exception 'INVALID: the movement date must equal the date of its journal'
      using errcode = 'invalid_parameter_value';
  end if;

  select fa.ledger_account_id into v_ledger
  from public.financial_accounts fa where fa.id = new.financial_account_id and fa.entity_id = new.entity_id;
  -- The journal must have booked at least what the movements of that side of that account add up to.
  select coalesce(sum(case new.direction when 'in' then l.debit else l.credit end), 0) into v_booked
  from public.journal_lines l
  where l.journal_id = new.journal_id and l.ledger_account_id = v_ledger;
  select coalesce(sum(m.base_amount), 0) into v_used
  from public.money_movements m
  where m.journal_id = new.journal_id and m.financial_account_id = new.financial_account_id
    and m.direction = new.direction;
  if v_used + new.base_amount > v_booked then
    raise exception 'INVALID: the journal did not book % on this financial account for the movement(s)', new.base_amount
      using errcode = 'invalid_parameter_value';
  end if;

  if new.reverses_movement_id is not null then
    -- FOR SHARE waits for a concurrent match (which holds the movement FOR UPDATE) and then sees its result.
    select * into v_orig from public.money_movements
    where id = new.reverses_movement_id and entity_id = new.entity_id for share;
    if not found
       or v_orig.financial_account_id <> new.financial_account_id
       or v_orig.direction = new.direction
       or v_orig.amount <> new.amount or v_orig.base_amount <> new.base_amount
       or v_orig.component <> new.component then
      raise exception 'INVALID: a reversal movement mirrors the movement it reverses'
        using errcode = 'invalid_parameter_value';
    end if;
    if v_j.reverses_journal_id is distinct from v_orig.journal_id then
      raise exception 'INVALID: a reversal movement belongs to the reversal journal of the original'
        using errcode = 'invalid_parameter_value';
    end if;
    if app_private.movement_is_matched(new.reverses_movement_id) then
      raise exception 'CONFLICT: the movement is matched to a bank statement line; unmatch it first'
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before insert on public.money_movements
  for each row execute function app_private.tg_money_movements_guard();

-- Browser roles read movements (RLS by capability); nothing writes them except trusted server code.
call app_private.expose_select('public.money_movements');
create policy money_movements_select on public.money_movements for select to authenticated
  using (app_authz.has_permission(entity_id, 'money.view'));

-- ------------------------------------------------------------ balances derived from movements
-- Balance of an account in ITS OWN currency: money in minus money out, up to an optional date.
create function app_private.account_balance(p_account uuid, p_as_of date default null) returns numeric
language sql stable as $$
  select coalesce(sum(case m.direction when 'in' then m.amount else -m.amount end), 0)
  from public.money_movements m
  where m.financial_account_id = p_account and (p_as_of is null or m.movement_date <= p_as_of)
$$;

-- The single writer of movements. Locks the account (so a negative-balance policy cannot be raced), applies
-- the Entity's optional hard block on negative balances, and inserts. All value checks live in the guard trigger.
create function app_private.record_movement(
  p_entity uuid, p_account uuid, p_direction text, p_amount numeric, p_base_amount numeric, p_rate numeric,
  p_date date, p_source_type text, p_source_id uuid, p_component text, p_journal uuid,
  p_description text default null, p_reverses uuid default null, p_id uuid default null)
returns uuid
language plpgsql as $$
declare
  v_fa public.financial_accounts%rowtype;
  v_id uuid;
  v_block boolean;
begin
  select * into v_fa from public.financial_accounts
  where id = p_account and entity_id = p_entity for no key update;
  if not found then
    raise exception 'INVALID: unknown financial account of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  if not v_fa.is_active and p_reverses is null then
    raise exception 'CONFLICT: financial account % is inactive and cannot receive new movements', v_fa.name
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_direction not in ('in', 'out') or p_amount is null or p_amount <= 0 then
    raise exception 'INVALID: a movement needs a direction and a positive amount' using errcode = 'invalid_parameter_value';
  end if;

  -- Cash balance warnings are always available; hard blocking is configured per Entity as the list of account
  -- kinds that may never go negative, e.g. ["cash"] (Step 08 §9).
  if p_direction = 'out' then
    select coalesce((select s.setting_value ? v_fa.kind
                     from public.entity_settings s
                     where s.entity_id = p_entity and s.setting_key = 'money.block_negative_balance'), false)
      into v_block;
    if v_block and app_private.account_balance(p_account) - p_amount < 0 then
      raise exception 'CONFLICT: this would take % below zero, which is blocked for % accounts', v_fa.name, v_fa.kind
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;

  insert into public.money_movements
    (id, entity_id, financial_account_id, currency, direction, amount, base_amount, exchange_rate, movement_date,
     source_type, source_id, component, journal_id, reverses_movement_id, description)
  values
    (coalesce(p_id, gen_random_uuid()), p_entity, p_account, v_fa.currency, p_direction, p_amount, p_base_amount,
     p_rate, p_date, p_source_type, p_source_id, p_component, p_journal, p_reverses,
     nullif(btrim(coalesce(p_description, '')), ''))
  returning id into v_id;
  return v_id;
end
$$;

-- ------------------------------------------------------------ ledger control
-- Movement balance against the General Ledger balance of the mapped account (Step 04 §13). A non-zero
-- difference means a posting touched the account without its money movement, or the reverse.
create function app_private.money_control_rows(p_entity uuid, p_as_of date default null)
returns table (
  financial_account_id uuid, name text, kind text, currency text, is_active boolean,
  movement_balance numeric, movement_base_balance numeric, ledger_balance numeric)
language sql stable as $$
  select fa.id, fa.name, fa.kind, fa.currency::text, fa.is_active,
         coalesce(mv.bal, 0), coalesce(mv.base_bal, 0), coalesce(gl.bal, 0)
  from public.financial_accounts fa
  left join lateral (
    select sum(case m.direction when 'in' then m.amount else -m.amount end) as bal,
           sum(case m.direction when 'in' then m.base_amount else -m.base_amount end) as base_bal
    from public.money_movements m
    where m.financial_account_id = fa.id and (p_as_of is null or m.movement_date <= p_as_of)
  ) mv on true
  left join lateral (
    select sum(l.debit - l.credit) as bal
    from public.journal_lines l
    join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id
    where l.entity_id = fa.entity_id and l.ledger_account_id = fa.ledger_account_id
      and j.status = 'posted' and (p_as_of is null or j.entry_date <= p_as_of)
  ) gl on true
  where fa.entity_id = p_entity
$$;

create function public.money_control(p_entity uuid, p_as_of date default null)
returns table (
  financial_account_id uuid, name text, kind text, currency text, is_active boolean,
  movement_balance text, movement_base_balance text, ledger_balance text, difference text,
  is_negative boolean)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'money.view') then
    raise exception 'FORBIDDEN: missing money.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select r.financial_account_id, r.name, r.kind, r.currency, r.is_active,
         r.movement_balance::text, r.movement_base_balance::text, r.ledger_balance::text,
         (r.ledger_balance - r.movement_base_balance)::text,
         r.movement_balance < 0
  from app_private.money_control_rows(p_entity, p_as_of) r
  order by r.name;
end
$$;

-- Bank-ledger view of one account: newest first, with the running balance in the account's currency.
create function public.account_activity(
  p_account uuid, p_from date default null, p_to date default null, p_limit integer default 200)
returns table (
  movement_id uuid, movement_date date, direction text, amount text, currency text, base_amount text,
  running_balance text, source_type text, source_id uuid, component text, description text,
  journal_id uuid, journal_number text, reverses_movement_id uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select entity_id into v_entity from public.financial_accounts where id = p_account;
  if v_entity is null or not app_authz.has_permission(v_entity, 'money.view') then
    raise exception 'FORBIDDEN: missing money.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select q.id, q.movement_date, q.direction, q.amount::text, q.currency::text, q.base_amount::text,
         q.running::text, q.source_type, q.source_id, q.component, q.description,
         q.journal_id, q.journal_number, q.reverses_movement_id
  from (
    select m.id, m.movement_date, m.direction, m.amount, m.currency, m.base_amount,
           sum(case m.direction when 'in' then m.amount else -m.amount end)
             over (order by m.movement_date, m.created_at, m.id) as running,
           m.source_type, m.source_id, m.component, m.description, m.journal_id, j.journal_number,
           m.reverses_movement_id, m.created_at
    from public.money_movements m
    join public.journal_entries j on j.id = m.journal_id
    where m.financial_account_id = p_account
  ) q
  where (p_from is null or q.movement_date >= p_from) and (p_to is null or q.movement_date <= p_to)
  order by q.movement_date desc, q.created_at desc, q.id desc
  limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end
$$;

-- ------------------------------------------------------------ financial account commands
-- Ledger accounts that may back a financial account: the cash/bank control accounts (by stable system key) or a
-- child of the same cash group (Step 03 §7). Anything else - AR, AP, fixed assets, ... - is refused.
create function app_private.is_cash_ledger_account(p_entity uuid, p_account uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.ledger_accounts a
    where a.id = p_account and a.entity_id = p_entity and a.account_class = 'asset' and not a.is_group
      and (a.system_key in ('CASH', 'BANK_OPERATING', 'PERSONAL_BANK', 'OTHER_CASH_ACCOUNT')
           or (a.system_key is null and a.parent_id is not null
               and a.parent_id = (select c.parent_id from public.ledger_accounts c
                                  where c.entity_id = p_entity and c.system_key = 'CASH'))))
$$;

create function public.create_financial_account(
  p_entity uuid, p_key text, p_kind text, p_name text, p_currency text,
  p_ledger_account uuid default null, p_institution text default null,
  p_account_number text default null, p_holder text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_replay uuid;
  v_ledger uuid := p_ledger_account;
  v_id uuid;
  v_parent uuid;
  v_lo integer;
  v_hi integer;
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'money.edit') then
    raise exception 'FORBIDDEN: missing money.edit' using errcode = 'insufficient_privilege';
  end if;
  if p_ledger_account is null and not app_authz.has_permission(p_entity, 'coa.manage') then
    raise exception 'FORBIDDEN: creating the ledger account needs coa.manage; map an existing one instead'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_kind, '') not in ('bank', 'cash', 'ewallet') or length(v_name) = 0 then
    raise exception 'INVALID: kind must be bank, cash or ewallet and a name is required'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_currency is null or not exists (select 1 from public.currencies where code = p_currency) then
    raise exception 'INVALID: unknown currency' using errcode = 'invalid_parameter_value';
  end if;

  v_replay := app_private.idem_begin('financial_account.create', p_entity, p_key,
    md5(jsonb_build_object('kind', p_kind, 'name', v_name, 'currency', p_currency, 'ledger', p_ledger_account,
                           'institution', p_institution, 'number', p_account_number, 'holder', p_holder)::text));
  if v_replay is not null then
    return v_replay;
  end if;

  if v_ledger is not null then
    if not app_private.is_cash_ledger_account(p_entity, v_ledger)
       or not exists (select 1 from public.ledger_accounts where id = v_ledger and status = 'active') then
      raise exception 'INVALID: the ledger account must be an active cash/bank account of this Entity'
        using errcode = 'invalid_parameter_value';
    end if;
    if exists (select 1 from public.financial_accounts where ledger_account_id = v_ledger) then
      raise exception 'CONFLICT: that ledger account already backs another financial account'
        using errcode = 'integrity_constraint_violation';
    end if;
    -- Postings that exist before the money layer cannot be adopted: the movements would never explain them.
    if exists (select 1 from public.journal_lines where ledger_account_id = v_ledger) then
      raise exception 'CONFLICT: that ledger account already carries postings and cannot be mapped to a financial account'
        using errcode = 'integrity_constraint_violation';
    end if;
  else
    -- Step 03 §7: the system creates and maps an appropriate child ledger account under the cash group.
    perform pg_advisory_xact_lock(hashtextextended('coa-code:' || p_entity::text, 0));
    select c.parent_id into v_parent from public.ledger_accounts c
    where c.entity_id = p_entity and c.system_key = 'CASH';
    if v_parent is null then
      raise exception 'CONFLICT: this Entity has no cash account group to place the new account in'
        using errcode = 'integrity_constraint_violation';
    end if;
    v_lo := case p_kind when 'cash' then 1111 when 'bank' then 1121 else 1191 end;
    v_hi := case p_kind when 'cash' then 1119 when 'bank' then 1189 else 1199 end;
    select g::text into v_code
    from generate_series(v_lo, v_hi) g
    where not exists (select 1 from public.ledger_accounts a where a.entity_id = p_entity and a.code = g::text)
    order by g limit 1;
    if v_code is null then
      raise exception 'CONFLICT: no free ledger account code is left for this kind of account'
        using errcode = 'integrity_constraint_violation';
    end if;
    insert into public.ledger_accounts
      (entity_id, code, name, account_class, normal_balance, parent_id, is_control, allows_manual_posting)
    values (p_entity, v_code, v_name, 'asset', 'debit', v_parent, true, false)
    returning id into v_ledger;
  end if;

  begin
    insert into public.financial_accounts
      (entity_id, kind, name, institution_name, account_number, account_holder, currency, ledger_account_id)
    values (p_entity, p_kind, v_name, nullif(btrim(coalesce(p_institution, '')), ''),
            nullif(btrim(coalesce(p_account_number, '')), ''), nullif(btrim(coalesce(p_holder, '')), ''),
            p_currency, v_ledger)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'CONFLICT: a financial account with this name already exists' using errcode = 'integrity_constraint_violation';
  end;

  perform app_private.idem_complete('financial_account.create', p_entity, p_key, 'financial_accounts', v_id);
  return v_id;
end
$$;

-- Name, institution, holder and number can be edited; kind, currency and ledger mapping are fixed at creation.
-- `p_patch` holds only the keys to change; a null or empty value clears an optional field.
create function public.update_financial_account(p_account uuid, p_patch jsonb, p_expected_version integer default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_fa public.financial_accounts%rowtype;
  v_key text;
  v_name text;
  v_version integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_fa from public.financial_accounts where id = p_account;
  if not found or not app_authz.has_permission(v_fa.entity_id, 'money.edit') then
    raise exception 'FORBIDDEN: missing money.edit' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p_patch) is distinct from 'object' or p_patch = '{}'::jsonb then
    raise exception 'INVALID: nothing to change' using errcode = 'invalid_parameter_value';
  end if;
  for v_key in select jsonb_object_keys(p_patch) loop
    if v_key not in ('name', 'institution_name', 'account_holder', 'account_number') then
      raise exception 'INVALID: % cannot be changed on a financial account', v_key using errcode = 'invalid_parameter_value';
    end if;
  end loop;

  select * into v_fa from public.financial_accounts where id = p_account for update;
  if p_expected_version is not null and v_fa.version <> p_expected_version then
    raise exception 'CONFLICT: the account was changed by someone else (stale version)'
      using errcode = 'integrity_constraint_violation';
  end if;
  v_name := case when p_patch ? 'name' then btrim(coalesce(p_patch ->> 'name', '')) else v_fa.name end;
  if length(v_name) = 0 then
    raise exception 'INVALID: a name is required' using errcode = 'invalid_parameter_value';
  end if;
  begin
    update public.financial_accounts set
      name = v_name,
      institution_name = case when p_patch ? 'institution_name'
        then nullif(btrim(coalesce(p_patch ->> 'institution_name', '')), '') else institution_name end,
      account_holder = case when p_patch ? 'account_holder'
        then nullif(btrim(coalesce(p_patch ->> 'account_holder', '')), '') else account_holder end,
      account_number = case when p_patch ? 'account_number'
        then nullif(btrim(coalesce(p_patch ->> 'account_number', '')), '') else account_number end
    where id = p_account
    returning version into v_version;
  exception when unique_violation then
    raise exception 'CONFLICT: a financial account with this name already exists' using errcode = 'integrity_constraint_violation';
  end;
  return v_version;
end
$$;

-- Accounts with history are disabled, never deleted (Step 03 §1). An account can only be disabled once it holds
-- no money, so no balance is left on an account that can no longer be used.
create function public.set_financial_account_active(p_account uuid, p_active boolean, p_reason text default null)
returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_fa public.financial_accounts%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_fa from public.financial_accounts where id = p_account;
  if not found or not app_authz.has_permission(v_fa.entity_id, 'money.edit') then
    raise exception 'FORBIDDEN: missing money.edit' using errcode = 'insufficient_privilege';
  end if;
  if p_active is null then
    raise exception 'INVALID: active or inactive is required' using errcode = 'invalid_parameter_value';
  end if;
  select * into v_fa from public.financial_accounts where id = p_account for no key update;
  if v_fa.is_active = p_active then
    return p_active;
  end if;
  if not p_active then
    if v_reason is null or length(v_reason) < 5 then
      raise exception 'INVALID: a reason of at least 5 characters is required to disable an account'
        using errcode = 'invalid_parameter_value';
    end if;
    if app_private.account_balance(p_account) <> 0 then
      raise exception 'CONFLICT: the account still holds a balance; move it out before disabling'
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  perform set_config('app.audit_reason', coalesce(v_reason, 'Financial account re-enabled'), true);
  update public.financial_accounts set is_active = p_active where id = p_account;
  return p_active;
end
$$;

-- ------------------------------------------------------------ balance adjustment (Step 09 §13)
-- "Users cannot type over an account balance": a correction of the money side is its own explicit event with a
-- reason, and the accounting treatment (the counter account) is chosen deliberately. It never edits history.
create function public.record_balance_adjustment(
  p_entity uuid, p_key text, p_account uuid, p_direction text, p_amount numeric, p_rate numeric,
  p_date date, p_counter_account uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_reason text := btrim(coalesce(p_reason, ''));
  v_fa public.financial_accounts%rowtype;
  v_counter public.ledger_accounts%rowtype;
  v_base public.currency_code;
  v_base_amount numeric;
  v_replay uuid;
  v_id uuid := gen_random_uuid();
  v_lines jsonb;
  v_journal uuid;
  v_orig jsonb := '{}'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'money.adjust') then
    raise exception 'FORBIDDEN: missing money.adjust' using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) < 10 then
    raise exception 'INVALID: an adjustment needs a reason of at least 10 characters'
      using errcode = 'invalid_parameter_value';
  end if;
  if coalesce(p_direction, '') not in ('in', 'out') or p_amount is null or not app_private.is_finite(p_amount)
     or p_amount <= 0 or p_amount >= 10::numeric ^ 16 then
    raise exception 'INVALID: direction and a positive amount are required' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);

  v_replay := app_private.idem_begin('balance_adjustment.create', p_entity, p_key,
    md5(jsonb_build_object('account', p_account, 'dir', p_direction, 'amount', p_amount, 'rate', p_rate,
                           'date', p_date, 'counter', p_counter_account, 'reason', v_reason)::text));
  if v_replay is not null then
    return v_replay;
  end if;

  -- Same lock order as a transfer (account first, journal number second), so the two can never deadlock.
  select * into v_fa from public.financial_accounts where id = p_account and entity_id = p_entity for no key update;
  if not found then
    raise exception 'INVALID: unknown financial account of this Entity' using errcode = 'invalid_parameter_value';
  end if;
  select * into v_counter from public.ledger_accounts where id = p_counter_account and entity_id = p_entity;
  if not found or v_counter.status <> 'active' or v_counter.is_group or v_counter.is_control
     or v_counter.system_key = 'OPENING_BALANCE_CLEARING' then
    raise exception 'INVALID: the counter account must be an active, non-control account of this Entity'
      using errcode = 'invalid_parameter_value';
  end if;

  select base_currency into v_base from public.entities where id = p_entity;
  if v_fa.currency = v_base then
    if p_rate is not null then
      raise exception 'INVALID: a base-currency account takes no exchange rate' using errcode = 'invalid_parameter_value';
    end if;
    v_base_amount := p_amount;
  else
    if p_rate is null or not app_private.is_finite(p_rate) or p_rate <= 0 then
      raise exception 'INVALID: a foreign-currency account needs a positive exchange rate' using errcode = 'invalid_parameter_value';
    end if;
    v_base_amount := app_private.convert_amount(p_amount, p_rate, v_base);
    v_orig := jsonb_build_object('original_currency', v_fa.currency, 'original_amount', p_amount, 'exchange_rate', p_rate);
  end if;
  if v_base_amount <= 0 then
    raise exception 'INVALID: the amount is too small to book in %', v_base using errcode = 'invalid_parameter_value';
  end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id', v_fa.ledger_account_id, 'description', 'Balance adjustment: ' || v_reason,
                       'debit', case p_direction when 'in' then v_base_amount else 0 end,
                       'credit', case p_direction when 'out' then v_base_amount else 0 end) || v_orig,
    jsonb_build_object('account_id', p_counter_account, 'description', 'Balance adjustment: ' || v_reason,
                       'debit', case p_direction when 'out' then v_base_amount else 0 end,
                       'credit', case p_direction when 'in' then v_base_amount else 0 end));

  perform set_config('app.audit_reason', v_reason, true);
  v_journal := app_private.post_system_journal(
    p_entity, 'money_adjustment', v_id, 'money.adjustment.v1', 'money.adjustment.v1', p_date,
    'Balance adjustment - ' || v_fa.name || ': ' || v_reason, v_lines);
  perform app_private.record_movement(
    p_entity, p_account, p_direction, p_amount, v_base_amount, p_rate, p_date, 'money_adjustment', v_id,
    'adjustment', v_journal, v_reason, null, v_id);

  perform app_private.idem_complete('balance_adjustment.create', p_entity, p_key, 'money_movements', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ opening balances create their movements
-- Same command as P3, hardened: every opening line on a cash/bank account now also creates the opening
-- movement, in the account's own currency, so migrated balances are part of the derived balance from day one
-- (Step 15 §24). Foreign-currency accounts must carry the original amount and rate on the line.
create or replace function public.post_opening_balances(
  p_entity uuid, p_key text, p_cutover date, p_lines jsonb, p_note text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_replay uuid;
  v_diff numeric;
  v_lines jsonb;
  v_batch uuid := gen_random_uuid();
  v_bad text;
  v_clearing_lines integer;
  v_expected_clearing integer;
  v_base public.currency_code;
  v_journal uuid;
  r record;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'system.import') then
    raise exception 'FORBIDDEN: missing system.import' using errcode = 'insufficient_privilege';
  end if;
  perform app_private.assert_business_date(p_cutover);
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) < 1 then
    raise exception 'INVALID: opening lines are required' using errcode = 'invalid_parameter_value';
  end if;

  v_replay := app_private.idem_begin('opening.post', p_entity, p_key,
    md5(jsonb_build_object('cutover', p_cutover, 'lines', p_lines, 'note', v_note)::text));
  if v_replay is not null then
    return v_replay;
  end if;

  -- Opening postings and completion of one Entity never run at the same time.
  perform pg_advisory_xact_lock(hashtextextended('opening:' || p_entity::text, 0));
  if exists (select 1 from public.opening_balance_batches where entity_id = p_entity and status = 'completed') then
    raise exception 'CONFLICT: the opening balances of this Entity are already completed' using errcode = 'integrity_constraint_violation';
  end if;
  perform app_private.assert_period_postable(p_entity, p_cutover);

  begin
    select coalesce(sum(coalesce(nullif(l ->> 'debit', '')::numeric, 0) - coalesce(nullif(l ->> 'credit', '')::numeric, 0)), 0)
      into v_diff
    from jsonb_array_elements(p_lines) l;
  exception when invalid_text_representation or numeric_value_out_of_range or invalid_parameter_value then
    raise exception 'INVALID: opening line amounts must be plain numbers' using errcode = 'invalid_parameter_value';
  end;

  v_lines := p_lines;
  if v_diff <> 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_key', 'OPENING_BALANCE_CLEARING',
      'debit', case when v_diff < 0 then -v_diff else 0 end,
      'credit', case when v_diff > 0 then v_diff else 0 end,
      'description', 'Opening balance clearing'));
  end if;
  v_lines := app_private.normalise_lines(p_entity, v_lines);

  -- Only balance-sheet accounts (and the clearing account we add ourselves) may carry opening balances.
  select string_agg(distinct a.code, ', ') into v_bad
  from jsonb_array_elements(v_lines) l
  join public.ledger_accounts a on a.id = (l ->> 'account_id')::uuid
  where a.account_class not in ('asset', 'contra_asset', 'liability', 'equity')
    and a.system_key is distinct from 'OPENING_BALANCE_CLEARING';
  if v_bad is not null then
    raise exception 'INVALID: opening balances may only use balance-sheet accounts (not %)', v_bad
      using errcode = 'invalid_parameter_value';
  end if;
  -- The clearing account is maintained by the workflow. Judged on the normalised lines, so no spelling of an
  -- identifier (case, braces, ...) can smuggle it in: it may appear exactly once, and only as our own line.
  select count(*) into v_clearing_lines
  from jsonb_array_elements(v_lines) l
  join public.ledger_accounts a on a.id = (l ->> 'account_id')::uuid
  where a.system_key = 'OPENING_BALANCE_CLEARING';
  v_expected_clearing := case when v_diff <> 0 then 1 else 0 end;
  if v_clearing_lines <> v_expected_clearing then
    raise exception 'INVALID: the clearing account is maintained by the workflow and cannot be entered directly'
      using errcode = 'invalid_parameter_value';
  end if;

  -- Cash/bank lines need their movement: refuse early, with a clear message, what cannot produce one.
  select base_currency into v_base from public.entities where id = p_entity;
  for r in
    select fa.name, fa.currency, fa.is_active, l.value as line
    from jsonb_array_elements(v_lines) l
    join public.financial_accounts fa on fa.ledger_account_id = (l.value ->> 'account_id')::uuid
                                     and fa.entity_id = p_entity
  loop
    if not r.is_active then
      raise exception 'INVALID: financial account % is inactive and cannot receive an opening balance', r.name
        using errcode = 'invalid_parameter_value';
    end if;
    if r.currency <> v_base and (r.line ->> 'original_currency' is distinct from r.currency::text
                                 or r.line ->> 'original_amount' is null) then
      raise exception 'INVALID: the opening line of % must state its original % amount and rate', r.name, r.currency
        using errcode = 'invalid_parameter_value';
    end if;
  end loop;

  perform 1 from public.financial_accounts fa
  where fa.entity_id = p_entity
    and fa.ledger_account_id in (select (l.value ->> 'account_id')::uuid from jsonb_array_elements(v_lines) l)
  order by fa.id for no key update;

  insert into public.opening_balance_batches (id, entity_id, cutover_date, note)
  values (v_batch, p_entity, p_cutover, v_note);

  v_journal := app_private.post_system_journal(
    p_entity, 'opening_balance', v_batch, 'opening.v1', 'opening.v1', p_cutover,
    coalesce(v_note, 'Opening balances at ' || p_cutover::text), v_lines, 'opening');

  for r in
    select fa.id as account_id, fa.currency, l.debit, l.credit, l.original_amount, l.exchange_rate
    from public.journal_lines l
    join public.financial_accounts fa on fa.ledger_account_id = l.ledger_account_id and fa.entity_id = l.entity_id
    where l.journal_id = v_journal
    order by l.line_no
  loop
    perform app_private.record_movement(
      p_entity, r.account_id, case when r.debit > 0 then 'in' else 'out' end,
      case when r.currency = v_base then greatest(r.debit, r.credit) else r.original_amount end,
      greatest(r.debit, r.credit),
      case when r.currency = v_base then null else r.exchange_rate end,
      p_cutover, 'opening_balance', v_batch, 'opening', v_journal, 'Opening balance');
  end loop;

  perform app_private.idem_complete('opening.post', p_entity, p_key, 'opening_balance_batches', v_batch);
  return v_batch;
end
$$;

-- ------------------------------------------------------------ privileges
revoke all on function app_private.movement_is_matched(uuid) from public;
revoke all on function app_private.tg_money_movements_guard() from public;
revoke all on function app_private.account_balance(uuid, date) from public;
revoke all on function app_private.record_movement(uuid, uuid, text, numeric, numeric, numeric, date, text, uuid, text, uuid, text, uuid, uuid) from public;
revoke all on function app_private.money_control_rows(uuid, date) from public;
revoke all on function app_private.is_cash_ledger_account(uuid, uuid) from public;

revoke all on function public.money_control(uuid, date) from public, anon;
revoke all on function public.account_activity(uuid, date, date, integer) from public, anon;
revoke all on function public.create_financial_account(uuid, text, text, text, text, uuid, text, text, text) from public, anon;
revoke all on function public.update_financial_account(uuid, jsonb, integer) from public, anon;
revoke all on function public.set_financial_account_active(uuid, boolean, text) from public, anon;
revoke all on function public.record_balance_adjustment(uuid, text, uuid, text, numeric, numeric, date, uuid, text) from public, anon;
revoke all on function public.post_opening_balances(uuid, text, date, jsonb, text) from public, anon;
grant execute on function public.money_control(uuid, date) to authenticated;
grant execute on function public.account_activity(uuid, date, date, integer) to authenticated;
grant execute on function public.create_financial_account(uuid, text, text, text, text, uuid, text, text, text) to authenticated;
grant execute on function public.update_financial_account(uuid, jsonb, integer) to authenticated;
grant execute on function public.set_financial_account_active(uuid, boolean, text) to authenticated;
grant execute on function public.record_balance_adjustment(uuid, text, uuid, text, numeric, numeric, date, uuid, text) to authenticated;
grant execute on function public.post_opening_balances(uuid, text, date, jsonb, text) to authenticated;
