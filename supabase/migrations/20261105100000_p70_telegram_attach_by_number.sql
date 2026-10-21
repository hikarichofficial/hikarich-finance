-- Decision 424 (OWNER, 21 October 2026): the bot can attach a photo to ANY posted expense of an Entity the signed-in
-- user may attach documents to, found by its transaction number (for example EXP-001-0003), not only to entries the bot
-- made itself. Two functions:
--   telegram_find_expense  looks the number up among the Entities the user may view (names and the total, nothing else);
--   telegram_attach_receipt  (replaced) links the stored document to the expense. The permission to attach is still
--   decided by public.link_document (documents.upload plus edit access to expenses), which runs unchanged.
create function public.telegram_find_expense(p_link uuid, p_number text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_number text := upper(btrim(coalesce(p_number, '')));
  v_out jsonb;
begin
  if length(v_number) < 4 or length(v_number) > 40 then
    raise exception 'INVALID: a transaction number such as EXP-001-0003 is required' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.telegram_act_as(p_link);
  select coalesce(jsonb_agg(jsonb_build_object(
           'expense_id', x.id, 'entity_id', x.entity_id, 'entity_name', coalesce(e.brand_name, e.legal_name), 'entity_type', e.entity_type,
           'number', x.expense_number, 'status', x.status, 'date', x.expense_date, 'total', x.total::text,
           'currency', x.currency::text,
           'payee', coalesce(x.payee_name, (select co.display_name from public.contacts co where co.id = x.payee_id)),
           'can_attach', app_authz.has_permission(x.entity_id, 'documents.upload'))
           order by e.legal_name), '[]'::jsonb)
    into v_out
  from public.expenses x
  join public.entities e on e.id = x.entity_id
  where upper(x.expense_number) = v_number
    and app_authz.has_permission(x.entity_id, 'bills.view');
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return v_out;
end
$$;

revoke all on function public.telegram_find_expense(uuid, text) from public, anon, authenticated;
grant execute on function public.telegram_find_expense(uuid, text) to service_role;

create or replace function public.telegram_attach_receipt(p_link uuid, p_document uuid, p_storage_path text, p_expense uuid)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  x public.expenses%rowtype;
  d public.documents%rowtype;
  v_link uuid;
begin
  perform app_private.telegram_act_as(p_link);
  select * into x from public.expenses where id = p_expense;
  if not found or not app_authz.has_permission(x.entity_id, 'bills.view') then
    raise exception 'FORBIDDEN: that entry is not available to this account' using errcode = 'insufficient_privilege';
  end if;
  select * into d from public.documents where id = p_document;
  if not found or d.entity_id <> x.entity_id then
    raise exception 'INVALID: the document does not belong to the entry''s Entity' using errcode = 'invalid_parameter_value';
  end if;
  if d.storage_path is null then
    perform public.finalize_document_upload(p_document, p_storage_path);
  end if;
  v_link := public.link_document(p_document, 'expense', p_expense, 'receipt');
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return v_link;
end
$$;
