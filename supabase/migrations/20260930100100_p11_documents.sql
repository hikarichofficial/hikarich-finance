-- P11 (Step 15 §15): generalizes P6's document storage from two hardcoded targets (bill, expense)
-- to a data-driven catalog, adds upload/download plumbing and version history.
-- Authority: Step 02 (Documents/Audit/Imports), Step 06 §5/§11, Step 08 §17/§21, Step 13 §16.
-- Engineering decisions: docs/DECISIONS.md #141-142.

-- ------------------------------------------------------------ target-kind catalog
-- Reference data (like public.permissions/public.roles): not Entity-scoped, changed only by migration.
create table app_private.document_target_kinds (
  target_type text primary key check (target_type ~ '^[a-z][a-z_]{1,40}$'),
  table_name regclass not null,
  view_permission text not null references public.permissions (key),
  edit_permission_any text[] not null check (array_length(edit_permission_any, 1) between 1 and 4),
  blocked_link_statuses text[] not null default '{}',
  removable_statuses text[] not null default '{}',
  -- false for a kind that keeps its own dedicated linker (tax_filing/tax_payment use tax_link_evidence,
  -- with its own tax-specific purposes and permission wording); the shared guard trigger still applies.
  generic_linker boolean not null default true
);

insert into app_private.document_target_kinds
  (target_type, table_name, view_permission, edit_permission_any, blocked_link_statuses, removable_statuses,
   generic_linker)
values
  ('bill', 'public.bills', 'bills.view', array['bills.create', 'bills.edit'],
   array['cancelled', 'void', 'reversed'], array['draft', 'submitted'], true),
  ('expense', 'public.expenses', 'bills.view', array['bills.create', 'bills.edit'],
   array['cancelled', 'reversed'], array['draft', 'submitted'], true),
  ('invoice', 'public.invoices', 'invoices.view', array['invoices.create', 'invoices.edit'],
   array['void'], array['draft'], true),
  ('fixed_asset', 'public.fixed_assets', 'assets.view', array['assets.manage'],
   array['cancelled'], array['draft'], true),
  ('loan', 'public.loans', 'loans.view', array['loans.manage'],
   array['cancelled'], array['draft'], true),
  ('other_obligation', 'public.other_obligations', 'loans.view', array['loans.manage'],
   array['void'], array['open'], true),
  ('equity_event', 'public.equity_events', 'equity.view', array['equity.manage'],
   array['reversed', 'cancelled'], array['draft'], true),
  ('contact', 'public.contacts', 'contacts.view', array['contacts.create', 'contacts.edit'],
   array[]::text[], array['active', 'inactive'], true),
  ('journal_entry', 'public.journal_entries', 'accounting.view', array['accounting.journal_create'],
   array[]::text[], array['draft'], true),
  -- P7 (20260925100400_p7_payments_filings.sql) already extended document_links to these two kinds with
  -- its own copy of this guard function; folded into the catalog here (decision 141) rather than left as a
  -- second hardcoded branch. Evidence of a filing or payment is never blocked and never removable: "tax
  -- evidence is part of the record" (decision 95). tax_link_evidence/tax_list_evidence keep serving them
  -- with their own tax-specific purposes and permission wording (generic_linker = false, matching the
  -- P6 test "the purchase linker does not take tax records").
  ('tax_filing', 'public.tax_filings', 'tax.view', array['tax.mark_filed'], array[]::text[], array[]::text[], false),
  ('tax_payment', 'public.tax_payments', 'tax.view', array['tax.mark_filed'], array[]::text[], array[]::text[], false);

-- ------------------------------------------------------------ documents: wider MIME allowlist, versioning
do $$
declare
  v_name text;
begin
  select con.conname into v_name from pg_constraint con
  where con.conrelid = 'public.documents'::regclass and con.contype = 'c'
    and pg_get_constraintdef(con.oid) like '%mime_type%';
  execute format('alter table public.documents drop constraint %I', v_name);
