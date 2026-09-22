-- P10 (Step 15 §14) part 2: the recurring generation engine.
-- Authority: Step 15 §14 ("generate drafts by default", failed-generation retry, editing a rule never
-- mutates historical generated transactions), Step 13 §9 (idempotency), §14 (outbox/background jobs),
-- Step 01 #22/#23/#26.
--
-- Design
--   * app_private.recurring_create_invoice/bill/expense reuse the EXACT header-check / line-preparation /
--     line-write helpers the manual create_*_draft commands use (P5/P6). They differ only in skipping the
--     auth.uid()/permission gate, because the scheduled path runs with no signed-in user at all — the gate
--     for the whole batch is checked once, up front, in run_due_recurring_occurrences (Engineering
--     decision, docs/DECISIONS.md): a service_role caller is authorized structurally (never exposed to
--     anon/authenticated, see grants below); an authenticated caller needs planning.recurring_run.
--   * generate_recurring_occurrence processes exactly one occurrence — the rule's current
--     next_occurrence_date — per call, exactly as Step 15 §14 specifies ("at most one due occurrence per
--     rule per invocation"). A failure never aborts the batch: it is caught, recorded on the (append-only
--     once successful) recurring_occurrences row, and next_occurrence_date is left untouched so the very
--     next run retries the same date. A success advances next_occurrence_date and, once the rule has
--     passed its end_date, ends the rule automatically.
--   * run_due_recurring_occurrences takes no idempotency key. Unlike a single-resource command (one call,
--     one created row, one idem_complete result), this is a batch over however many rules are due, so a
--     key-to-single-result cache does not fit it. Its idempotency is structural instead: each rule row is
--     claimed with `for update skip locked` (two concurrent runs never double-process the same rule), and
--     recurring_occurrences' UNIQUE (recurring_rule_id, occurrence_date) makes a second attempt at the
--     same occurrence a no-op rather than a duplicate document. A retried or overlapping call is therefore
--     already safe without a replay cache.

-- Adds p_interval periods to p_from. Monthly preserves the day-of-month, clamping to the target month's
-- last day when the original day does not exist there (e.g. 31 Jan + 1 month lands on 28/29 Feb, it never
-- rolls forward into March the way plain date + interval arithmetic would).
create function app_private.recurring_next_date(p_from date, p_frequency text, p_interval integer) returns date
language plpgsql immutable as $$
declare
  v_day integer := extract(day from p_from)::integer;
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

-- ------------------------------------------------------------ per-kind document creation
-- Mirrors create_invoice_draft (P5) minus the actor gate and idempotency key: the batch caller already
-- authorized the run, and per-occurrence idempotency comes from recurring_occurrences' unique constraint.
create function app_private.recurring_create_invoice(p_rule public.recurring_rules, p_occurrence date) returns uuid
language plpgsql as $$
declare
  t jsonb := p_rule.template;
  v_currency public.currency_code := coalesce(nullif(t ->> 'currency', ''), app_private.entity_base_currency(p_rule.entity_id));
  v_rate numeric := nullif(t ->> 'exchange_rate', '')::numeric;
  v_account uuid := nullif(t ->> 'payment_account_id', '')::uuid;
  v_channel uuid := nullif(t ->> 'payment_channel_id', '')::uuid;
  v_due date := p_occurrence + p_rule.due_offset_days;
  v_prep jsonb;
  v_id uuid;
begin
  perform app_private.invoice_check_header(
    p_rule.entity_id, nullif(t ->> 'customer_id', '')::uuid, p_occurrence, v_due, v_currency, v_rate,
    v_account, v_channel);
  v_prep := app_private.invoice_prepare_lines(p_rule.entity_id, v_currency, coalesce(t -> 'lines', '[]'::jsonb));

  insert into public.invoices
    (entity_id, customer_id, currency, exchange_rate, issue_date, due_date, payment_account_id, payment_channel_id,
     notes, terms, payment_note, internal_note, subtotal, discount_total, total)
  values
    (p_rule.entity_id, (t ->> 'customer_id')::uuid, v_currency, v_rate, p_occurrence, v_due, v_account, v_channel,
     nullif(btrim(coalesce(t ->> 'notes', '')), ''), nullif(btrim(coalesce(t ->> 'terms', '')), ''),
     nullif(btrim(coalesce(t ->> 'payment_note', '')), ''), nullif(btrim(coalesce(t ->> 'internal_note', '')), ''),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'discount_total')::numeric, (v_prep ->> 'total')::numeric)
  returning id into v_id;
  perform app_private.invoice_write_lines(p_rule.entity_id, v_id, v_prep);
  return v_id;
end
$$;

