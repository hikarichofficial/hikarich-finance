-- P1 (Step 15 §5): Entities, configuration, identity and security foundations.
-- Authority: Step 02 §2/§4 (Organization & Security), Step 06 §1-§2/§6, Step 08 §3-§4/§15.
-- RLS policies and privileges are P2; here every table is RLS-enabled with no browser access.

-- ------------------------------------------------------------ reference: currencies
create table public.currencies (
  code public.currency_code primary key,
  name text not null,
  minor_unit smallint not null check (minor_unit between 0 and 4),
  is_active boolean not null default true
);
-- ISO 4217 reference data (production-safe; no business data).
insert into public.currencies (code, name, minor_unit) values
  ('IDR', 'Indonesian Rupiah', 2),
  ('USD', 'US Dollar', 2),
  ('EUR', 'Euro', 2),
  ('SGD', 'Singapore Dollar', 2),
  ('MYR', 'Malaysian Ringgit', 2),
  ('AUD', 'Australian Dollar', 2),
  ('GBP', 'Pound Sterling', 2),
  ('JPY', 'Japanese Yen', 0),
  ('CNY', 'Chinese Yuan', 2),
  ('SAR', 'Saudi Riyal', 2);
call app_private.secure_table('public.currencies');

-- ------------------------------------------------------------ profiles
-- Application users extend Supabase Auth users. Employees are separate records (Step 02 §4).
create table public.profiles (
  id uuid primary key references auth.users (id) on delete restrict,
  display_name text not null check (length(btrim(display_name)) > 0),
  is_active boolean not null default true,
  disabled_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  constraint profiles_disabled_consistency check (is_active = (disabled_at is null))
);
call app_private.apply_standard_triggers('public.profiles', false);
call app_private.secure_table('public.profiles');

-- ------------------------------------------------------------ entities
create table public.entities (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('company', 'personal', 'other')),
  code text not null unique check (code ~ '^[a-z][a-z0-9_-]{1,30}$'),
  legal_name text not null check (length(btrim(legal_name)) > 0),
  brand_name text,
  base_currency public.currency_code not null default 'IDR' references public.currencies (code),
  timezone text not null default 'Asia/Jakarta',
  fiscal_year_start_month smallint not null default 1 check (fiscal_year_start_month between 1 and 12),
  status text not null default 'active' check (status in ('active', 'disabled')),
  disabled_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  constraint entities_disabled_consistency check ((status = 'disabled') = (disabled_at is not null))
);

create function app_private.tg_entities_validate() returns trigger
language plpgsql as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'Unknown timezone %', new.timezone using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE' then
    if new.base_currency is distinct from old.base_currency
       and exists (select 1 from public.ledger_accounts where entity_id = old.id limit 1) then
      raise exception 'Entity base currency cannot change once a ledger exists (Step 04 §14)'
        using errcode = 'integrity_constraint_violation';
    end if;
    if new.entity_type is distinct from old.entity_type then
      raise exception 'Entity type cannot change (legal-identity boundary, Step 08 §4)'
        using errcode = 'integrity_constraint_violation';
    end if;
  end if;
  return new;
end
$$;
create trigger tg_entities_validate before insert or update on public.entities
  for each row execute function app_private.tg_entities_validate();
call app_private.apply_standard_triggers('public.entities', false);
call app_private.secure_table('public.entities');

-- Legal/brand identity (Step 02 §4). Taxpayer facts belong to the Tax phase (P7/P15).
create table public.entity_profiles (
  entity_id uuid primary key references public.entities (id) on delete restrict,
  address_line text,
  city text,
  province text,
  postal_code text,
  country_code text not null default 'ID' check (country_code ~ '^[A-Z]{2}$'),
  contact_email text,
  contact_phone text,
  website text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1
);
call app_private.apply_standard_triggers('public.entity_profiles');
call app_private.secure_table('public.entity_profiles');

-- Per-Entity configuration values (Step 02 §2 "Entities & Configuration").
create table public.entity_settings (
  entity_id uuid not null references public.entities (id) on delete restrict,
  setting_key text not null check (setting_key ~ '^[a-z][a-z0-9_.]{1,80}$'),
  setting_value jsonb not null,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  primary key (entity_id, setting_key)
);
call app_private.apply_standard_triggers('public.entity_settings');
call app_private.secure_table('public.entity_settings');

