-- p24 (decision 324): automatic, owner-configurable SKU generator.
--
-- Audit first (nothing here duplicates what exists):
--   * `public.products` already has `sku` (unique per Entity where not null, `products_entity_sku_uq`) and its own
--     RLS / audit trigger; it is EXTENDED (brand, type, sequence number, parent product, variant), not replaced.
--   * Invoice lines already keep their own `description` and prices; they gain `sku_snapshot` (set when the line is
--     saved) so a later change of the master SKU never rewrites an old document.
--   * Audit uses the existing `tg_audit` / `audit_events`; the SKU history table only adds the "why".
--   * New: settings, brands, product types, variants, a never-reused sequence counter, a SKU history.
--
-- Everything is Entity-scoped and provisioned for EVERY Entity (existing ones below, new ones by trigger).
-- Owner = every catalogued permission; the two new rights are NOT granted to any other role.

-- ------------------------------------------------------------ permissions
alter table public.roles disable trigger tg_audit;
alter table public.role_permissions disable trigger tg_audit;
insert into public.permissions (key, module, action, description)
select v.module || '.' || v.action, v.module, v.action, v.description
from (values
  ('products', 'sku_settings', 'Configure the SKU generator (format, brands, types, variants, numbering)'),
  ('products', 'sku_override', 'Type or change a product SKU by hand')
) as v(module, action, description)
on conflict (key) do nothing;
alter table public.roles enable trigger tg_audit;
alter table public.role_permissions enable trigger tg_audit;

-- ------------------------------------------------------------ settings (one row per Entity)
create function app_private.valid_sku_components(p jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog, public as $$
declare
  e jsonb;
  seen text[] := array[]::text[];
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) <> 4 then return false; end if;
  for e in select * from jsonb_array_elements(p) loop
    if jsonb_typeof(e) <> 'object'
       or (select count(*) from jsonb_object_keys(e)) <> 3
       or not coalesce((e ->> 'key') = any (array['brand', 'type', 'seq', 'variant']), false)
       or jsonb_typeof(e -> 'enabled') <> 'boolean'
       or jsonb_typeof(e -> 'required') <> 'boolean'
       or (e ->> 'key') = any (seen) then
      return false;
    end if;
    seen := seen || (e ->> 'key');
  end loop;
  return true;
end
$$;

create table public.sku_settings (
  entity_id uuid primary key references public.entities (id) on delete restrict,
  auto_generate boolean not null default true,
  -- Order, on/off and "required" of the four parts: brand (Kode 1), type (Kode 2), seq (Kode 3), variant (Kode 4).
  components jsonb not null default
    '[{"key":"brand","enabled":true,"required":true},{"key":"type","enabled":true,"required":true},{"key":"seq","enabled":true,"required":true},{"key":"variant","enabled":true,"required":false}]'::jsonb
    check (app_private.valid_sku_components(components)),
  separator text not null default '-' check (separator ~ '^[-/._:~|+]{0,2}$'),
  prefix text not null default '' check (prefix ~ '^[A-Za-z0-9._/-]{0,12}$'),
  suffix text not null default '' check (suffix ~ '^[A-Za-z0-9._/-]{0,12}$'),
  -- A part with no value: left out (no double separator) or replaced by a fixed filler.
  empty_handling text not null default 'skip' check (empty_handling in ('skip', 'placeholder')),
  empty_placeholder text not null default 'XX' check (empty_placeholder ~ '^[A-Za-z0-9]{1,6}$'),
  number_digits smallint not null default 3 check (number_digits between 1 and 9),
  number_start integer not null default 1 check (number_start >= 0),
  number_step integer not null default 1 check (number_step >= 1),
  number_scope text not null default 'brand_type' check (number_scope in ('global', 'brand', 'brand_type')),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1
);
call app_private.apply_standard_triggers('public.sku_settings');
call app_private.secure_table('public.sku_settings');
create trigger tg_audit after insert or update or delete on public.sku_settings
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ brands (Kode 1), types (Kode 2), variants (Kode 4)
create table public.product_brands (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  name text not null check (length(btrim(name)) between 1 and 120),
  code text not null check (code ~ '^[A-Z0-9]{1,12}$'),
  description text check (description is null or length(description) <= 500),
  is_active boolean not null default true,
  archived_at timestamptz,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id)
);
-- One live code per Entity; an archived record frees its code.
create unique index product_brands_code_uq on public.product_brands (entity_id, code) where archived_at is null;

