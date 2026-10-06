-- P15 decision 303 (correction to migration 20261006150000): the Personal Entity ("Hikarich", code 'hikarich') is
-- stored with entity_type 'company', not 'personal', so the previous migration found nothing to change. This one
-- selects it by its code only. Same change as `update_entity_time_settings` makes (Asia/Jakarta -> Asia/Makassar,
-- WITA), audited with a system actor and the reason; stored dates never move, only what "today" means from now on.
-- A no-op when the Entity does not exist or is already on WITA (a fresh database, the tests). PT is left as it is.
do $$
declare
  v_entity public.entities%rowtype;
begin
  select * into v_entity from public.entities where code = 'hikarich' and timezone = 'Asia/Jakarta' for update;
  if not found then
    return;
  end if;

  update public.entities set timezone = 'Asia/Makassar' where id = v_entity.id;

  insert into public.audit_events (entity_id, actor_type, actor_id, action, target_table, target_id,
                                   before_state, after_state, reason)
  values (v_entity.id, 'system', null, 'entities.time_settings_changed', 'entities', v_entity.id,
          jsonb_build_object('timezone', v_entity.timezone, 'fiscal_year_start_month', v_entity.fiscal_year_start_month),
          jsonb_build_object('timezone', 'Asia/Makassar', 'fiscal_year_start_month', v_entity.fiscal_year_start_month),
          'Permintaan OWNER 6 Oktober 2026: zona waktu Entity Pribadi diubah ke WITA');
end
$$;
