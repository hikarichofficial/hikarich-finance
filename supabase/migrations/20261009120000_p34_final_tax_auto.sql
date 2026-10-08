-- P34 (decision 346, owner request of 8 October 2026): the final tax (PPh Final UMKM) of a month is computed and
-- recorded BY ITSELF, on the first day after the month ends, so nobody has to press "Hitung Pajak Final Bulan
-- Ini". The running month keeps its live estimate (decision 342).
--   * app_private.tax_final_compute_auto(entity, period): the very same computation, journal and tax ledger as
--     public.tax_final_compute, built from the function as it stands today by exact text replacement (the sign-in,
--     permission and idempotency-key steps are dropped, because no person is signed in in a scheduled job; the
--     computation is naturally repeatable: an unchanged tax returns the existing record, a changed one records a
--     new revision with the difference only). If the old text is not found the migration fails.
--   * app_private.tax_final_auto_run(): for every active Entity, the month just ended and the month before it are
--     (re)checked, and any earlier month of the last two years that has no record yet is computed (a missed day
--     heals itself). A month whose evaluation is not "auto_determined" (no profile, engine off, over the ceiling,
--     ...) is skipped; one failing Entity or month never blocks the others.
--   * Scheduled when the database has pg_cron, three times a day just after midnight in WIT, WITA and WIB, like the
--     recurring-transactions job; the Entity's own date decides which month has ended.
-- The public command tax_final_compute stays (it is how a person could compute by hand) but the screen no longer
-- offers it.

do $mig$
declare
  v_def text;
  v_from integer;
  v_to integer;
  v_pairs text[][] := array[
    array[$o$FUNCTION public.tax_final_compute(p_entity uuid, p_key text, p_period date)$o$,
          $n$FUNCTION app_private.tax_final_compute_auto(p_entity uuid, p_period date)$n$],
    array[$o$      perform app_private.idem_complete('tax.final_compute', p_entity, p_key, 'tax_determinations', v_old.id);
$o$, ''],
    array[$o$  perform app_private.idem_complete('tax.final_compute', p_entity, p_key, 'tax_determinations', v_new);
$o$, '']
  ];
  i integer;
begin
  v_def := pg_catalog.pg_get_functiondef('public.tax_final_compute(uuid, text, date)'::regprocedure);
  -- drop the sign-in, permission and replay steps, up to the check that the Entity is active
  v_from := position($o$  if auth.uid() is null then$o$ in v_def);
  v_to := position($o$  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then$o$ in v_def);
  if v_from = 0 or v_to = 0 or v_to <= v_from then
    raise exception 'p34 patch: the sign-in steps of tax_final_compute were not found';
  end if;
  v_def := substr(v_def, 1, v_from - 1) || substr(v_def, v_to);
  for i in 1 .. array_length(v_pairs, 1) loop
    if position(v_pairs[i][1] in v_def) = 0 then
      raise exception 'p34 patch % not found in tax_final_compute', i;
    end if;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  end loop;
  if position('auth.uid()' in v_def) > 0 or position('p_key' in v_def) > 0 then
    raise exception 'p34 patch: sign-in or key references remain in the automatic function';
  end if;
  execute v_def;
end
$mig$;

revoke all on function app_private.tax_final_compute_auto(uuid, date) from public;

create function app_private.tax_final_auto_run() returns integer
language plpgsql set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
  v_prev date;
  v_period date;
  k integer;
  e jsonb;
  v_n integer := 0;
begin
  for v_entity in select id from public.entities where status = 'active' order by id loop
    v_prev := (date_trunc('month', app_private.entity_today(v_entity)) - interval '1 month')::date;
    for k in 0 .. 23 loop
      v_period := (v_prev - make_interval(months => k))::date;
      begin
        e := app_private.tax_final_evaluate(v_entity, v_period);
        if e ->> 'status' = 'auto_determined'
           and (k <= 1 or not exists (
                  select 1 from public.tax_determinations d
                  where d.entity_id = v_entity and d.tax_kind = 'final_umkm' and d.tax_period = v_period
                    and d.source_type = 'period' and d.superseded_at is null)) then
          perform app_private.tax_final_compute_auto(v_entity, v_period);
          v_n := v_n + 1;
        end if;
      exception when others then
        raise warning 'final tax auto-run failed for entity % month %: %', v_entity, v_period, sqlerrm;
      end;
    end loop;
  end loop;
  return v_n;
end
$$;

revoke all on function app_private.tax_final_auto_run() from public;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('hikarich-final-tax-auto-run', '20 15-17 * * *', 'select app_private.tax_final_auto_run()');
  else
    raise notice 'pg_cron is not available here: the final tax auto-run is not scheduled';
  end if;
end
$$;
