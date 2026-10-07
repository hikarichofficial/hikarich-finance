-- P30: own attachment types ("jenis lampiran"), OWNER request of 7 October 2026. Until now an attachment was
-- one of four fixed purposes (invoice vendor, kuitansi, kontrak, lainnya) and a person could not add their own,
-- e.g. "Surat jalan" or "Bukti transfer". A new per-Entity catalog holds the types a person adds; a link then
-- carries `custom:<id>` as its purpose. Nothing here touches money, the ledger or any permission rule: adding a
-- type needs the same right as attaching a file (`documents.upload`), and the built-in four stay exactly as
-- they were.
create table public.document_purposes (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  name text not null check (length(btrim(name)) between 2 and 60),
  normalized_name text generated always as (lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))) stored,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (entity_id, normalized_name)
);
call app_private.apply_standard_triggers('public.document_purposes');
call app_private.secure_table('public.document_purposes');
create trigger tg_audit after insert or update or delete on public.document_purposes
  for each row execute function app_private.tg_audit('entity_id');
create trigger tg_forbid_delete before delete on public.document_purposes
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.document_purposes
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.expose_select('public.document_purposes');
create policy document_purposes_select on public.document_purposes for select to authenticated
  using (app_authz.has_permission(entity_id, 'documents.view'));

-- Adds a type, or returns the one that already has this name (same name ignoring case and spacing).
create function public.create_document_purpose(p_entity uuid, p_name text) returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_name text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'documents.upload') then
    raise exception 'FORBIDDEN: adding an attachment type needs documents.upload' using errcode = 'insufficient_privilege';
  end if;
  if length(v_name) not between 2 and 60 then
    raise exception 'INVALID: the name of an attachment type has 2 to 60 characters' using errcode = 'invalid_parameter_value';
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  select id into v_id from public.document_purposes
  where entity_id = p_entity and normalized_name = lower(v_name);
  if v_id is not null then
    update public.document_purposes set is_active = true where id = v_id and not is_active;
    return v_id;
  end if;
  insert into public.document_purposes (entity_id, name) values (p_entity, v_name) returning id into v_id;
  return v_id;
end
$$;
revoke all on function public.create_document_purpose(uuid, text) from public, anon;
grant execute on function public.create_document_purpose(uuid, text) to authenticated;

-- A link's purpose is one of the built-in words or `custom:<uuid>`; the guard trigger checks the uuid names an
-- active type of the same Entity (a text column cannot carry a foreign key).
alter table public.document_links drop constraint document_links_purpose_check;
alter table public.document_links add constraint document_links_purpose_check
  check (purpose in ('vendor_invoice', 'receipt', 'contract', 'other', 'filing_receipt', 'payment_proof',
                     'withholding_slip', 'tax_invoice')
         or purpose ~ '^custom:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

create or replace function public.link_document(p_document uuid, p_target_type text, p_target_id uuid, p_purpose text default 'receipt')
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  d public.documents%rowtype;
  v_kind app_private.document_target_kinds%rowtype;
  v_id uuid;
  v_allowed boolean;
  v_purpose text := coalesce(p_purpose, 'receipt');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into d from public.documents where id = p_document;
  if not found then
    raise exception 'INVALID: unknown document' using errcode = 'invalid_parameter_value';
  end if;
  select * into v_kind from app_private.document_target_kinds k where k.target_type = p_target_type;
  if not found or not v_kind.generic_linker then
    raise exception 'INVALID: this linker does not take % records', coalesce(p_target_type, '?')
      using errcode = 'invalid_parameter_value';
  end if;
  select bool_or(app_authz.has_permission(d.entity_id, p)) into v_allowed from unnest(v_kind.edit_permission_any) as p;
  if not app_authz.has_permission(d.entity_id, 'documents.upload') or not coalesce(v_allowed, false) then
    raise exception 'FORBIDDEN: attaching a document needs documents.upload and % access', p_target_type
      using errcode = 'insufficient_privilege';
  end if;
  if v_purpose like 'custom:%' then
    if v_purpose !~ '^custom:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or not exists (select 1 from public.document_purposes dp
                      where dp.id = substr(v_purpose, 8)::uuid and dp.entity_id = d.entity_id and dp.is_active) then
      raise exception 'INVALID: this attachment type does not exist in this Entity' using errcode = 'invalid_parameter_value';
    end if;
  elsif v_purpose not in ('vendor_invoice', 'receipt', 'contract', 'other') then
    raise exception 'INVALID: the purpose is vendor_invoice, receipt, contract, other or one of your own types' using errcode = 'invalid_parameter_value';
  end if;
  select l.id into v_id from public.document_links l
  where l.document_id = d.id and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active';
  if v_id is not null then
    return v_id;
  end if;
  begin
    insert into public.document_links (entity_id, document_id, target_type, target_id, purpose)
    values (d.entity_id, d.id, p_target_type, p_target_id, v_purpose)
    returning id into v_id;
  exception when unique_violation then
    select l.id into v_id from public.document_links l
    where l.document_id = d.id and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active';
  end;
  return v_id;
end
$$;