create table public.product_types (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  name text not null check (length(btrim(name)) between 1 and 120),
  code text not null check (code ~ '^[A-Z0-9]{1,12}$'),
  description text check (description is null or length(description) <= 500),
  is_active boolean not null default true,
  archived_at timestamptz,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id)
);
create unique index product_types_code_uq on public.product_types (entity_id, code) where archived_at is null;

-- Not only "validity": the variant kind can be a package, edition, tier or anything the Owner names.
create table public.product_variants (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  name text not null check (length(btrim(name)) between 1 and 120),
  code text not null check (code ~ '^[A-Z0-9]{1,12}$'),
  variant_type text not null default 'validity'
    check (variant_type in ('validity', 'package', 'edition', 'tier', 'custom')),
  validity_days integer check (validity_days is null or validity_days > 0),
  description text check (description is null or length(description) <= 500),
  is_active boolean not null default true,
  archived_at timestamptz,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id)
);
create unique index product_variants_code_uq on public.product_variants (entity_id, code) where archived_at is null;

call app_private.apply_standard_triggers('public.product_brands');
call app_private.apply_standard_triggers('public.product_types');
call app_private.apply_standard_triggers('public.product_variants');
call app_private.secure_table('public.product_brands');
call app_private.secure_table('public.product_types');
call app_private.secure_table('public.product_variants');
create trigger tg_audit after insert or update or delete on public.product_brands
  for each row execute function app_private.tg_audit('entity_id');
create trigger tg_audit after insert or update or delete on public.product_types
  for each row execute function app_private.tg_audit('entity_id');
create trigger tg_audit after insert or update or delete on public.product_variants
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ the never-reused counter
create table public.sku_sequences (
  entity_id uuid not null references public.entities (id) on delete restrict,
  scope_key text not null,
  last_value integer not null,
  updated_at timestamptz not null default now(),
  primary key (entity_id, scope_key)
);
create trigger tg_lock_entity before update on public.sku_sequences
  for each row execute function app_private.tg_lock_entity();
call app_private.secure_table('public.sku_sequences');

-- ------------------------------------------------------------ products: extended, not replaced
alter table public.products
  add column brand_id uuid,
  add column product_type_id uuid,
  add column sku_number integer,
  add column parent_product_id uuid,
  add column variant_id uuid,
  -- Existing rows keep whatever SKU they have and count as typed by hand; new rows default to generated.
  add column sku_manual boolean not null default true;
alter table public.products alter column sku_manual set default false;
alter table public.products
  add constraint products_brand_fk foreign key (entity_id, brand_id)
    references public.product_brands (entity_id, id) on delete restrict,
  add constraint products_type_fk foreign key (entity_id, product_type_id)
    references public.product_types (entity_id, id) on delete restrict,
  add constraint products_variant_fk foreign key (entity_id, variant_id)
    references public.product_variants (entity_id, id) on delete restrict,
  add constraint products_parent_fk foreign key (entity_id, parent_product_id)
    references public.products (entity_id, id) on delete restrict,
  add constraint products_variant_shape check ((parent_product_id is null) = (variant_id is null)),
  add constraint products_parent_not_self check (parent_product_id is null or parent_product_id <> id);
create unique index products_parent_variant_uq on public.products (parent_product_id, variant_id)
  where parent_product_id is not null;
create index products_parent_idx on public.products (entity_id, parent_product_id);
create index products_brand_idx on public.products (entity_id, brand_id);
create index products_type_idx on public.products (entity_id, product_type_id);

-- Browser roles may choose the classification; the counter and the manual flag are system-managed.
grant insert (brand_id, product_type_id, parent_product_id, variant_id) on public.products to authenticated;
grant update (brand_id, product_type_id) on public.products to authenticated;

-- The SKU as it was when an invoice line was saved: later master changes never rewrite an old document.
alter table public.invoice_lines add column sku_snapshot text;

create function app_private.tg_invoice_line_sku_snapshot() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.product_id is null then
    new.sku_snapshot := null;
  elsif tg_op = 'INSERT' or new.product_id is distinct from old.product_id then
    select p.sku into new.sku_snapshot from public.products p
    where p.entity_id = new.entity_id and p.id = new.product_id;
  end if;
  return new;
