-- Decision 401 (OWNER's own attachment types, finishing decision 340): renaming a type and taking one out
-- of use.
--
-- Decision 340 added the per-Entity catalog and said in so many words that "rename and deactivate are not
-- built yet". A typo in a type's name was therefore permanent, and a type added by mistake stayed in the
-- dropdown for good -- the only way out being a second type with the right name next to the wrong one. Both
-- gaps close here. Nothing about money, the ledger or a permission rule changes: both commands need
-- `documents.upload`, the same right that adds a type in the first place (decision 340's own reasoning: a
-- person who may attach a file may name what they are attaching).
--
-- Taking a type out of use deliberately does NOT touch the attachments already carrying it. A link stores
-- `custom:<id>`, `link_document` checks "active" only when the link is made, and `list_document_links`
-- resolves the name whatever its state -- so a past attachment keeps reading the way it was filed, and only
-- new attachments stop being offered the type. That is what "no longer in use" means for a document trail;
-- rewriting history would be the wrong fix. A type is never deleted, for the same reason.

-- Renames a type. The new name follows the same rules the catalog already enforces, including its
-- case-and-spacing-insensitive uniqueness within the Entity -- so a rename onto another type's name is
-- refused rather than silently merging two types that attachments already point at separately.
create function public.rename_document_purpose(p_purpose uuid, p_name text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_name text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  p public.document_purposes%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into p from public.document_purposes where id = p_purpose for update;
  if not found then
    raise exception 'NOT_FOUND: attachment type' using errcode = 'no_data_found';
  end if;
  if not app_authz.has_permission(p.entity_id, 'documents.upload') then
    raise exception 'FORBIDDEN: renaming an attachment type needs documents.upload' using errcode = 'insufficient_privilege';
  end if;
  if length(v_name) not between 2 and 60 then
    raise exception 'INVALID: the name of an attachment type has 2 to 60 characters' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.document_purposes x
             where x.entity_id = p.entity_id and x.id <> p.id and x.normalized_name = lower(v_name)) then
    raise exception 'INVALID: this Entity already has an attachment type with that name'
      using errcode = 'invalid_parameter_value';
  end if;
  update public.document_purposes set name = v_name where id = p.id;
end
$$;
revoke all on function public.rename_document_purpose(uuid, text) from public, anon;
grant execute on function public.rename_document_purpose(uuid, text) to authenticated;

-- Takes a type out of use, or puts it back. `create_document_purpose` already reactivates a type when the
-- same name is added again (decision 340); this makes it a decision of its own rather than a side effect.
create function public.set_document_purpose_active(p_purpose uuid, p_active boolean) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p public.document_purposes%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if p_active is null then
    raise exception 'INVALID: active must be true or false' using errcode = 'invalid_parameter_value';
  end if;
  select * into p from public.document_purposes where id = p_purpose for update;
  if not found then
    raise exception 'NOT_FOUND: attachment type' using errcode = 'no_data_found';
  end if;
  if not app_authz.has_permission(p.entity_id, 'documents.upload') then
    raise exception 'FORBIDDEN: changing an attachment type needs documents.upload' using errcode = 'insufficient_privilege';
  end if;
  if p.is_active <> p_active then
    update public.document_purposes set is_active = p_active where id = p.id;
  end if;
end
$$;
revoke all on function public.set_document_purpose_active(uuid, boolean) from public, anon;
grant execute on function public.set_document_purpose_active(uuid, boolean) to authenticated;
