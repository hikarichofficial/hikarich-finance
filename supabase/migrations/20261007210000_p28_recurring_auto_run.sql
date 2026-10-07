-- P28: recurring transactions run by themselves (Owner request, 7 October 2026: once a rule is set up, on its
-- date the invoice / expense / bill must simply be there as a draft; the Owner or staff posts it later).
-- Until now a draft was only created when someone pressed "Jalankan yang Jatuh Tempo". This adds the missing
-- scheduler: a database job that, shortly after midnight of the Entity's own day, runs the SAME engine the
-- button uses (public.run_due_recurring_occurrences on its scheduled/service_role path). Nothing about WHAT is
-- generated changes: drafts only (never posted), one occurrence per rule per run, failures recorded and retried
-- on the next run, each Entity isolated so one failing Entity can never block the others. The manual button
-- stays for "run it now".

create function app_private.run_all_due_recurring() returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare
  v_prev text := current_setting('request.jwt.claims', true);
  v_entity uuid;
  v_total integer := 0;
begin
  -- No signed-in user exists in a scheduled job: take the engine's structurally authorized service path.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  for v_entity in select id from public.entities where status = 'active' order by id loop
    begin
      v_total := v_total + public.run_due_recurring_occurrences(v_entity);
    exception when others then
      raise warning 'recurring auto-run failed for entity %: %', v_entity, sqlerrm;
    end;
  end loop;
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return v_total;
end
$$;

revoke all on function app_private.run_all_due_recurring() from public;

-- Schedule it when the database has pg_cron (Supabase does; a bare test database does not). 15:10, 16:10 and
-- 17:10 UTC are just after midnight in WIT, WITA and WIB; a run with nothing due does nothing, so the extra
-- runs only cover Entities in the other time zones.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('hikarich-recurring-auto-run', '10 15-17 * * *', 'select app_private.run_all_due_recurring()');
  else
    raise notice 'pg_cron is not available here: the recurring auto-run is not scheduled';
  end if;
end
$$;
