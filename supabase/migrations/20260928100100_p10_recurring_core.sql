-- P10 (Step 15 §14) part 1: recurring rules and their occurrence history.
-- Authority: Step 01 #26, Step 13 §14-15 (events/outbox, background jobs), Step 16 §19.
--
-- Design
--   * A recurring rule stores a reusable command template (jsonb) for exactly one kind of document:
--     invoice (AR/income), bill (AP) or expense. There is no separate non-invoiced "income" entity in
--     this build (docs/DECISIONS.md records this mapping); a recurring "income" template is a recurring
--     invoice.
--   * The template holds everything create_invoice_draft/create_bill_draft/create_expense_draft need
--     except the per-occurrence dates, entity_id and idempotency_key (Step 15 §14: "generate drafts by
--     default" — the generator writes plain drafts, never issues/submits them itself).
--   * `recurring_occurrences` is the idempotent, append-only record of every generation attempt. The
--     UNIQUE (recurring_rule_id, occurrence_date) constraint is the "stable idempotent identity" the
--     gate requires: a retried generation for the same date can never create a second document.
--   * Editing a rule (label, template, frequency, pause/resume/end) never touches past occurrence rows —
--     they live in a separate table and generation only ever reads the rule's CURRENT fields at the
--     moment it runs (Step 15 §14 gate: "editing recurring rules never mutates historical generated
--     transactions").

create table public.recurring_rules (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  kind text not null check (kind in ('invoice', 'bill', 'expense')),
  label text not null check (length(btrim(label)) between 2 and 200),
  status text not null default 'active' check (status in ('active', 'paused', 'ended')),
  frequency text not null check (frequency in ('weekly', 'monthly', 'custom_days')),
  interval_count integer not null default 1 check (interval_count between 1 and 365),
  -- Invoice/bill only: due_date = occurrence_date + due_offset_days. Ignored for expenses.
  due_offset_days integer not null default 0 check (due_offset_days between 0 and 365),
  start_date date not null,
  end_date date,
  -- The date the next occurrence is due. Advances only after a SUCCESSFUL generation (Step 15 §14:
  -- "failed-generation retry behavior" — a failure keeps this unchanged so the next run retries it).
  next_occurrence_date date not null,
  last_generated_date date,
  -- The create_*_draft payload for this kind, minus entity_id/idempotency_key/dates (see app_private
  -- .recurring_validate_template below for the required keys per kind).
  template jsonb not null,
  note text check (note is null or length(note) <= 1000),
  paused_at timestamptz,
  paused_by uuid,
  paused_reason text,
  ended_at timestamptz,
  ended_by uuid,
  ended_reason text,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  constraint recurring_end_after_start check (end_date is null or end_date >= start_date),
  constraint recurring_next_not_before_start check (next_occurrence_date >= start_date),
  constraint recurring_state_consistent check (
    case status
      when 'active' then paused_at is null and ended_at is null
      when 'paused' then paused_at is not null and ended_at is null
      else ended_at is not null
    end)
);
create index recurring_rules_due_idx on public.recurring_rules (entity_id, next_occurrence_date)
  where status = 'active';
create index recurring_rules_entity_idx on public.recurring_rules (entity_id, status, kind);

create table public.recurring_occurrences (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  recurring_rule_id uuid not null,
  occurrence_date date not null,
  status text not null check (status in ('generated', 'failed')),
  generated_table text check (generated_table is null or generated_table in ('invoices', 'bills', 'expenses')),
  generated_id uuid,
  attempts integer not null default 1 check (attempts >= 1),
  last_attempted_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  unique (entity_id, id),
  unique (recurring_rule_id, occurrence_date),
  foreign key (entity_id, recurring_rule_id) references public.recurring_rules (entity_id, id) on delete restrict,
  constraint recurring_occurrence_generated_consistent check (
    (status = 'generated') = (generated_table is not null and generated_id is not null)
  )
);
create index recurring_occurrences_rule_idx on public.recurring_occurrences (recurring_rule_id, occurrence_date desc);

-- A generated occurrence is a historical fact; only a failed row may still change (on retry).
create function app_private.tg_recurring_occurrences_guard() returns trigger
language plpgsql as $$
begin
  if old.status = 'generated' then
    raise exception 'UPDATE is not allowed once a recurring occurrence is generated (append-only)'
      using errcode = 'integrity_constraint_violation';
  end if;
  if new.recurring_rule_id is distinct from old.recurring_rule_id
     or new.occurrence_date is distinct from old.occurrence_date
     or new.entity_id is distinct from old.entity_id then
    raise exception 'recurring occurrence identity cannot change' using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_recurring_occurrences_guard before update on public.recurring_occurrences
  for each row execute function app_private.tg_recurring_occurrences_guard();
create trigger tg_forbid_delete before delete on public.recurring_occurrences
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.recurring_occurrences
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.recurring_occurrences');

call app_private.apply_standard_triggers('public.recurring_rules');
call app_private.secure_table('public.recurring_rules');
create trigger tg_audit after insert or update or delete on public.recurring_rules
  for each row execute function app_private.tg_audit('entity_id');
create trigger tg_audit after insert or update or delete on public.recurring_occurrences
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ authorization + validation helpers
create function app_private.planning_authorize(p_entity uuid, p_perm text, p_what text) returns void
language plpgsql stable as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, p_perm) then
    raise exception 'FORBIDDEN: missing % for %', p_perm, p_what using errcode = 'insufficient_privilege';
  end if;
end
$$;

-- Confirms the template carries the keys the chosen kind's generator needs and that referenced
-- masters exist (Step 08 integrity). Full arithmetic/tax validation happens at generation time,
-- exactly like a manually drafted invoice/bill/expense is only fully validated when it is created.
create function app_private.recurring_validate_template(p_entity uuid, p_kind text, p_template jsonb) returns void
language plpgsql stable as $$
begin
  if jsonb_typeof(p_template) is distinct from 'object' then
    raise exception 'INVALID: the recurring template must be an object' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_typeof(coalesce(p_template -> 'lines', '[]'::jsonb)) is distinct from 'array' then
    raise exception 'INVALID: the recurring template lines must be a list' using errcode = 'invalid_parameter_value';
  end if;
  if p_kind = 'invoice' then
    if not exists (select 1 from public.contacts c
                    where c.id = nullif(p_template ->> 'customer_id', '')::uuid and c.entity_id = p_entity
                      and c.kind in ('customer', 'both')) then
      raise exception 'INVALID: the recurring invoice template needs a known customer' using errcode = 'invalid_parameter_value';
    end if;
  elsif p_kind = 'bill' then
    if not exists (select 1 from public.contacts c
                    where c.id = nullif(p_template ->> 'vendor_id', '')::uuid and c.entity_id = p_entity
                      and c.kind in ('vendor', 'both')) then
      raise exception 'INVALID: the recurring bill template needs a known vendor' using errcode = 'invalid_parameter_value';
    end if;
  else -- expense
    if nullif(p_template ->> 'account_id', '') is null then
      raise exception 'INVALID: the recurring expense template needs a payment account' using errcode = 'invalid_parameter_value';
    end if;
    if not exists (select 1 from public.financial_accounts a
                    where a.id = (p_template ->> 'account_id')::uuid and a.entity_id = p_entity and a.is_active) then
      raise exception 'INVALID: the recurring expense payment account is unknown or inactive' using errcode = 'invalid_parameter_value';
    end if;
    if nullif(p_template ->> 'payee_id', '') is null and nullif(btrim(coalesce(p_template ->> 'payee_name', '')), '') is null then
      raise exception 'INVALID: the recurring expense template needs a payee' using errcode = 'invalid_parameter_value';
    end if;
  end if;
end
$$;

-- ------------------------------------------------------------ commands
create function public.create_recurring_rule(
  p_entity uuid, p_key text, p_kind text, p_label text, p_frequency text, p_start_date date, p_template jsonb,
  p_interval integer default 1, p_due_offset_days integer default 0, p_end_date date default null,
  p_note text default null)
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
                           'end', p_end_date)::text));
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
    (entity_id, kind, label, frequency, interval_count, due_offset_days, start_date, end_date,
     next_occurrence_date, template, note)
  values
    (p_entity, p_kind, btrim(p_label), p_frequency, p_interval, p_due_offset_days, p_start_date, p_end_date,
     p_start_date, p_template, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v_id;

  perform app_private.idem_complete('recurring.create', p_entity, p_key, 'recurring_rules', v_id);
  return v_id;
end
$$;

-- Only the named fields change; edits never touch already-generated occurrences (they live in a
-- separate append-only table untouched by this statement).
create function public.update_recurring_rule(p_rule uuid, p_patch jsonb, p_expected_version integer default null)
returns integer
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  r public.recurring_rules%rowtype;
  v_label text;
  v_template jsonb;
  v_interval integer;
  v_due_offset integer;
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
    set label = btrim(v_label), template = v_template, interval_count = v_interval, due_offset_days = v_due_offset,
        end_date = v_end_date, note = v_note
    where id = p_rule
    returning version into v_new_version;
  return v_new_version;
end
$$;

create function public.pause_recurring_rule(p_rule uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r public.recurring_rules%rowtype;
begin
  select * into r from public.recurring_rules where id = p_rule for update;
  if not found then raise exception 'NOT_FOUND: recurring rule' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(r.entity_id, 'planning.recurring_edit', 'pausing a recurring rule');
  if r.status <> 'active' then
    raise exception 'INVALID: only an active recurring rule can be paused' using errcode = 'invalid_parameter_value';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'INVALID: a reason is required' using errcode = 'invalid_parameter_value';
  end if;
  update public.recurring_rules
    set status = 'paused', paused_at = now(), paused_by = auth.uid(), paused_reason = btrim(p_reason)
    where id = p_rule;
end
$$;

create function public.resume_recurring_rule(p_rule uuid) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r public.recurring_rules%rowtype;
begin
  select * into r from public.recurring_rules where id = p_rule for update;
  if not found then raise exception 'NOT_FOUND: recurring rule' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(r.entity_id, 'planning.recurring_edit', 'resuming a recurring rule');
  if r.status <> 'paused' then
    raise exception 'INVALID: only a paused recurring rule can be resumed' using errcode = 'invalid_parameter_value';
  end if;
  -- Future occurrences only (Step 16 §19): resuming never regenerates what was skipped while paused,
  -- it simply schedules the next occurrence from today onward if the rule fell behind.
  update public.recurring_rules
    set status = 'active', paused_at = null, paused_by = null, paused_reason = null,
        next_occurrence_date = greatest(next_occurrence_date, app_private.entity_today(entity_id))
    where id = p_rule;
end
$$;

create function public.end_recurring_rule(p_rule uuid, p_reason text) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare r public.recurring_rules%rowtype;
begin
  select * into r from public.recurring_rules where id = p_rule for update;
  if not found then raise exception 'NOT_FOUND: recurring rule' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(r.entity_id, 'planning.recurring_edit', 'ending a recurring rule');
  if r.status = 'ended' then
    raise exception 'INVALID: the recurring rule already ended' using errcode = 'invalid_parameter_value';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'INVALID: a reason is required' using errcode = 'invalid_parameter_value';
  end if;
  update public.recurring_rules
    set status = 'ended', ended_at = now(), ended_by = auth.uid(), ended_reason = btrim(p_reason)
    where id = p_rule;
end
$$;

-- ------------------------------------------------------------ queries
create function public.list_recurring_rules(p_entity uuid, p_status text default null)
returns setof public.recurring_rules
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.planning_authorize(p_entity, 'planning.view', 'the recurring rule list');
  return query
    select * from public.recurring_rules r
    where r.entity_id = p_entity and (p_status is null or r.status = p_status)
    order by r.status = 'active' desc, r.next_occurrence_date;
end
$$;

create function public.list_recurring_occurrences(p_rule uuid, p_limit integer default 50)
returns setof public.recurring_occurrences
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare v_entity uuid;
begin
  select entity_id into v_entity from public.recurring_rules where id = p_rule;
  if v_entity is null then raise exception 'NOT_FOUND: recurring rule' using errcode = 'no_data_found'; end if;
  perform app_private.planning_authorize(v_entity, 'planning.view', 'recurring occurrence history');
  return query
    select * from public.recurring_occurrences o
    where o.recurring_rule_id = p_rule
    order by o.occurrence_date desc
    limit least(greatest(p_limit, 1), 200);
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.recurring_rules');
create policy recurring_rules_select on public.recurring_rules for select to authenticated
  using (app_authz.has_permission(entity_id, 'planning.view'));
call app_private.expose_select('public.recurring_occurrences');
create policy recurring_occurrences_select on public.recurring_occurrences for select to authenticated
  using (app_authz.has_permission(entity_id, 'planning.view'));

grant execute on function public.create_recurring_rule(uuid, text, text, text, text, date, jsonb, integer, integer, date, text) to authenticated;
grant execute on function public.update_recurring_rule(uuid, jsonb, integer) to authenticated;
grant execute on function public.pause_recurring_rule(uuid, text) to authenticated;
grant execute on function public.resume_recurring_rule(uuid) to authenticated;
grant execute on function public.end_recurring_rule(uuid, text) to authenticated;
grant execute on function public.list_recurring_rules(uuid, text) to authenticated;
grant execute on function public.list_recurring_occurrences(uuid, integer) to authenticated;
