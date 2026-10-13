-- p67 (decision 418): an attachment can be deleted, in every menu, and its file leaves the storage.
--
-- Until now an attachment could only be "released" (Lepas): the link was marked removed and the file stayed in the
-- archive, and the evidence of a record that is no longer a draft could not be released at all (decision 95). The
-- owner asked for a delete button on each attachment, in every menu, and for the file to disappear from Supabase too.
--
--   * delete_attachment(link, reason): marks the link removed whatever the status of the record it belonged to. When
--     no other record uses the same file, the document is marked deleted and the caller gets the storage path so the
--     application can remove the bytes; a file still used by another record is only taken off this one.
--   * delete_document(document, reason): the same from the Documents screens (every link of the file goes).
--   * confirm_document_purge(document): called after the bytes are gone; clears the path.
--
-- The document row itself stays (a table that forbids deletes, referenced by journals and tax evidence) as a tombstone
-- with who deleted it, when and why, and the audit trail records it; only the file is gone. The same file uploaded
-- again later is the same document and is revived. A deleted document is never listed or served.

alter table public.documents add column deleted_at timestamptz;
alter table public.documents add column deleted_by uuid;
alter table public.documents add column delete_reason text;
alter table public.documents add constraint documents_deleted_consistent
  check ((deleted_at is null and deleted_by is null and delete_reason is null)
      or (deleted_at is not null and length(delete_reason) between 3 and 1000));

do $$
declare
  v_patch text[][] := array[
    -- (function, old text, new text, how many times the old text must occur in that function)
    array['app_private.tg_documents_guard()',
          $o$array['storage_path', 'updated_at', 'updated_by', 'version']$o$,
          $n$array['storage_path', 'deleted_at', 'deleted_by', 'delete_reason', 'updated_at', 'updated_by', 'version']$n$, '1'],
    -- the same content uploaded again after a delete is the same document again
    array['public.register_document(uuid,text,text,text,bigint,text,uuid)',
          $o$  select d.id into v_id from public.documents d where d.entity_id = p_entity and d.sha256 = v_hash;
  if v_id is null then$o$,
          $n$  select d.id into v_id from public.documents d where d.entity_id = p_entity and d.sha256 = v_hash;
  if v_id is not null then
    update public.documents set deleted_at = null, deleted_by = null, delete_reason = null
    where id = v_id and deleted_at is not null;
  end if;
  if v_id is null then$n$, '1'],
    -- a deleted file is never served
    array['public.get_document_download_grant(uuid)',
          $o$  select exists (select 1 from public.document_links l where l.document_id = d.id and l.status = 'active')
    into v_has_links;$o$,
          $n$  if d.deleted_at is not null then
    raise exception 'INVALID: this file was deleted' using errcode = 'invalid_parameter_value';
  end if;
  select exists (select 1 from public.document_links l where l.document_id = d.id and l.status = 'active')
    into v_has_links;$n$, '1'],
    -- and never listed
    array['public.list_documents(uuid,text,text,integer,integer)',
          $o$  where d.entity_id = p_entity
    and (p_q is null or d.file_name ilike '%' || p_q || '%')
    and ($o$,
          $n$  where d.entity_id = p_entity
    and d.deleted_at is null
    and (p_q is null or d.file_name ilike '%' || p_q || '%')
    and ($n$, '1'],
    array['public.list_document_archive(uuid,text,integer,integer)',
          $o$    where d.entity_id = p_entity
      and (p_q is null or d.file_name ilike '%' || p_q || '%')
  )$o$,
          $n$    where d.entity_id = p_entity
      and d.deleted_at is null
      and (p_q is null or d.file_name ilike '%' || p_q || '%')
  )$n$, '1']
  ];
  i integer;
  v_def text;
  v_src text;
  v_count integer;
begin
  for i in 1 .. array_length(v_patch, 1) loop
    v_def := pg_catalog.pg_get_functiondef(v_patch[i][1]::regprocedure);
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_patch[i][1]::regprocedure);
    v_count := (length(v_src) - length(replace(v_src, v_patch[i][2], ''))) / length(v_patch[i][2]);
    if v_count <> v_patch[i][4]::integer then
      raise exception 'p67 patch % (%): the old text occurs % time(s), expected %', i, v_patch[i][1], v_count, v_patch[i][4];
    end if;
    execute replace(v_def, v_patch[i][2], v_patch[i][3]);
  end loop;
end
$$;