end
$$;
revoke all on function app_private.tg_invoice_line_sku_snapshot() from public;
create trigger tg_sku_snapshot before insert or update of product_id on public.invoice_lines
  for each row execute function app_private.tg_invoice_line_sku_snapshot();

-- ------------------------------------------------------------ history of every SKU
create table public.product_sku_history (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  product_id uuid not null,
  old_sku text,
  new_sku text,
  source text not null check (source in ('generated', 'manual', 'changed')),
  reason text,
  changed_by uuid,
  changed_at timestamptz not null default now(),
  unique (entity_id, id),
  foreign key (entity_id, product_id) references public.products (entity_id, id) on delete cascade
);
create index product_sku_history_product_idx on public.product_sku_history (entity_id, product_id, changed_at desc);
create trigger tg_lock_entity before update on public.product_sku_history
  for each row execute function app_private.tg_lock_entity();
call app_private.secure_table('public.product_sku_history');

-- ------------------------------------------------------------ defaults for an Entity (idempotent)
create function app_private.provision_sku_defaults(p_entity uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  insert into public.sku_settings (entity_id) values (p_entity) on conflict (entity_id) do nothing;
  insert into public.product_brands (entity_id, name, code, sort_order)
  select p_entity, v.name, v.code, v.ord from (values
    ('Kamar EA', 'KEA', 10), ('Kamar Kajian Market', 'KKM', 20), ('Hikarich', 'HIK', 30)
  ) as v(name, code, ord)
  where not exists (select 1 from public.product_brands b
                    where b.entity_id = p_entity and b.code = v.code and b.archived_at is null);
  insert into public.product_types (entity_id, name, code, sort_order)
  select p_entity, v.name, v.code, v.ord from (values
    ('Expert Advisor', 'EA', 10), ('Indicator', 'IND', 20), ('Software / Tool', 'TOOL', 30),
    ('Digital Access', 'ACC', 40), ('Ebook', 'EBK', 50), ('Video', 'VID', 60),
    ('Template', 'TPL', 70), ('Service', 'SRV', 80)
  ) as v(name, code, ord)
  where not exists (select 1 from public.product_types t
                    where t.entity_id = p_entity and t.code = v.code and t.archived_at is null);
  insert into public.product_variants (entity_id, name, code, variant_type, validity_days, sort_order)
  select p_entity, v.name, v.code, 'validity', v.days, v.ord from (values
    ('1 Bulan', '1B', 30, 10), ('3 Bulan', '3B', 90, 20), ('6 Bulan', '6B', 180, 30),
    ('1 Tahun', '1T', 365, 40), ('Lifetime', 'LT', null::integer, 50)
  ) as v(name, code, days, ord)
  where not exists (select 1 from public.product_variants x
                    where x.entity_id = p_entity and x.code = v.code and x.archived_at is null);
end
$$;
revoke all on function app_private.provision_sku_defaults(uuid) from public;

create function app_private.tg_entity_sku_defaults() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.provision_sku_defaults(new.id);
  return new;
end
$$;
revoke all on function app_private.tg_entity_sku_defaults() from public;
create trigger tg_sku_defaults after insert on public.entities
  for each row execute function app_private.tg_entity_sku_defaults();

select app_private.provision_sku_defaults(e.id) from public.entities e;

-- ------------------------------------------------------------ composing and numbering (one place, in the database)
-- The sequence number that the NEXT product of this scope would get (read only, for the preview).
create function app_private.peek_sku_number(p_entity uuid, p_brand uuid, p_type uuid) returns integer
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  s public.sku_settings;
  v_key text;
  v_last integer;
begin
  select * into s from public.sku_settings where entity_id = p_entity;
  if not found then return null; end if;
  v_key := case s.number_scope when 'global' then 'g'
             when 'brand' then 'b:' || coalesce(p_brand::text, '-')
             else 'bt:' || coalesce(p_brand::text, '-') || ':' || coalesce(p_type::text, '-') end;
  select q.last_value into v_last from public.sku_sequences q where q.entity_id = p_entity and q.scope_key = v_key;
  return case when v_last is null then s.number_start else v_last + s.number_step end;
end
$$;

-- Takes the next number of the scope. A single upsert on the counter row is atomic: two sessions in the same
-- scope queue on the row lock and never get the same number; deleting or archiving a product never gives its
-- number back (the counter only goes forward).
create function app_private.next_sku_number(p_entity uuid, p_brand uuid, p_type uuid) returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.sku_settings;
  v_key text;
  v_n integer;
begin
  select * into s from public.sku_settings where entity_id = p_entity;
  if not found then raise exception 'SKU settings missing' using errcode = 'no_data_found'; end if;
  v_key := case s.number_scope when 'global' then 'g'
             when 'brand' then 'b:' || coalesce(p_brand::text, '-')
             else 'bt:' || coalesce(p_brand::text, '-') || ':' || coalesce(p_type::text, '-') end;
  insert into public.sku_sequences as q (entity_id, scope_key, last_value)
  values (p_entity, v_key, s.number_start)
  on conflict (entity_id, scope_key) do update
    set last_value = q.last_value + s.number_step, updated_at = now()
  returning q.last_value into v_n;
  return v_n;
end
$$;

-- Puts the parts together exactly as the Entity's settings say. An empty or switched-off part leaves no double
-- separator. `p_base` = the SKU of the product itself, where the variant part is allowed to be empty.
create function app_private.compose_sku(
  p_entity uuid, p_brand text, p_type text, p_number integer, p_variant text, p_base boolean default false
) returns text
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  s public.sku_settings;
  e jsonb;
  v_val text;
  v_parts text[] := array[]::text[];
begin
  select * into s from public.sku_settings where entity_id = p_entity;
  if not found then raise exception 'SKU settings missing' using errcode = 'no_data_found'; end if;
  if s.prefix <> '' then v_parts := v_parts || s.prefix; end if;
  for e in select * from jsonb_array_elements(s.components) loop
    continue when not (e ->> 'enabled')::boolean;
    v_val := case e ->> 'key'
      when 'brand' then p_brand
      when 'type' then p_type
      when 'seq' then case when p_number is null then null else lpad(p_number::text, s.number_digits, '0') end
      else p_variant end;
    if v_val is null or v_val = '' then
      if (e ->> 'required')::boolean and not (p_base and (e ->> 'key') = 'variant') then
        raise exception 'SKU_PART_REQUIRED:%', e ->> 'key' using errcode = 'check_violation';
      end if;
      if s.empty_handling = 'placeholder' then v_val := s.empty_placeholder; else continue; end if;
    end if;
    v_parts := v_parts || v_val;
  end loop;
  if s.suffix <> '' then v_parts := v_parts || s.suffix; end if;
  if cardinality(v_parts) = 0 then
    raise exception 'SKU_EMPTY' using errcode = 'check_violation';
  end if;
  return array_to_string(v_parts, s.separator);
end
$$;
revoke all on function app_private.peek_sku_number(uuid, uuid, uuid) from public;
revoke all on function app_private.next_sku_number(uuid, uuid, uuid) from public;
revoke all on function app_private.compose_sku(uuid, text, text, integer, text, boolean) from public;

-- ------------------------------------------------------------ the product trigger: assign / guard the SKU
create function app_private.tg_product_sku() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  s public.sku_settings;
  v_parent public.products;
  v_brand text;
  v_type text;
  v_variant text;
  v_n integer;
  v_sku text;
  v_can_override boolean;
  i integer;
begin
  v_can_override := auth.uid() is null or app_authz.has_permission(new.entity_id, 'products.sku_override');
  select * into s from public.sku_settings where entity_id = new.entity_id;

  if tg_op = 'UPDATE' then
    if new.parent_product_id is distinct from old.parent_product_id
       or new.variant_id is distinct from old.variant_id
       or new.sku_number is distinct from old.sku_number then
      raise exception 'SKU_STRUCTURE_LOCKED' using errcode = 'check_violation';
    end if;
    if (new.brand_id is distinct from old.brand_id or new.product_type_id is distinct from old.product_type_id)
       and not v_can_override then
      raise exception 'SKU_OVERRIDE_FORBIDDEN' using errcode = 'insufficient_privilege';
    end if;
    new.sku := nullif(btrim(new.sku), '');
    if new.sku is distinct from old.sku then
      if not v_can_override then
        raise exception 'SKU_OVERRIDE_FORBIDDEN' using errcode = 'insufficient_privilege';
      end if;
      new.sku_manual := true;
      insert into public.product_sku_history (entity_id, product_id, old_sku, new_sku, source, reason, changed_by)
      values (new.entity_id, new.id, old.sku, new.sku, 'changed',
              nullif(current_setting('app.audit_reason', true), ''), auth.uid());
    end if;
    return new;
  end if;

  -- ---- INSERT
  new.sku := nullif(btrim(new.sku), '');

  if new.parent_product_id is not null then
    -- A variant: same brand, type and number as its product; only the variant part differs.
    select * into v_parent from public.products
    where entity_id = new.entity_id and id = new.parent_product_id;
    if not found or v_parent.parent_product_id is not null then
      raise exception 'SKU_PARENT_INVALID' using errcode = 'check_violation';
    end if;
    new.brand_id := v_parent.brand_id;
    new.product_type_id := v_parent.product_type_id;
    new.sku_number := v_parent.sku_number;
    select code into v_variant from public.product_variants where entity_id = new.entity_id and id = new.variant_id;
    if new.sku is null then
      if v_parent.sku is null then
        raise exception 'SKU_PARENT_INVALID' using errcode = 'check_violation';
      end if;
      if v_parent.brand_id is not null and not v_parent.sku_manual then
        select code into v_brand from public.product_brands where entity_id = new.entity_id and id = v_parent.brand_id;
        select code into v_type from public.product_types where entity_id = new.entity_id and id = v_parent.product_type_id;
        new.sku := app_private.compose_sku(new.entity_id, v_brand, v_type, v_parent.sku_number, v_variant);
      else
        -- The product's SKU was typed by hand: keep it and add the variant after it.
        new.sku := v_parent.sku || s.separator || v_variant;
      end if;
      new.sku_manual := false;
    else
      if not v_can_override then
        raise exception 'SKU_OVERRIDE_FORBIDDEN' using errcode = 'insufficient_privilege';
      end if;
      new.sku_manual := true;
    end if;
  elsif new.sku is not null then
    if not v_can_override then
      raise exception 'SKU_OVERRIDE_FORBIDDEN' using errcode = 'insufficient_privilege';
    end if;
    new.sku_manual := true;
  elsif s.auto_generate and new.brand_id is not null and new.product_type_id is not null then
    select code into v_brand from public.product_brands where entity_id = new.entity_id and id = new.brand_id;
    select code into v_type from public.product_types where entity_id = new.entity_id and id = new.product_type_id;
    -- Skip a number that is already taken by another SKU (e.g. after the numbering scope was changed).
    for i in 1 .. 200 loop
      v_n := app_private.next_sku_number(new.entity_id, new.brand_id, new.product_type_id);
      v_sku := app_private.compose_sku(new.entity_id, v_brand, v_type, v_n, null, true);
      exit when not exists (select 1 from public.products p where p.entity_id = new.entity_id and p.sku = v_sku);
      v_sku := null;
    end loop;
    if v_sku is null then raise exception 'SKU_NUMBER_EXHAUSTED' using errcode = 'unique_violation'; end if;
    new.sku := v_sku;
    new.sku_number := v_n;
    new.sku_manual := false;
  end if;

  if new.sku is not null then
    -- recorded after the row exists (history references it)
    new.sku_manual := coalesce(new.sku_manual, false);
  end if;
  return new;
end
$$;
revoke all on function app_private.tg_product_sku() from public;
create trigger tg_product_sku before insert or update on public.products
  for each row execute function app_private.tg_product_sku();

-- First SKU of a new product goes into the history too.
create function app_private.tg_product_sku_history_insert() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if new.sku is not null then
    insert into public.product_sku_history (entity_id, product_id, old_sku, new_sku, source, changed_by)
    values (new.entity_id, new.id, null, new.sku, case when new.sku_manual then 'manual' else 'generated' end, auth.uid());
  end if;
  return null;
end
$$;
revoke all on function app_private.tg_product_sku_history_insert() from public;
create trigger tg_product_sku_history after insert on public.products
  for each row execute function app_private.tg_product_sku_history_insert();

-- ------------------------------------------------------------ RLS and grants
-- The SKU masters are read directly (RLS: products.view) but WRITTEN only through the reviewed RPCs below, so the
-- baseline rule "browser roles hold no direct write privilege outside the master-data allowlist" stays untouched.
call app_private.expose_select('public.sku_settings');
call app_private.expose_select('public.product_brands');
call app_private.expose_select('public.product_types');
call app_private.expose_select('public.product_variants');
call app_private.expose_select('public.product_sku_history');

create policy sku_settings_select on public.sku_settings for select to authenticated
  using (app_authz.has_permission(entity_id, 'products.view'));
create policy product_brands_select on public.product_brands for select to authenticated
  using (app_authz.has_permission(entity_id, 'products.view'));
create policy product_types_select on public.product_types for select to authenticated
  using (app_authz.has_permission(entity_id, 'products.view'));
create policy product_variants_select on public.product_variants for select to authenticated
  using (app_authz.has_permission(entity_id, 'products.view'));
create policy product_sku_history_select on public.product_sku_history for select to authenticated
  using (app_authz.has_permission(entity_id, 'products.view'));

-- ------------------------------------------------------------ RPCs
-- What the SKU would be, for the live preview. Read only: it never takes a number.
create function public.preview_product_sku(
  p_entity uuid, p_brand uuid, p_type uuid, p_variant uuid default null, p_parent uuid default null
) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  s public.sku_settings;
  v_parent public.products;
  v_brand text;
  v_type text;
  v_variant text;
  v_n integer;
  v_base text;
  v_sku text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'products.view') then
    raise exception 'FORBIDDEN' using errcode = 'insufficient_privilege';
  end if;
  select * into s from public.sku_settings where entity_id = p_entity;
  if not found then return jsonb_build_object('auto', false); end if;

  if p_parent is not null then
    select * into v_parent from public.products where entity_id = p_entity and id = p_parent;
    if not found then return jsonb_build_object('auto', s.auto_generate, 'error', 'parent'); end if;
    if p_variant is not null then
      select code into v_variant from public.product_variants where entity_id = p_entity and id = p_variant;
    end if;
    if v_parent.brand_id is not null and not v_parent.sku_manual then
      select code into v_brand from public.product_brands where entity_id = p_entity and id = v_parent.brand_id;
      select code into v_type from public.product_types where entity_id = p_entity and id = v_parent.product_type_id;
      v_base := v_parent.sku;
      v_sku := case when v_variant is null then null
                    else app_private.compose_sku(p_entity, v_brand, v_type, v_parent.sku_number, v_variant) end;
    else
      v_base := v_parent.sku;
      v_sku := case when v_variant is null then null else v_parent.sku || s.separator || v_variant end;
    end if;
    return jsonb_build_object('auto', s.auto_generate, 'base_sku', v_base, 'sku', v_sku);
  end if;

  if p_brand is null or p_type is null then
    return jsonb_build_object('auto', s.auto_generate, 'base_sku', null, 'sku', null);
  end if;
  select code into v_brand from public.product_brands where entity_id = p_entity and id = p_brand;
  select code into v_type from public.product_types where entity_id = p_entity and id = p_type;
  v_n := app_private.peek_sku_number(p_entity, p_brand, p_type);
  v_base := app_private.compose_sku(p_entity, v_brand, v_type, v_n, null, true);
  return jsonb_build_object('auto', s.auto_generate, 'number', v_n, 'base_sku', v_base, 'sku', v_base);