-- ------------------------------------------------------------ roles & permissions (Step 06 §2, §4)
-- Atomic permissions are the unit of evaluation; roles are editable templates. The permission
-- catalog and role templates are seeded in P2 together with the RLS policies that use them.
create table public.permissions (
  key text primary key check (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){1,3}$'),
  module text not null,
  action text not null,
  description text,
  created_at timestamptz not null default now()
);
call app_private.secure_table('public.permissions');

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  role_key text not null unique check (role_key ~ '^[a-z][a-z0-9_]*$'),
  name text not null,
  description text,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1
);
call app_private.apply_standard_triggers('public.roles', false);
call app_private.secure_table('public.roles');

create table public.role_permissions (
  role_id uuid not null references public.roles (id) on delete cascade,
  permission_key text not null references public.permissions (key) on delete restrict,
  created_at timestamptz not null default now(),
  created_by uuid,
  primary key (role_id, permission_key)
);
call app_private.secure_table('public.role_permissions');

-- Entity membership: which user may act in which Entity, with which role (Step 06 §5, §9).
create table public.entity_memberships (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  user_id uuid not null references public.profiles (id) on delete restrict,
  role_id uuid not null references public.roles (id) on delete restrict,
  status text not null default 'active' check (status in ('active', 'disabled')),
  disabled_at timestamptz,
  granted_by uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, user_id),
  unique (entity_id, id),
  constraint memberships_disabled_consistency check ((status = 'disabled') = (disabled_at is not null))
);
create index entity_memberships_user_idx on public.entity_memberships (user_id) where status = 'active';
call app_private.apply_standard_triggers('public.entity_memberships');
call app_private.secure_table('public.entity_memberships');

-- Per-membership capability exceptions on top of the role (Step 06 §2 "granular capabilities").
create table public.membership_permission_overrides (
  membership_id uuid not null references public.entity_memberships (id) on delete cascade,
  permission_key text not null references public.permissions (key) on delete restrict,
  effect text not null check (effect in ('grant', 'deny')),
  reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  primary key (membership_id, permission_key)
);
call app_private.secure_table('public.membership_permission_overrides');

-- Effective-dated approval rules (Step 06 §7). Overlapping rules for the same scope are impossible.
create table public.approval_rules (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  module text not null,
  action text not null,
  min_amount public.money_amount check (min_amount is null or min_amount >= 0),
  requires_approval boolean not null default true,
  approver_role_id uuid references public.roles (id) on delete restrict,
  allow_self_approval boolean not null default false,
  effective_from date not null,
  effective_to date,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  check (effective_to is null or effective_to >= effective_from),
  exclude using gist (
    entity_id with =,
    module with =,
    action with =,
    (coalesce(min_amount, 0)) with =,
    daterange(effective_from, effective_to, '[]') with &&
  )
);
call app_private.apply_standard_triggers('public.approval_rules');
call app_private.secure_table('public.approval_rules');

-- Trusted devices and security events (Step 02 §4, Step 13 §19). Secrets are never stored:
-- only a hash of the device fingerprint.
create table public.trusted_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete restrict,
  fingerprint_hash text not null,
  label text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  trusted_until timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (user_id, fingerprint_hash)
);
call app_private.apply_standard_triggers('public.trusted_devices', false);
call app_private.secure_table('public.trusted_devices');

create table public.security_events (
  id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default now(),
  user_id uuid references public.profiles (id) on delete restrict,
  entity_id uuid references public.entities (id) on delete restrict,
  event_type text not null,
  severity text not null default 'info' check (severity in ('info', 'warning', 'critical')),
  ip_address inet,
  user_agent text,
  metadata jsonb not null default '{}'::jsonb,
  correlation_id text
);
create index security_events_user_idx on public.security_events (user_id, occurred_at desc);
create trigger tg_forbid_update before update on public.security_events
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.security_events
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.security_events
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.security_events');
