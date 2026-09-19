-- P1 (Step 15 §5 "master records"): financial accounts, payment channels and category → COA mappings.
-- Authority: Step 02 §4 (Financial Accounts & Master Data), Step 03 §6/§7, Step 04 §14.
-- Balances are never stored here: they are derived from posted journal lines (Step 03).

-- ------------------------------------------------------------ financial accounts (Step 03 §7)
-- Every real bank/cash/e-wallet balance account maps to exactly one ledger asset account of the same
-- Entity (composite FK) and each ledger account backs at most one financial account (UNIQUE).
create table public.financial_accounts (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  kind text not null check (kind in ('bank', 'cash', 'ewallet')),
  name text not null check (length(btrim(name)) > 0),
  institution_name text,
  account_number text,
  account_holder text,
  currency public.currency_code not null references public.currencies (code),
  ledger_account_id uuid not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (ledger_account_id),
  unique (entity_id, name),
  foreign key (entity_id, ledger_account_id) references public.ledger_accounts (entity_id, id) on delete restrict
);

create function app_private.tg_financial_accounts_guard() returns trigger
language plpgsql as $$
declare
  v_acc public.ledger_accounts%rowtype;
begin
  select * into v_acc from public.ledger_accounts
  where entity_id = new.entity_id and id = new.ledger_account_id;
  if v_acc.account_class <> 'asset' or v_acc.is_group then
    raise exception 'Financial account % must map to a non-group asset ledger account (Step 03 §7)', new.name
      using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE' then
    -- Currency and ledger mapping are fixed once the account is used in a posted journal.
    if (new.currency is distinct from old.currency or new.ledger_account_id is distinct from old.ledger_account_id)
       and exists (
         select 1 from public.journal_lines jl
         where jl.entity_id = old.entity_id and jl.ledger_account_id = old.ledger_account_id limit 1) then
      raise exception 'Currency/ledger mapping of financial account % cannot change once it has postings', old.name
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_guard before insert or update on public.financial_accounts
  for each row execute function app_private.tg_financial_accounts_guard();
call app_private.apply_standard_triggers('public.financial_accounts');
call app_private.secure_table('public.financial_accounts');
-- Account numbers are sensitive (Step 06 §6): never copied into audit snapshots.
create trigger tg_audit after insert or update or delete on public.financial_accounts
  for each row execute function app_private.tg_audit('entity_id', 'account_number');

-- ------------------------------------------------------------ payment channels
-- QRIS and similar channels are not balances: they point at the settlement account (Step 03 §7).
create table public.payment_channels (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  method_kind text not null check (method_kind in ('bank_transfer', 'cash', 'qris', 'ewallet', 'card', 'other')),
  name text not null check (length(btrim(name)) > 0),
  settlement_financial_account_id uuid,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (entity_id, name),
  foreign key (entity_id, settlement_financial_account_id)
    references public.financial_accounts (entity_id, id) on delete restrict
);
call app_private.apply_standard_triggers('public.payment_channels');
call app_private.secure_table('public.payment_channels');
create trigger tg_audit after insert or update or delete on public.payment_channels
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ category → COA mapping (Step 03 §6)
-- Operational category vs accounting classification. Effective-dated so history is never
-- reinterpreted; tax treatment is NOT derived from this table.
create table public.category_account_mappings (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  category_id uuid not null,
  context text not null default 'default' check (context ~ '^[a-z][a-z0-9_]{1,40}$'),
  debit_ledger_account_id uuid,
  credit_ledger_account_id uuid,
  effective_from date not null,
  effective_to date,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, category_id) references public.categories (entity_id, id) on delete restrict,
  foreign key (entity_id, debit_ledger_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  foreign key (entity_id, credit_ledger_account_id) references public.ledger_accounts (entity_id, id) on delete restrict,
  check (debit_ledger_account_id is not null or credit_ledger_account_id is not null),
  check (effective_to is null or effective_to >= effective_from),
  exclude using gist (
    entity_id with =,
    category_id with =,
    context with =,
    daterange(effective_from, effective_to, '[]') with &&
  )
);
call app_private.apply_standard_triggers('public.category_account_mappings');
call app_private.secure_table('public.category_account_mappings');
create trigger tg_audit after insert or update or delete on public.category_account_mappings
  for each row execute function app_private.tg_audit('entity_id');

revoke all on all functions in schema app_private from public;
revoke all on all procedures in schema app_private from public;
