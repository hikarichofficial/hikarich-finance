-- P26: a recurring invoice or bill can be due on a fixed day of the month (Owner request, 7 October 2026).
-- Until now the due date was only "N days after the draft is made". A bill that is due every month on the
-- 20th (internet, IPL, rent) needs "due on day 20", not an offset. A new optional rule field
-- `due_day_of_month` (1-31) sets it; when empty the old offset rule applies unchanged, so every existing rule
-- behaves exactly as before. A day later than the month has (e.g. 31 in February) uses the month's last day.
-- If that day is before the document date, the due date falls in the next month.

alter table public.recurring_rules
  add column due_day_of_month smallint check (due_day_of_month between 1 and 31);

create function app_private.recurring_due_date(p_rule public.recurring_rules, p_occurrence date) returns date
language plpgsql immutable set search_path = pg_catalog, public as $$
declare
  v_month date;
  v_due date;
begin
  if p_rule.due_day_of_month is null then
    return p_occurrence + p_rule.due_offset_days;
  end if;
  v_month := date_trunc('month', p_occurrence)::date;
  v_due := least(v_month + (p_rule.due_day_of_month - 1), (v_month + interval '1 month - 1 day')::date);
  if v_due < p_occurrence then
    v_month := (v_month + interval '1 month')::date;
    v_due := least(v_month + (p_rule.due_day_of_month - 1), (v_month + interval '1 month - 1 day')::date);
  end if;
  return v_due;
end
$$;
revoke all on function app_private.recurring_due_date(public.recurring_rules, date) from public;

-- create_recurring_rule gets one more optional argument, so the old signature is replaced.
drop function public.create_recurring_rule(uuid, text, text, text, text, date, jsonb, integer, integer, date, text);

create function public.create_recurring_rule(
  p_entity uuid, p_key text, p_kind text, p_label text, p_frequency text, p_start_date date, p_template jsonb,
  p_interval integer default 1, p_due_offset_days integer default 0, p_end_date date default null,
  p_note text default null, p_due_day integer default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_replay uuid;
  v_id uuid;
begin
  perform app_private.planning_authorize(p_entity, 'planning.recurring_edit', 'creating a recurring rule');
  v_replay := app_private.idem_begin('recurring.create', p_entity, p_key,
    md5(jsonb_build_object('kind', p_kind, 'label', p_label, 'frequency', p_frequency, 'start', p_start_date,
                           'template', p_template, 'interval', p_interval, 'due_offset', p_due_offset_days,
                           'end', p_end_date, 'due_day', p_due_day)::text));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from public.entities where id = p_entity and status = 'active') then
    raise exception 'INVALID: unknown or disabled Entity' using errcode = 'invalid_parameter_value';
  end if;
  if p_kind not in ('invoice', 'bill', 'expense') then
    raise exception 'INVALID: unknown recurring kind' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_start_date);
  perform app_private.recurring_validate_template(p_entity, p_kind, p_template);

  insert into public.recurring_rules
    (entity_id, kind, label, frequency, interval_count, due_offset_days, due_day_of_month, start_date, end_date,
     next_occurrence_date, template, note)
  values
    (p_entity, p_kind, btrim(p_label), p_frequency, p_interval, p_due_offset_days, case when p_kind = 'expense' then null else p_due_day end, p_start_date, p_end_date,
     p_start_date, p_template, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  perform app_private.idem_complete('recurring.create', p_entity, p_key, 'recurring_rules', v_id);
  return v_id;
end
$$;

create or replace function public.update_recurring_rule(p_rule uuid, p_patch jsonb, p_expected_version integer default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.recurring_rules%rowtype;
  v_label text;
  v_template jsonb;
  v_interval integer;
  v_due_offset integer;
  v_due_day integer;
  v_end_date date;
  v_note text;
  v_has_end boolean := p_patch ? 'end_date';
  v_new_version integer;
begin
  select * into r from public.recurring_rules where id = p_rule for update;
  if not found then
    raise exception 'NOT_FOUND: recurring rule' using errcode = 'no_data_found';
  end if;
  perform app_private.planning_authorize(r.entity_id, 'planning.recurring_edit', 'changing a recurring rule');
  if r.status = 'ended' then
    raise exception 'INVALID: an ended recurring rule cannot be edited' using errcode = 'invalid_parameter_value';
  end if;
  if p_expected_version is not null and p_expected_version <> r.version then
    raise exception 'CONFLICT: the recurring rule changed since it was loaded' using errcode = 'integrity_constraint_violation';
  end if;

  v_label := coalesce(nullif(p_patch ->> 'label', ''), r.label);
  v_template := coalesce(p_patch -> 'template', r.template);
  v_interval := coalesce((p_patch ->> 'interval_count')::integer, r.interval_count);
  v_due_offset := coalesce((p_patch ->> 'due_offset_days')::integer, r.due_offset_days);
  v_due_day := case when p_patch ? 'due_day_of_month' then nullif(p_patch ->> 'due_day_of_month', '')::integer else r.due_day_of_month end;
  if r.kind = 'expense' then v_due_day := null; end if;
  v_end_date := case when v_has_end then nullif(p_patch ->> 'end_date', '')::date else r.end_date end;
  v_note := case when p_patch ? 'note' then nullif(btrim(coalesce(p_patch ->> 'note', '')), '') else r.note end;

  if p_patch ? 'template' then
    perform app_private.recurring_validate_template(r.entity_id, r.kind, v_template);
  end if;
  if v_end_date is not null and v_end_date < r.next_occurrence_date then
    raise exception 'INVALID: the end date cannot be before the next occurrence (%)', r.next_occurrence_date
      using errcode = 'invalid_parameter_value';
  end if;

  update public.recurring_rules
    set label = btrim(v_label), template = v_template, interval_count = v_interval, due_offset_days = v_due_offset, due_day_of_month = v_due_day,
        end_date = v_end_date, note = v_note
    where id = p_rule
    returning version into v_new_version;
  return v_new_version;
end
$$;

create or replace function app_private.recurring_create_invoice(p_rule public.recurring_rules, p_occurrence date) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare
  t jsonb := p_rule.template;
  v_currency public.currency_code := coalesce(nullif(t ->> 'currency', ''), app_private.entity_base_currency(p_rule.entity_id));
  v_rate numeric := nullif(t ->> 'exchange_rate', '')::numeric;
  v_account uuid := nullif(t ->> 'payment_account_id', '')::uuid;
  v_channel uuid := nullif(t ->> 'payment_channel_id', '')::uuid;
  v_due date := app_private.recurring_due_date(p_rule, p_occurrence);
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

create or replace function app_private.recurring_create_bill(p_rule public.recurring_rules, p_occurrence date) returns uuid
language plpgsql set search_path = pg_catalog, public as $$
declare
  t jsonb := p_rule.template;
  v_currency public.currency_code := coalesce(nullif(t ->> 'currency', ''), app_private.entity_base_currency(p_rule.entity_id));
  v_rate numeric := nullif(t ->> 'exchange_rate', '')::numeric;
  v_ref text := nullif(btrim(coalesce(t ->> 'vendor_reference', '')), '');
  v_due date := app_private.recurring_due_date(p_rule, p_occurrence);
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

revoke all on function public.create_recurring_rule(uuid, text, text, text, text, date, jsonb, integer, integer, date, text, integer) from public, anon;
grant execute on function public.create_recurring_rule(uuid, text, text, text, text, date, jsonb, integer, integer, date, text, integer) to authenticated;