exception when check_violation then
  return jsonb_build_object('auto', s.auto_generate, 'error', sqlerrm);
end
$$;
revoke all on function public.preview_product_sku(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.preview_product_sku(uuid, uuid, uuid, uuid, uuid) to authenticated;

-- Changes the SKU of a product by hand (Owner / `products.sku_override`), with an optional reason that goes into
-- the history and the audit log. Historical documents keep the SKU they were saved with.
create function public.set_product_sku(p_product uuid, p_sku text, p_reason text default null)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select entity_id into v_entity from public.products where id = p_product;
  if v_entity is null or not app_authz.has_permission(v_entity, 'products.sku_override') then
    raise exception 'SKU_OVERRIDE_FORBIDDEN' using errcode = 'insufficient_privilege';
  end if;
  if nullif(btrim(p_sku), '') is null or length(btrim(p_sku)) > 64 then
    raise exception 'SKU_INVALID' using errcode = 'check_violation';
  end if;
  perform set_config('app.audit_reason', coalesce(left(btrim(p_reason), 200), ''), true);
  update public.products set sku = btrim(p_sku) where id = p_product;
end
$$;
revoke all on function public.set_product_sku(uuid, text, text) from public, anon;
grant execute on function public.set_product_sku(uuid, text, text) to authenticated;

-- Has this SKU master ever been used? (UI: hard delete only when not; otherwise archive.)
create function public.sku_master_in_use(p_kind text, p_id uuid) returns boolean
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_kind = 'brand' then select entity_id into v_entity from public.product_brands where id = p_id;
  elsif p_kind = 'type' then select entity_id into v_entity from public.product_types where id = p_id;
  elsif p_kind = 'variant' then select entity_id into v_entity from public.product_variants where id = p_id;
  else raise exception 'SKU_KIND_INVALID' using errcode = 'check_violation'; end if;
  if v_entity is null or not app_authz.has_permission(v_entity, 'products.view') then return true; end if;
  return case p_kind
    when 'brand' then exists (select 1 from public.products where entity_id = v_entity and brand_id = p_id)
    when 'type' then exists (select 1 from public.products where entity_id = v_entity and product_type_id = p_id)
    else exists (select 1 from public.products where entity_id = v_entity and variant_id = p_id) end;
end
$$;
revoke all on function public.sku_master_in_use(text, uuid) from public, anon;
grant execute on function public.sku_master_in_use(text, uuid) to authenticated;

-- Products that appear on any invoice line (to warn before changing a SKU that old documents carry).
create function public.product_used_on_documents(p_product uuid) returns boolean
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select entity_id into v_entity from public.products where id = p_product;
  if v_entity is null or not app_authz.has_permission(v_entity, 'products.view') then return false; end if;
  return exists (select 1 from public.invoice_lines l where l.entity_id = v_entity and l.product_id = p_product);
end
$$;
revoke all on function public.product_used_on_documents(uuid) from public, anon;
grant execute on function public.product_used_on_documents(uuid) to authenticated;

-- ------------------------------------------------------------ write RPCs for the SKU masters (Owner / products.sku_settings)
create function app_private.require_sku_settings(p_entity uuid) returns void
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'products.sku_settings') then
    raise exception 'FORBIDDEN: missing products.sku_settings' using errcode = 'insufficient_privilege';
  end if;