-- Mirrors create_bill_draft (P6).
create function app_private.recurring_create_bill(p_rule public.recurring_rules, p_occurrence date) returns uuid
language plpgsql as $$
declare
  t jsonb := p_rule.template;
  v_currency public.currency_code := coalesce(nullif(t ->> 'currency', ''), app_private.entity_base_currency(p_rule.entity_id));
  v_rate numeric := nullif(t ->> 'exchange_rate', '')::numeric;
  v_ref text := nullif(btrim(coalesce(t ->> 'vendor_reference', '')), '');
  v_due date := p_occurrence + p_rule.due_offset_days;
  v_prep jsonb;
  v_id uuid;
begin
  perform app_private.bill_check_header(
    p_rule.entity_id, nullif(t ->> 'vendor_id', '')::uuid, p_occurrence, v_due, v_currency, v_rate, v_ref);
  v_prep := app_private.purchase_prepare_lines(p_rule.entity_id, v_currency, coalesce(t -> 'lines', '[]'::jsonb));

  insert into public.bills
    (entity_id, vendor_id, vendor_reference, currency, exchange_rate, bill_date, due_date, notes, internal_note,
     subtotal, total)
  values
    (p_rule.entity_id, (t ->> 'vendor_id')::uuid, v_ref, v_currency, v_rate, p_occurrence, v_due,
     nullif(btrim(coalesce(t ->> 'notes', '')), ''), nullif(btrim(coalesce(t ->> 'internal_note', '')), ''),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'total')::numeric)
  returning id into v_id;
  perform app_private.bill_write_lines(p_rule.entity_id, v_id, v_prep);
  return v_id;
end
$$;

-- Mirrors create_expense_draft (P6). due_offset_days is meaningless for an expense (Step 15 §14: it
-- applies to invoice/bill due dates only), so the occurrence date is used as-is.
create function app_private.recurring_create_expense(p_rule public.recurring_rules, p_occurrence date) returns uuid
language plpgsql as $$
declare
  t jsonb := p_rule.template;
  v_account uuid := (t ->> 'account_id')::uuid;
  v_payee uuid := nullif(t ->> 'payee_id', '')::uuid;
  v_name text := case when nullif(t ->> 'payee_id', '') is null
                       then nullif(btrim(coalesce(t ->> 'payee_name', '')), '') else null end;
  v_ref text := nullif(btrim(coalesce(t ->> 'receipt_reference', '')), '');
  v_rate numeric := nullif(t ->> 'exchange_rate', '')::numeric;
  v_currency public.currency_code;
  v_prep jsonb;
  v_id uuid;
begin
  v_currency := app_private.expense_check_header(p_rule.entity_id, v_payee, v_name, v_account, p_occurrence, v_rate, v_ref);
  v_prep := app_private.purchase_prepare_lines(p_rule.entity_id, v_currency, coalesce(t -> 'lines', '[]'::jsonb));

  insert into public.expenses
    (entity_id, payee_id, payee_name, receipt_reference, financial_account_id, currency, exchange_rate, expense_date,
     notes, internal_note, subtotal, total)
  values
    (p_rule.entity_id, v_payee, v_name, v_ref, v_account, v_currency, v_rate, p_occurrence,
     nullif(btrim(coalesce(t ->> 'notes', '')), ''), nullif(btrim(coalesce(t ->> 'internal_note', '')), ''),
     (v_prep ->> 'subtotal')::numeric, (v_prep ->> 'total')::numeric)
  returning id into v_id;
  perform app_private.expense_write_lines(p_rule.entity_id, v_id, v_prep);
  return v_id;
end
$$;

-- ------------------------------------------------------------ per-rule attempt
-- Generates (or retries) exactly the rule's current next_occurrence_date. Caller must hold the rule row
-- locked (run_due_recurring_occurrences does this with `for update skip locked`) so no two runs can ever
-- race on the same rule.
create function app_private.generate_recurring_occurrence(p_rule public.recurring_rules) returns void
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
    v_next := app_private.recurring_next_date(p_rule.next_occurrence_date, p_rule.frequency, p_rule.interval_count);
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

  v_next := app_private.recurring_next_date(p_rule.next_occurrence_date, p_rule.frequency, p_rule.interval_count);
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

-- ------------------------------------------------------------ entry point
-- Processes every active rule of the Entity whose next_occurrence_date has come due, at most one
-- occurrence per rule per call. Callable by:
--   * service_role — the scheduled/background path (Step 13 §14). No signed-in user exists there, so it
--     is authorized structurally: this privilege is never granted to anon or authenticated (grants below).
--   * an authenticated user holding planning.recurring_run — the manual "generate now" action.
create function public.run_due_recurring_occurrences(p_entity uuid, p_as_of date default null)
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
    v_count := v_count + 1;
  end loop;

  return v_count;
end
$$;

grant execute on function public.run_due_recurring_occurrences(uuid, date) to authenticated;
grant execute on function public.run_due_recurring_occurrences(uuid, date) to service_role;
