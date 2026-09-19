-- P1 (Step 15 §5 "master records"): exchange rates, categories, contacts and catalog.
-- Authority: Step 02 §2/§4 (Master Data, Contacts & Catalog), Step 03 §6, Step 08 §3/§15/§17.
-- Historical documents snapshot these values (Step 08 §3); editing a master never rewrites history.

-- ------------------------------------------------------------ exchange rates (Step 04 §14)
-- Global reference rates. Transactions copy the rate they use (snapshot), so rows here are
-- append-only: a correction is a new row with a different source or date.
create table public.exchange_rates (
  id uuid primary key default gen_random_uuid(),
  from_currency public.currency_code not null references public.currencies (code),
  to_currency public.currency_code not null references public.currencies (code),
  rate_date date not null,
  rate public.fx_rate not null,
  source text not null check (length(btrim(source)) > 0),
  created_at timestamptz not null default now(),
  created_by uuid,
  check (from_currency <> to_currency),
  unique (from_currency, to_currency, rate_date, source)
);
create trigger tg_forbid_update before update on public.exchange_rates
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.exchange_rates
  for each row execute function app_private.tg_forbid_delete();
call app_private.secure_table('public.exchange_rates');

-- ------------------------------------------------------------ categories (Step 02 §4, Step 03 §6)
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  parent_id uuid,
  code text,
  name text not null check (length(btrim(name)) > 0),
  normalized_name text generated always as (lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))) stored,
  kind text not null check (kind in ('revenue', 'expense', 'asset', 'liability', 'equity', 'other')),
  cashflow_class text not null default 'operating' check (cashflow_class in ('operating', 'investing', 'financing', 'none')),
  counts_as_turnover boolean not null default false,
  -- Tax classification is a separate dimension from the COA mapping (Step 03 §6); the key is
  -- resolved by the Tax engine in P7 and is intentionally free of tax rules here.
  tax_category_key text,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, parent_id) references public.categories (entity_id, id) on delete restrict,
  check (parent_id is null or parent_id <> id)
);
create index categories_entity_name_idx on public.categories (entity_id, normalized_name);
create trigger tg_no_cycle before insert or update of parent_id on public.categories
  for each row execute function app_private.tg_no_parent_cycle();
call app_private.apply_standard_triggers('public.categories');
call app_private.secure_table('public.categories');
create trigger tg_audit after insert or update or delete on public.categories
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ contacts (Step 02 §4)
-- Duplicates are detected through the normalized columns/indexes but never auto-merged (Step 08 §15).
create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  kind text not null check (kind in ('customer', 'vendor', 'both')),
  display_name text not null check (length(btrim(display_name)) > 0),
  legal_name text,
  normalized_name text generated always as (lower(regexp_replace(btrim(display_name), '\s+', ' ', 'g'))) stored,
  email text,
  normalized_email text generated always as (lower(btrim(email))) stored,
  phone text,
  normalized_phone text generated always as (regexp_replace(coalesce(phone, ''), '[^0-9]', '', 'g')) stored,
  tax_identifier text,
  address_line text,
  city text,
  country_code text check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  notes text,
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id)
);
create index contacts_entity_name_idx on public.contacts (entity_id, normalized_name);
create index contacts_entity_email_idx on public.contacts (entity_id, normalized_email) where normalized_email is not null;
create index contacts_entity_phone_idx on public.contacts (entity_id, normalized_phone) where normalized_phone <> '';
call app_private.apply_standard_triggers('public.contacts');
call app_private.secure_table('public.contacts');
-- Tax identifiers are sensitive (Step 06 §6): never copied into audit snapshots.
create trigger tg_audit after insert or update or delete on public.contacts
  for each row execute function app_private.tg_audit('entity_id', 'tax_identifier');

create table public.contact_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  contact_id uuid not null,
  bank_name text not null,
  account_number text not null check (length(btrim(account_number)) > 0),
  account_holder text not null,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, contact_id) references public.contacts (entity_id, id) on delete restrict
);
create unique index contact_bank_accounts_one_default_idx
  on public.contact_bank_accounts (contact_id) where is_default and is_active;
call app_private.apply_standard_triggers('public.contact_bank_accounts');
call app_private.secure_table('public.contact_bank_accounts');
create trigger tg_audit after insert or update or delete on public.contact_bank_accounts
  for each row execute function app_private.tg_audit('entity_id', 'account_number');

-- ------------------------------------------------------------ products / services (Step 02 §4)
create table public.products (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  kind text not null check (kind in ('product', 'service')),
  sku text,
  name text not null check (length(btrim(name)) > 0),
  normalized_name text generated always as (lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))) stored,
  description text,
  unit text not null default 'unit',
  default_unit_price public.money_amount check (default_unit_price is null or default_unit_price >= 0),
  default_currency public.currency_code references public.currencies (code),
  default_category_id uuid,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, default_category_id) references public.categories (entity_id, id) on delete restrict
);
create unique index products_entity_sku_uq on public.products (entity_id, sku) where sku is not null;
create index products_entity_name_idx on public.products (entity_id, normalized_name);
call app_private.apply_standard_triggers('public.products');
call app_private.secure_table('public.products');
create trigger tg_audit after insert or update or delete on public.products
  for each row execute function app_private.tg_audit('entity_id');

create table public.product_aliases (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  product_id uuid not null,
  alias text not null check (length(btrim(alias)) > 0),
  normalized_alias text generated always as (lower(regexp_replace(btrim(alias), '\s+', ' ', 'g'))) stored,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (entity_id, id),
  foreign key (entity_id, product_id) references public.products (entity_id, id) on delete cascade,
  -- An alias must resolve to exactly one product within the Entity.
  unique (entity_id, normalized_alias)
);
create trigger tg_lock_entity before update on public.product_aliases
  for each row execute function app_private.tg_lock_entity();
call app_private.secure_table('public.product_aliases');