end
$$;
revoke all on function app_private.require_sku_settings(uuid) from public;

-- Create (p_id null) or edit a brand, product type or variant. A code can be edited at any time: SKUs and
-- documents that already exist keep what they carry; only new SKUs use the new code.
create function public.save_sku_master(
  p_kind text, p_entity uuid, p_id uuid, p_name text, p_code text, p_description text default null,
  p_sort integer default 0, p_variant_type text default 'validity', p_validity_days integer default null,
  p_expected_version integer default null
) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_id uuid := p_id;
  v_code text := upper(btrim(p_code));
  v_name text := btrim(p_name);
  v_desc text := nullif(btrim(coalesce(p_description, '')), '');
  v_rows integer;
begin
  perform app_private.require_sku_settings(p_entity);
  if p_kind not in ('brand', 'type', 'variant') then
    raise exception 'SKU_KIND_INVALID' using errcode = 'check_violation';
  end if;
  if p_id is null then
    if p_kind = 'brand' then
      insert into public.product_brands (entity_id, name, code, description, sort_order)
      values (p_entity, v_name, v_code, v_desc, coalesce(p_sort, 0)) returning id into v_id;
    elsif p_kind = 'type' then
      insert into public.product_types (entity_id, name, code, description, sort_order)
      values (p_entity, v_name, v_code, v_desc, coalesce(p_sort, 0)) returning id into v_id;
    else
      insert into public.product_variants (entity_id, name, code, description, sort_order, variant_type, validity_days)
      values (p_entity, v_name, v_code, v_desc, coalesce(p_sort, 0), coalesce(p_variant_type, 'validity'), p_validity_days)
      returning id into v_id;
    end if;
    return v_id;
  end if;
  if p_kind = 'brand' then
    update public.product_brands set name = v_name, code = v_code, description = v_desc, sort_order = coalesce(p_sort, 0)
    where id = p_id and entity_id = p_entity and (p_expected_version is null or version = p_expected_version);
  elsif p_kind = 'type' then
    update public.product_types set name = v_name, code = v_code, description = v_desc, sort_order = coalesce(p_sort, 0)
    where id = p_id and entity_id = p_entity and (p_expected_version is null or version = p_expected_version);
  else
    update public.product_variants set name = v_name, code = v_code, description = v_desc, sort_order = coalesce(p_sort, 0),
      variant_type = coalesce(p_variant_type, 'validity'), validity_days = p_validity_days
    where id = p_id and entity_id = p_entity and (p_expected_version is null or version = p_expected_version);
  end if;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'SKU_MASTER_CONFLICT' using errcode = 'serialization_failure';
  end if;
  return v_id;
