-- Decision 391 (OWNER, 9 October 2026): which of the Entity's two names a financial document carries.
-- The invoice already put the legal name first with the brand under it (decision 272's own rule), but the
-- payslip took whichever name was set and preferred the brand, so a PT's payslip could go out under a trading
-- name. A payslip is a tax document; the legal name belongs on it. Rather than hard-code that per document,
-- the Entity now says once what its documents are headed with, and every document follows the same answer:
--   legal  -- the legal name alone
--   brand  -- the brand name alone (falling back to the legal name when there is none)
--   both   -- the legal name, the brand name under it (the behaviour so far, and the default)
-- Presentation only: nothing about an amount, a tax or an authorization depends on it.

create function public.set_document_name_style(p_entity uuid, p_style text) returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
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
  if p_style is null or p_style not in ('legal', 'brand', 'both') then
    raise exception 'INVALID: choose legal, brand or both' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.entity_settings (entity_id, setting_key, setting_value, created_by, updated_by)
  values (p_entity, 'document.name_style', to_jsonb(p_style), auth.uid(), auth.uid())
  on conflict (entity_id, setting_key) do update
    set setting_value = excluded.setting_value, updated_at = now(), updated_by = auth.uid(),
        version = public.entity_settings.version + 1;

  return p_style;
end
$$;

revoke all on function public.set_document_name_style(uuid, text) from public, anon;
grant execute on function public.set_document_name_style(uuid, text) to authenticated;
