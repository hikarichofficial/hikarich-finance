-- P14 decision 248 (OWNER answer to decision 237): tax periods follow the Entity's own calendar.
--
-- "Today" for every Entity rule (tax periods over or not, due dates, aging) is already
-- `app_private.entity_today`, i.e. the date in the Entity's own timezone; fiscal years already follow
-- `entities.fiscal_year_start_month`. Indonesian defaults stay as they are (Asia/Jakarta, January: the
-- tax year equals the calendar year unless the books use another year). This migration lets the OWNER
-- (or anyone granted `system.entity_config`) change both from Settings (Step 09 §21 "fiscal
-- year/base currency/timezone"):
--   * timezone: any valid IANA name (the existing validation trigger checks it). Stored dates never
--     move; only what "today" means for the Entity changes from the moment of the change.
--   * fiscal year start month: only while the Entity has no accounting period yet, because every
--     period already created is labelled with a fiscal year computed from it.
-- Needs a recent step-up and a written reason; optimistic concurrency on `entities.version`; the change
-- is recorded in the Audit Log with the reason (the row trigger records before/after as well).

create function public.update_entity_time_settings(
  p_entity uuid, p_timezone text, p_fiscal_year_start_month integer, p_expected_version integer,
  p_reason text)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_old public.entities%rowtype;
  v_version integer;
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
  if p_reason is null or length(btrim(p_reason)) < 5 or length(p_reason) > 500 then
    raise exception 'INVALID: a reason of 5 to 500 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  if p_timezone is null
     or not exists (select 1 from pg_catalog.pg_timezone_names where name = p_timezone) then
    raise exception 'INVALID: unknown timezone' using errcode = 'invalid_parameter_value';
  end if;
  if p_fiscal_year_start_month is null or p_fiscal_year_start_month not between 1 and 12 then
    raise exception 'INVALID: fiscal year start month must be 1 to 12' using errcode = 'invalid_parameter_value';
  end if;

  select * into v_old from public.entities where id = p_entity for update;
  if not found then
    raise exception 'FORBIDDEN: unknown Entity' using errcode = 'insufficient_privilege';
  end if;
  if v_old.version <> p_expected_version then
    raise exception 'CONFLICT: the Entity changed since it was loaded' using errcode = 'serialization_failure';
  end if;
  if p_fiscal_year_start_month <> v_old.fiscal_year_start_month
     and exists (select 1 from public.accounting_periods where entity_id = p_entity) then
    raise exception 'CONFLICT: the fiscal year start cannot change once accounting periods exist'
      using errcode = 'integrity_constraint_violation';
  end if;
  if p_timezone = v_old.timezone and p_fiscal_year_start_month = v_old.fiscal_year_start_month then
    return v_old.version;
  end if;

  update public.entities
     set timezone = p_timezone, fiscal_year_start_month = p_fiscal_year_start_month
   where id = p_entity
  returning version into v_version;

  insert into public.audit_events (entity_id, actor_type, actor_id, action, target_table, target_id,
                                   before_state, after_state, reason)
  values (p_entity, 'user', auth.uid(), 'entities.time_settings_changed', 'entities', p_entity,
          jsonb_build_object('timezone', v_old.timezone, 'fiscal_year_start_month', v_old.fiscal_year_start_month),
          jsonb_build_object('timezone', p_timezone, 'fiscal_year_start_month', p_fiscal_year_start_month),
          btrim(p_reason));
  return v_version;
end
$$;

revoke all on function public.update_entity_time_settings(uuid, text, integer, integer, text) from public;
grant execute on function public.update_entity_time_settings(uuid, text, integer, integer, text) to authenticated;