end
$$;
alter table public.documents add constraint documents_mime_type_check check (
  mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'text/csv',
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'));

alter table public.documents add column supersedes_document_id uuid;
alter table public.documents add constraint documents_supersedes_fk
  foreign key (entity_id, supersedes_document_id) references public.documents (entity_id, id);
alter table public.documents add constraint documents_supersedes_not_self
  check (supersedes_document_id is null or supersedes_document_id <> id);

-- Adds an optional `p_supersedes` (Step 08 §21 version history); everything else is unchanged from P6.
-- The old 6-argument signature is dropped first: leaving both would overload the name and make an
-- ordinary 6-argument call ambiguous between "the old function" and "the new one using its default".
drop function public.register_document(uuid, text, text, text, bigint, text);
create function public.register_document(
  p_entity uuid, p_key text, p_file_name text, p_mime_type text, p_size_bytes bigint, p_sha256 text,
  p_supersedes uuid default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
  v_hash text := lower(btrim(coalesce(p_sha256, '')));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'documents.upload') then
    raise exception 'FORBIDDEN: missing documents.upload' using errcode = 'insufficient_privilege';
  end if;
  v_replay := app_private.idem_begin('document.register', p_entity, p_key,
    md5(jsonb_build_object('n', p_file_name, 'm', p_mime_type, 's', p_size_bytes, 'h', v_hash,
                           'sup', p_supersedes)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_mime_type is null or p_size_bytes is null then
    raise exception 'INVALID: the document needs a file type and a size' using errcode = 'invalid_parameter_value';
  end if;
  if p_supersedes is not null and not exists (
      select 1 from public.documents d where d.id = p_supersedes and d.entity_id = p_entity) then
    raise exception 'INVALID: the superseded document does not exist in this Entity' using errcode = 'invalid_parameter_value';
  end if;
  select d.id into v_id from public.documents d where d.entity_id = p_entity and d.sha256 = v_hash;
  if v_id is null then
    begin
      insert into public.documents (entity_id, file_name, mime_type, size_bytes, sha256, supersedes_document_id)
      values (p_entity, btrim(coalesce(p_file_name, '')), p_mime_type, p_size_bytes, v_hash, p_supersedes)
      returning id into v_id;
    exception
      when check_violation then
        raise exception 'INVALID: the document needs a plain file name, an accepted file type, a size up to 25 MB and a SHA-256 hash'
          using errcode = 'invalid_parameter_value';
      when unique_violation then
        -- The same content was registered by a concurrent call: it is the same document.
        select d.id into v_id from public.documents d where d.entity_id = p_entity and d.sha256 = v_hash;
    end;
  end if;
  perform app_private.idem_complete('document.register', p_entity, p_key, 'documents', v_id);
  return v_id;
end
$$;

-- ------------------------------------------------------------ document_links: data-driven target kind
do $$
declare
  v_name text;
begin
  select con.conname into v_name from pg_constraint con
  where con.conrelid = 'public.document_links'::regclass and con.contype = 'c'
    and pg_get_constraintdef(con.oid) like '%target_type%';
  execute format('alter table public.document_links drop constraint %I', v_name);
end
$$;

create or replace function app_private.tg_document_links_guard() returns trigger
language plpgsql as $$
declare
  v_kind app_private.document_target_kinds%rowtype;
  v_status text;
  v_lock constant text[] := array['status', 'removed_at', 'removed_by', 'removed_reason', 'updated_at', 'updated_by',
                                   'version'];
begin
  if tg_op = 'INSERT' then
    select * into v_kind from app_private.document_target_kinds k where k.target_type = new.target_type;
    if not found then
      raise exception 'INVALID: unknown document target type %', new.target_type using errcode = 'invalid_parameter_value';
    end if;
    execute format('select status from %s where id = $1 and entity_id = $2', v_kind.table_name)
      into v_status using new.target_id, new.entity_id;
    if v_status is null then
      raise exception 'INVALID: the % does not exist in this Entity', new.target_type using errcode = 'invalid_parameter_value';
    end if;
    if v_status = any (v_kind.blocked_link_statuses) then
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

-- ------------------------------------------------------------ generalized commands (replace the P6 versions)
create or replace function public.link_document(p_document uuid, p_target_type text, p_target_id uuid, p_purpose text default 'receipt')
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  d public.documents%rowtype;
  v_kind app_private.document_target_kinds%rowtype;
  v_id uuid;
  v_allowed boolean;
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
  if coalesce(p_purpose, 'receipt') not in ('vendor_invoice', 'receipt', 'contract', 'other') then
    raise exception 'INVALID: the purpose is vendor_invoice, receipt, contract or other' using errcode = 'invalid_parameter_value';
  end if;
  select l.id into v_id from public.document_links l
  where l.document_id = d.id and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active';
  if v_id is not null then
    return v_id;
  end if;
  begin
    insert into public.document_links (entity_id, document_id, target_type, target_id, purpose)
    values (d.entity_id, d.id, p_target_type, p_target_id, coalesce(p_purpose, 'receipt'))
    returning id into v_id;
  exception when unique_violation then
    select l.id into v_id from public.document_links l
    where l.document_id = d.id and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active';
  end;
  return v_id;
end
$$;

create or replace function public.unlink_document(p_link uuid, p_reason text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.document_links%rowtype;
  v_kind app_private.document_target_kinds%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_status text;
  v_allowed boolean;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.document_links where id = p_link;
  if not found then
    raise exception 'INVALID: unknown document link' using errcode = 'invalid_parameter_value';
  end if;
  -- Unlike link_document, removal is not restricted to generic_linker kinds: a dedicated linker (tax
  -- evidence) still uses the shared removable_statuses rule to keep its evidence permanently attached.
  select * into v_kind from app_private.document_target_kinds k where k.target_type = l.target_type;
  select bool_or(app_authz.has_permission(l.entity_id, p)) into v_allowed from unnest(v_kind.edit_permission_any) as p;
  if not app_authz.has_permission(l.entity_id, 'documents.upload') or not coalesce(v_allowed, false) then
    raise exception 'FORBIDDEN: removing a document needs documents.upload and % access', l.target_type
      using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 3 and 1000 then
    raise exception 'INVALID: a reason is required' using errcode = 'invalid_parameter_value';
  end if;
  select * into l from public.document_links where id = p_link for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: this document link is already removed' using errcode = 'integrity_constraint_violation';
  end if;
  execute format('select status from %s where id = $1 and entity_id = $2', v_kind.table_name)
    into v_status using l.target_id, l.entity_id;
  if not (v_status = any (v_kind.removable_statuses)) then
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

create or replace function public.list_document_links(p_entity uuid, p_target_type text, p_target_id uuid)
returns table (
  link_id uuid, document_id uuid, file_name text, mime_type text, size_bytes bigint, sha256 text, purpose text,
  created_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_kind app_private.document_target_kinds%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_kind from app_private.document_target_kinds k where k.target_type = p_target_type;
  if not found or not app_authz.has_permission(p_entity, 'documents.view')
     or not app_authz.has_permission(p_entity, v_kind.view_permission) then
    raise exception 'FORBIDDEN: missing documents.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select l.id, d.id, d.file_name, d.mime_type, d.size_bytes, d.sha256, l.purpose, l.created_at
  from public.document_links l
  join public.documents d on d.id = l.document_id
  where l.entity_id = p_entity and l.target_type = p_target_type and l.target_id = p_target_id and l.status = 'active'
  order by l.created_at;
end
$$;

-- Atomically swaps a link to a newer version of the same evidence (Step 08 §21).
create or replace function public.replace_document_link(p_link uuid, p_new_document uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.document_links%rowtype;
  nd public.documents%rowtype;
  v_new_link uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.document_links where id = p_link;
  if not found then
    raise exception 'INVALID: unknown document link' using errcode = 'invalid_parameter_value';
  end if;
  select * into nd from public.documents where id = p_new_document and entity_id = l.entity_id;
  if not found then
    raise exception 'INVALID: the replacement document must be registered in the same Entity'
      using errcode = 'invalid_parameter_value';
  end if;
  v_new_link := public.link_document(nd.id, l.target_type, l.target_id, l.purpose);
  perform public.unlink_document(p_link, coalesce(nullif(btrim(p_reason), ''), 'replaced with a newer version'));
  return v_new_link;
end
$$;

-- Sets the storage location once the bytes actually landed in Supabase Storage (Step 13 §16); the
-- upload route (src/services/documents) picks the object key, verifies the file signature/size and
-- calls this after a successful upload. storage_path never changes once set: a corrected file is a
-- new document (register_document with p_supersedes) plus replace_document_link, not an overwrite.
create or replace function public.finalize_document_upload(p_document uuid, p_storage_path text)
returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  d public.documents%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into d from public.documents where id = p_document for update;
  if not found or not app_authz.has_permission(d.entity_id, 'documents.upload') then
    raise exception 'FORBIDDEN: missing documents.upload' using errcode = 'insufficient_privilege';
  end if;
  if d.storage_path is not null then
    raise exception 'CONFLICT: this document already has a storage location' using errcode = 'integrity_constraint_violation';
  end if;
  if p_storage_path is null or length(p_storage_path) not between 1 and 500 then
    raise exception 'INVALID: a storage path is required' using errcode = 'invalid_parameter_value';
  end if;
  update public.documents set storage_path = p_storage_path where id = d.id;
end
$$;

-- Permission re-check before a signed download/preview URL is minted (Step 06 §5: a storage path
-- alone is not permission). Granted when the caller can view any active link's target, or the
-- document has no links yet and the caller can at least see the Documents module.
create or replace function public.get_document_download_grant(p_document uuid)
returns table (document_id uuid, file_name text, mime_type text, storage_path text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  d public.documents%rowtype;
  v_has_links boolean;
  v_allowed boolean := false;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into d from public.documents where id = p_document;
  if not found or not app_authz.has_permission(d.entity_id, 'documents.view') then
    raise exception 'FORBIDDEN: missing documents.view' using errcode = 'insufficient_privilege';
  end if;
  select exists (select 1 from public.document_links l where l.document_id = d.id and l.status = 'active')
    into v_has_links;
  if not v_has_links then
    v_allowed := true;
  else
    select bool_or(app_authz.has_permission(d.entity_id, k.view_permission)) into v_allowed
    from public.document_links l
    join app_private.document_target_kinds k on k.target_type = l.target_type
    where l.document_id = d.id and l.status = 'active';
  end if;
  if not coalesce(v_allowed, false) then
    raise exception 'FORBIDDEN: no accessible record links to this document' using errcode = 'insufficient_privilege';
  end if;
  return query select d.id, d.file_name, d.mime_type, d.storage_path;
end
$$;

-- Documents Center list (Step 01 #35): every document the caller could reach through link_document's
-- own permission check, plus unlinked documents while at least documents.view is held.
create or replace function public.list_documents(
  p_entity uuid, p_target_type text default null, p_q text default null, p_limit int default 50, p_offset int default 0)
returns table (
  document_id uuid, file_name text, mime_type text, size_bytes bigint, sha256 text, created_at timestamptz,
  link_count bigint, target_types text[])
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'documents.view') then
    raise exception 'FORBIDDEN: missing documents.view' using errcode = 'insufficient_privilege';
  end if;
  if p_limit is null or p_limit not between 1 and 200 then
    raise exception 'INVALID: limit must be between 1 and 200' using errcode = 'invalid_parameter_value';
  end if;
  return query
  select d.id, d.file_name, d.mime_type, d.size_bytes, d.sha256, d.created_at,
         count(l.id) filter (where l.status = 'active'),
         coalesce(array_agg(distinct l.target_type) filter (where l.status = 'active'), '{}')
  from public.documents d
  left join public.document_links l on l.document_id = d.id
  where d.entity_id = p_entity
    and (p_q is null or d.file_name ilike '%' || p_q || '%')
    and (
      -- unlinked: visible with documents.view alone, but only when no target_type filter is applied
      -- (an unlinked document has no target_type of its own, so it never matches a specific filter)
      (p_target_type is null
       and not exists (select 1 from public.document_links x where x.document_id = d.id and x.status = 'active'))
      -- linked: visible only through a target the caller can view (and matching the filter, if any)
      or exists (
        select 1 from public.document_links x
        join app_private.document_target_kinds k on k.target_type = x.target_type
        where x.document_id = d.id and x.status = 'active'
          and app_authz.has_permission(p_entity, k.view_permission)
          and (p_target_type is null or x.target_type = p_target_type)))
  group by d.id
  order by d.created_at desc
  limit p_limit offset greatest(coalesce(p_offset, 0), 0);
end
$$;

grant execute on function public.register_document(uuid, text, text, text, bigint, text, uuid) to authenticated;
grant execute on function public.replace_document_link(uuid, uuid, text) to authenticated;
grant execute on function public.finalize_document_upload(uuid, text) to authenticated;
grant execute on function public.get_document_download_grant(uuid) to authenticated;
grant execute on function public.list_documents(uuid, text, text, int, int) to authenticated;