end
$$;

-- activate / deactivate / archive / restore / delete (delete only when nothing ever used it).
create function public.set_sku_master_state(p_kind text, p_entity uuid, p_id uuid, p_action text)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_rows integer;
  v_tbl text;
begin
  perform app_private.require_sku_settings(p_entity);
  v_tbl := case p_kind when 'brand' then 'product_brands' when 'type' then 'product_types'
                       when 'variant' then 'product_variants' end;
  if v_tbl is null or p_action not in ('activate', 'deactivate', 'archive', 'restore', 'delete') then
    raise exception 'SKU_KIND_INVALID' using errcode = 'check_violation';
  end if;
  if p_action = 'delete' then
    if public.sku_master_in_use(p_kind, p_id) then
      raise exception 'SKU_MASTER_IN_USE' using errcode = 'foreign_key_violation';
    end if;
    execute format('delete from public.%I where id = $1 and entity_id = $2', v_tbl) using p_id, p_entity;
  else
    execute format(
      'update public.%I set is_active = case $3 when ''activate'' then true when ''restore'' then true '
      || 'when ''deactivate'' then false else false end, '
      || 'archived_at = case $3 when ''archive'' then now() when ''restore'' then null else archived_at end '
      || 'where id = $1 and entity_id = $2', v_tbl) using p_id, p_entity, p_action;
  end if;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'SKU_MASTER_NOT_FOUND' using errcode = 'no_data_found';
  end if;