-- Marks a document deleted when no record uses it any more; returns whether it did.
create function app_private.purge_document_if_unused(p_document uuid, p_reason text) returns boolean
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if exists (select 1 from public.document_links l where l.document_id = p_document and l.status = 'active') then
    return false;
  end if;
  update public.documents
  set deleted_at = now(), deleted_by = auth.uid(), delete_reason = left(p_reason, 1000)
  where id = p_document and deleted_at is null;
  return found;
end
$$;
revoke all on function app_private.purge_document_if_unused(uuid, text) from public;

-- Can the caller change the evidence of a record of this kind (the same right that attaches a file there)?
create function app_private.can_edit_document_target(p_entity uuid, p_target_type text) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
  select coalesce(app_authz.has_permission(p_entity, 'documents.upload')
         and (select bool_or(app_authz.has_permission(p_entity, p))
                from app_private.document_target_kinds k, unnest(k.edit_permission_any) as p
               where k.target_type = p_target_type), false)
$$;
revoke all on function app_private.can_edit_document_target(uuid, text) from public;

create function public.delete_attachment(p_link uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  l public.document_links%rowtype;
  d public.documents%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_purged boolean;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into l from public.document_links where id = p_link;
  if not found then
    raise exception 'INVALID: unknown document link' using errcode = 'invalid_parameter_value';
  end if;
  if not app_private.can_edit_document_target(l.entity_id, l.target_type) then
    raise exception 'FORBIDDEN: deleting an attachment needs documents.upload and % access', l.target_type
      using errcode = 'insufficient_privilege';
  end if;
  if length(v_reason) not between 3 and 1000 then
    raise exception 'INVALID: a reason is required' using errcode = 'invalid_parameter_value';
  end if;
  select * into l from public.document_links where id = p_link for update;
  if l.status <> 'active' then
    raise exception 'CONFLICT: this attachment is already removed' using errcode = 'integrity_constraint_violation';
  end if;
  perform set_config('app.audit_reason', v_reason, true);
  update public.document_links
  set status = 'removed', removed_at = now(), removed_by = auth.uid(), removed_reason = left('Dihapus: ' || v_reason, 500)
  where id = l.id;
  select * into d from public.documents where id = l.document_id for update;
  v_purged := app_private.purge_document_if_unused(l.document_id, v_reason);
  return jsonb_build_object('document_id', l.document_id, 'purged', v_purged,
                            'storage_path', case when v_purged then d.storage_path end);
end
$$;

create function public.delete_document(p_document uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  d public.documents%rowtype;
  l record;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_purged boolean;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into d from public.documents where id = p_document for update;
  if not found or not app_authz.has_permission(d.entity_id, 'documents.upload') then
    raise exception 'FORBIDDEN: deleting a file needs documents.upload' using errcode = 'insufficient_privilege';
  end if;
  if d.deleted_at is not null then
    raise exception 'CONFLICT: this file is already deleted' using errcode = 'integrity_constraint_violation';
  end if;
  if length(v_reason) not between 3 and 1000 then
    raise exception 'INVALID: a reason is required' using errcode = 'invalid_parameter_value';
  end if;
  -- every record that still uses the file must be one the caller may change
  for l in select * from public.document_links x where x.document_id = d.id and x.status = 'active' for update loop
    if not app_private.can_edit_document_target(l.entity_id, l.target_type) then
      raise exception 'FORBIDDEN: this file is attached to a % you may not change', l.target_type
        using errcode = 'insufficient_privilege';
    end if;
  end loop;
  perform set_config('app.audit_reason', v_reason, true);
  update public.document_links
  set status = 'removed', removed_at = now(), removed_by = auth.uid(), removed_reason = left('Dihapus: ' || v_reason, 500)
  where document_id = d.id and status = 'active';
  v_purged := app_private.purge_document_if_unused(d.id, v_reason);
  return jsonb_build_object('document_id', d.id, 'purged', v_purged, 'storage_path', d.storage_path);
end
$$;

-- Called once the bytes are gone from the storage: the document keeps no path.
create function public.confirm_document_purge(p_document uuid) returns void
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
  if d.deleted_at is null then
    raise exception 'CONFLICT: this file is not deleted' using errcode = 'integrity_constraint_violation';
  end if;
  update public.documents set storage_path = null where id = d.id;
end
$$;

revoke all on function public.delete_attachment(uuid, text) from public, anon;
revoke all on function public.delete_document(uuid, text) from public, anon;
revoke all on function public.confirm_document_purge(uuid) from public, anon;
grant execute on function public.delete_attachment(uuid, text) to authenticated;
grant execute on function public.delete_document(uuid, text) to authenticated;
grant execute on function public.confirm_document_purge(uuid) to authenticated;
