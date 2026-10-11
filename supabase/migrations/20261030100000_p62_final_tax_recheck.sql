-- P62 (decision 408, owner report of 12 October 2026): an invoice dated in a month that had already been
-- computed (issued 23.29 WITA for 28 September, nine minutes after the first automatic run had stored 0 for
-- September) left the final tax at 0 until the next day, and a month older than the previous one was never
-- looked at again at all, because the run only re-checked the last two months. The owner's rule: the moment any
-- invoice or income is posted, its tax must be read.
--   * Event driven: posting (or voiding) an invoice, an income entry or a marketplace settlement dated in a month
--     that has already ended queues that month in app_private.tax_final_recheck_queue; a deferred trigger on the
--     queue runs the computation when the transaction commits, i.e. after the whole posting has finished and
--     its figures are final. The tax is therefore recorded in the same instant, and a failure there never
--     blocks the posting: the month stays in the queue.
--   * Safety net: a job every 15 minutes retries what is still queued (an empty queue is a single index read, so
--     it costs nothing); a row that failed 20 times stays visible with its last error and is left to the sweep.
--   * The sweep (three runs a day around midnight, unchanged) now re-evaluates EVERY month of the last two
--     years, not only the last two. The computation is repeatable: an unchanged tax returns the existing record,
--     a changed one records a new revision with the difference only.
create table app_private.tax_final_recheck_queue (
  entity_id uuid not null,
  period date not null check (period = date_trunc('month', period)::date),
  queued_at timestamptz not null default now(),
  attempts integer not null default 0,
  last_error text,
  primary key (entity_id, period)
);
revoke all on table app_private.tax_final_recheck_queue from public;

-- Run one month now: compute when the evaluation says it can be, leave the queue when done or when there is
-- nothing to compute, keep the row (with the error) when the computation fails.
create function app_private.tax_final_process_period(p_entity uuid, p_period date) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  e jsonb;
begin
  begin
    e := app_private.tax_final_evaluate(p_entity, p_period);
    if e ->> 'status' = 'auto_determined' then
      perform app_private.tax_final_compute_auto(p_entity, p_period);
    end if;
    delete from app_private.tax_final_recheck_queue where entity_id = p_entity and period = p_period;
  exception when others then
    update app_private.tax_final_recheck_queue
       set attempts = attempts + 1, last_error = left(sqlerrm, 500)
     where entity_id = p_entity and period = p_period;
    raise warning 'final tax recheck failed for entity % month %: %', p_entity, p_period, sqlerrm;
  end;
end
$$;
revoke all on function app_private.tax_final_process_period(uuid, date) from public;

-- Queue a month, only when it has ended (the running month stays a live estimate).
create function app_private.tax_final_enqueue(p_entity uuid, p_date date) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_period date := date_trunc('month', p_date)::date;
begin
  if p_date is null or v_period >= date_trunc('month', app_private.entity_today(p_entity))::date then
    return;
  end if;
  insert into app_private.tax_final_recheck_queue (entity_id, period) values (p_entity, v_period)
  on conflict (entity_id, period) do nothing;
end
$$;
revoke all on function app_private.tax_final_enqueue(uuid, date) from public;

-- tg_argv: the date column, the status column and the status that counts as turnover.
create function app_private.tg_tax_final_enqueue() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_date text := tg_argv[0];
  v_status text := tg_argv[1];
  v_counts text := tg_argv[2];
  n jsonb;
  o jsonb;
begin
  if tg_op in ('INSERT', 'UPDATE') then
    n := to_jsonb(new);
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    o := to_jsonb(old);
  end if;
  if n is not null and n ->> v_status = v_counts then
    perform app_private.tax_final_enqueue((n ->> 'entity_id')::uuid, (n ->> v_date)::date);
  end if;
  if o is not null and o ->> v_status = v_counts then
    perform app_private.tax_final_enqueue((o ->> 'entity_id')::uuid, (o ->> v_date)::date);
  end if;
  return null;
end
$$;
revoke all on function app_private.tg_tax_final_enqueue() from public;

create trigger tg_tax_final_enqueue after insert or update or delete on public.invoices
  for each row execute function app_private.tg_tax_final_enqueue('issue_date', 'status', 'issued');
create trigger tg_tax_final_enqueue after insert or update or delete on public.income_entries
  for each row execute function app_private.tg_tax_final_enqueue('entry_date', 'status', 'recorded');
create trigger tg_tax_final_enqueue after insert or update or delete on public.marketplace_settlements
  for each row execute function app_private.tg_tax_final_enqueue('settlement_date', 'status', 'confirmed');

-- The deferred step: when the transaction that queued the month commits, compute it.
create function app_private.tg_tax_final_queue_run() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.tax_final_process_period(new.entity_id, new.period);
  return null;
end
$$;
revoke all on function app_private.tg_tax_final_queue_run() from public;

create constraint trigger tg_tax_final_queue_run after insert on app_private.tax_final_recheck_queue
  deferrable initially deferred for each row execute function app_private.tg_tax_final_queue_run();

-- The safety net: retry what is still queued.
create function app_private.tax_final_process_queue() returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r record;
  v_n integer := 0;
begin
  for r in select entity_id, period from app_private.tax_final_recheck_queue where attempts < 20 order by queued_at limit 50 loop
    perform app_private.tax_final_process_period(r.entity_id, r.period);
    v_n := v_n + 1;
  end loop;
  return v_n;
end
$$;
revoke all on function app_private.tax_final_process_queue() from public;

create or replace function app_private.tax_final_auto_run() returns integer
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
        if e ->> 'status' = 'auto_determined' then
          perform app_private.tax_final_compute_auto(v_entity, v_period);
          v_n := v_n + 1;
        end if;
        delete from app_private.tax_final_recheck_queue where entity_id = v_entity and period = v_period;
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
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('hikarich-final-tax-recheck-queue', '*/15 * * * *', 'select app_private.tax_final_process_queue()');
  else
    raise notice 'pg_cron is not available here: the final tax queue is not retried automatically';
  end if;
end
$$;
