-- P15 decision 303 (OWNER, 6 October 2026: "zona waktu kamu bantu ubah ke WITA", for the Personal Entity only):
-- the Personal Entity (code 'hikarich') moves from Asia/Jakarta (WIB) to Asia/Makassar (WITA), the same change
-- Administrasi > Pengaturan makes (`update_entity_time_settings`), done here because that screen needs the OWNER's
-- authenticator code. Stored dates never move; only what "today" means for this Entity changes, from now on. The
-- PT Entity is left as it is. A no-op when the Entity does not exist or is already on WITA (a fresh database, tests).
do $$
declare
  v_entity public.entities%rowtype;
begin
  select * into v_entity from public.entities
  where code = 'hikarich' and entity_type = 'personal' and timezone = 'Asia/Jakarta' for update;
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