end
$$;

-- The format builder: order / on-off / required of the four parts, separator, prefix, suffix, empty handling,
-- digits, start, step, scope, and automatic on/off. Applies to NEW SKUs only.
create function public.save_sku_settings(
  p_entity uuid, p_auto boolean, p_components jsonb, p_separator text, p_prefix text, p_suffix text,
  p_empty_handling text, p_empty_placeholder text, p_digits integer, p_start integer, p_step integer, p_scope text
) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_rows integer;
begin
  perform app_private.require_sku_settings(p_entity);
  update public.sku_settings set
    auto_generate = p_auto, components = p_components, separator = coalesce(p_separator, ''),
    prefix = coalesce(btrim(p_prefix), ''), suffix = coalesce(btrim(p_suffix), ''),
    empty_handling = p_empty_handling, empty_placeholder = p_empty_placeholder,
    number_digits = p_digits, number_start = p_start, number_step = p_step, number_scope = p_scope
  where entity_id = p_entity;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    perform app_private.provision_sku_defaults(p_entity);
    update public.sku_settings set
      auto_generate = p_auto, components = p_components, separator = coalesce(p_separator, ''),
      prefix = coalesce(btrim(p_prefix), ''), suffix = coalesce(btrim(p_suffix), ''),
      empty_handling = p_empty_handling, empty_placeholder = p_empty_placeholder,
      number_digits = p_digits, number_start = p_start, number_step = p_step, number_scope = p_scope
    where entity_id = p_entity;
  end if;
end
$$;

revoke all on function public.save_sku_master(text, uuid, uuid, text, text, text, integer, text, integer, integer) from public, anon;
revoke all on function public.set_sku_master_state(text, uuid, uuid, text) from public, anon;
revoke all on function public.save_sku_settings(uuid, boolean, jsonb, text, text, text, text, text, integer, integer, integer, text) from public, anon;
grant execute on function public.save_sku_master(text, uuid, uuid, text, text, text, integer, text, integer, integer) to authenticated;
grant execute on function public.set_sku_master_state(text, uuid, uuid, text) to authenticated;
grant execute on function public.save_sku_settings(uuid, boolean, jsonb, text, text, text, text, text, integer, integer, integer, text) to authenticated;
