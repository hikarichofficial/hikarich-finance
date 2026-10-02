-- P15 decision 272 (OWNER: "pastikan bahwa semua bisa diubah dan diedit diganti namanya"): the Entity's
-- legal name, brand name, address and contact details can be changed from Settings.
--
-- Until now these were written once when the Entity row was created and no command changed them. Like
-- the timezone (decision 248) this needs `system.entity_config` (OWNER by default) and a recent step-up,
-- uses optimistic concurrency on `entities.version`, and is recorded in the Audit Log with before/after.
-- Issued invoices and receipts keep the name they were issued with: their documents store their own
-- snapshot. The Entity code and type are not changed here (URLs and the chart of accounts depend on them).

create function public.update_entity_identity(
  p_entity uuid, p_legal_name text, p_brand_name text, p_address_line text, p_city text, p_province text,
  p_postal_code text, p_contact_email text, p_contact_phone text, p_website text, p_expected_version integer)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_old public.entities%rowtype;
  v_old_profile public.entity_profiles%rowtype;
  v_version integer;
  v_legal text := btrim(coalesce(p_legal_name, ''));
  v_brand text := nullif(btrim(coalesce(p_brand_name, '')), '');
  v_address text := nullif(btrim(coalesce(p_address_line, '')), '');
  v_city text := nullif(btrim(coalesce(p_city, '')), '');
  v_province text := nullif(btrim(coalesce(p_province, '')), '');
  v_postal text := nullif(btrim(coalesce(p_postal_code, '')), '');
  v_email text := nullif(btrim(coalesce(p_contact_email, '')), '');
  v_phone text := nullif(btrim(coalesce(p_contact_phone, '')), '');
  v_website text := nullif(btrim(coalesce(p_website, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'system.entity_config') then
    raise exception 'FORBIDDEN: missing system.entity_config' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  if length(v_legal) not between 1 and 200 then
    raise exception 'INVALID: the legal name must be 1 to 200 characters' using errcode = 'invalid_parameter_value';
  end if;
  if length(coalesce(v_brand, '')) > 200 or length(coalesce(v_address, '')) > 300 or length(coalesce(v_city, '')) > 100
     or length(coalesce(v_province, '')) > 100 or length(coalesce(v_postal, '')) > 20
     or length(coalesce(v_phone, '')) > 40 or length(coalesce(v_website, '')) > 200 then
    raise exception 'INVALID: a name, address or contact detail is too long' using errcode = 'invalid_parameter_value';
  end if;
  if v_email is not null and (length(v_email) > 200 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') then
    raise exception 'INVALID: the email address is not valid' using errcode = 'invalid_parameter_value';
  end if;

  select * into v_old from public.entities where id = p_entity for update;
  if not found then
    raise exception 'FORBIDDEN: unknown Entity' using errcode = 'insufficient_privilege';
  end if;
  if v_old.version <> p_expected_version then
    raise exception 'CONFLICT: the Entity changed since it was loaded' using errcode = 'serialization_failure';
  end if;
  select * into v_old_profile from public.entity_profiles where entity_id = p_entity;

  if v_legal <> v_old.legal_name or v_brand is distinct from v_old.brand_name then
    update public.entities set legal_name = v_legal, brand_name = v_brand where id = p_entity
    returning version into v_version;
  else
    v_version := v_old.version;
  end if;

  insert into public.entity_profiles (entity_id, address_line, city, province, postal_code, contact_email, contact_phone, website)
  values (p_entity, v_address, v_city, v_province, v_postal, v_email, v_phone, v_website)
  on conflict (entity_id) do update
    set address_line = excluded.address_line, city = excluded.city, province = excluded.province,
        postal_code = excluded.postal_code, contact_email = excluded.contact_email,
        contact_phone = excluded.contact_phone, website = excluded.website;

  insert into public.audit_events (entity_id, actor_type, actor_id, action, target_table, target_id,
                                   before_state, after_state)
  values (p_entity, 'user', auth.uid(), 'entities.identity_changed', 'entities', p_entity,
          jsonb_build_object('legal_name', v_old.legal_name, 'brand_name', v_old.brand_name,
                             'address_line', v_old_profile.address_line, 'city', v_old_profile.city,
                             'province', v_old_profile.province, 'postal_code', v_old_profile.postal_code,
                             'contact_email', v_old_profile.contact_email, 'contact_phone', v_old_profile.contact_phone,
                             'website', v_old_profile.website),
          jsonb_build_object('legal_name', v_legal, 'brand_name', v_brand, 'address_line', v_address, 'city', v_city,
                             'province', v_province, 'postal_code', v_postal, 'contact_email', v_email,
                             'contact_phone', v_phone, 'website', v_website));
  return v_version;
end
$$;

revoke all on function public.update_entity_identity(uuid, text, text, text, text, text, text, text, text, text, integer) from public;
grant execute on function public.update_entity_identity(uuid, text, text, text, text, text, text, text, text, text, integer) to authenticated;
