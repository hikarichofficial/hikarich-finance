-- P15 decision 303 (finding #102): two small behaviours of the recurring engine.
--
-- 1. A monthly rule that starts on the 29th, 30th or 31st drifted to the 28th for good after one short month
--    (31 Jan -> 28 Feb -> 28 Mar ...). The next date now counts from the day the rule STARTED on, capped at the last
--    day of each month (31 Jan -> 28 Feb -> 31 Mar). Weekly and custom-day rules are unchanged.
-- 2. "Generate now" returned how many rules it TRIED, so a failed occurrence counted as a success. It now returns how
--    many occurrences were actually generated; a failed one is still recorded (and retried) exactly as before.
--
-- The old three-argument recurring_next_date stays as it is (it has no other caller after this).

create function app_private.recurring_next_date(p_from date, p_frequency text, p_interval integer, p_anchor_day integer)
returns date
language plpgsql immutable as $$
declare
  v_day integer := coalesce(p_anchor_day, extract(day from p_from)::integer);
  v_month_start date;
begin
  if p_frequency = 'weekly' then
    return p_from + make_interval(days => 7 * p_interval);
  elsif p_frequency = 'custom_days' then
    return p_from + make_interval(days => p_interval);
  elsif p_frequency = 'monthly' then
    v_month_start := (date_trunc('month', p_from) + make_interval(months => p_interval))::date;
    return least(v_month_start + (v_day - 1), (date_trunc('month', v_month_start) + interval '1 month - 1 day')::date);
  else
    raise exception 'INVALID: unknown recurring frequency %', p_frequency using errcode = 'invalid_parameter_value';
  end if;
end
$$;
revoke all on function app_private.recurring_next_date(date, text, integer, integer) from public;

create or replace function app_private.generate_recurring_occurrence(p_rule public.recurring_rules) returns void
language plpgsql as $$
declare
  v_existing public.recurring_occurrences%rowtype;
  v_existing_found boolean;
  v_generated_id uuid;
  v_table text;
  v_next date;
  v_ends boolean;
  v_error text;
begin
  select * into v_existing from public.recurring_occurrences
  where recurring_rule_id = p_rule.id and occurrence_date = p_rule.next_occurrence_date;
  v_existing_found := found;

  if v_existing_found and v_existing.status = 'generated' then
    -- Defensive only (the row lock should make this unreachable): already generated, just advance.
    v_next := app_private.recurring_next_date(p_rule.next_occurrence_date, p_rule.frequency, p_rule.interval_count, extract(day from p_rule.start_date)::integer);
    v_ends := p_rule.end_date is not null and v_next > p_rule.end_date;
    update public.recurring_rules
      set next_occurrence_date = v_next, last_generated_date = p_rule.next_occurrence_date,
          status = case when v_ends then 'ended' else status end,
          ended_at = case when v_ends then now() else ended_at end,
          ended_reason = case when v_ends then 'Reached its end date after the last scheduled occurrence' else ended_reason end
      where id = p_rule.id;
    return;
  end if;

  begin
    if p_rule.kind = 'invoice' then
      v_generated_id := app_private.recurring_create_invoice(p_rule, p_rule.next_occurrence_date);
      v_table := 'invoices';
    elsif p_rule.kind = 'bill' then
      v_generated_id := app_private.recurring_create_bill(p_rule, p_rule.next_occurrence_date);
      v_table := 'bills';
    else
      v_generated_id := app_private.recurring_create_expense(p_rule, p_rule.next_occurrence_date);
      v_table := 'expenses';
    end if;
  exception when others then
    get stacked diagnostics v_error = message_text;
    if v_existing_found then
      update public.recurring_occurrences
        set status = 'failed', attempts = v_existing.attempts + 1, last_attempted_at = now(), last_error = v_error
        where id = v_existing.id;
    else
      insert into public.recurring_occurrences
        (entity_id, recurring_rule_id, occurrence_date, status, attempts, last_attempted_at, last_error)
      values (p_rule.entity_id, p_rule.id, p_rule.next_occurrence_date, 'failed', 1, now(), v_error);
    end if;
    insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
    values (p_rule.entity_id, 'RecurringGenerationFailed', 'recurring_rules', p_rule.id,
            jsonb_build_object('rule_id', p_rule.id, 'occurrence_date', p_rule.next_occurrence_date, 'error', v_error));
    return; -- next_occurrence_date stays put: the next run retries the same date (Step 15 §14).
  end;

  if v_existing_found then
    update public.recurring_occurrences
      set status = 'generated', generated_table = v_table, generated_id = v_generated_id,
          attempts = v_existing.attempts + 1, last_attempted_at = now(), last_error = null
      where id = v_existing.id;
  else
    insert into public.recurring_occurrences
      (entity_id, recurring_rule_id, occurrence_date, status, generated_table, generated_id)
    values (p_rule.entity_id, p_rule.id, p_rule.next_occurrence_date, 'generated', v_table, v_generated_id);
  end if;

  v_next := app_private.recurring_next_date(p_rule.next_occurrence_date, p_rule.frequency, p_rule.interval_count, extract(day from p_rule.start_date)::integer);
  v_ends := p_rule.end_date is not null and v_next > p_rule.end_date;
  update public.recurring_rules
    set next_occurrence_date = v_next, last_generated_date = p_rule.next_occurrence_date,
        status = case when v_ends then 'ended' else status end,
        ended_at = case when v_ends then now() else ended_at end,
        ended_reason = case when v_ends then 'Reached its end date after the last scheduled occurrence' else ended_reason end
    where id = p_rule.id;

  insert into public.outbox_events (entity_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_rule.entity_id, 'RecurringOccurrenceGenerated', v_table, v_generated_id,
          jsonb_build_object('rule_id', p_rule.id, 'occurrence_date', p_rule.next_occurrence_date));
end
$$;

create or replace function public.run_due_recurring_occurrences(p_entity uuid, p_as_of date default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_as_of date;
  v_rule public.recurring_rules%rowtype;
  v_count integer := 0;
begin
  if auth.role() = 'service_role' then
    perform set_config('app.actor_type', 'system', true);
  else
    perform app_private.planning_authorize(p_entity, 'planning.recurring_run', 'generating recurring occurrences now');
  end if;

  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;

  v_as_of := coalesce(p_as_of, app_private.entity_today(p_entity));
  perform app_private.assert_business_date(v_as_of);

  for v_rule in
    select * from public.recurring_rules
    where entity_id = p_entity and status = 'active' and next_occurrence_date <= v_as_of
    order by next_occurrence_date
    for update skip locked
  loop
    perform app_private.generate_recurring_occurrence(v_rule);
    -- v_rule is the row as it was before the attempt, so next_occurrence_date is the date that was attempted.
    if exists (select 1 from public.recurring_occurrences o
               where o.recurring_rule_id = v_rule.id and o.occurrence_date = v_rule.next_occurrence_date
                 and o.status = 'generated') then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end
$$;
