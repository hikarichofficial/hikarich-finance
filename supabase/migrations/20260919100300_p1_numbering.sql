-- P1 (Step 15 §5 "financial identifiers"): concurrency-safe, Entity-aware document numbering.
-- Authority: Step 02 §4 (invoice numbering), Step 08 §16-§17.
--
-- Rules implemented in the database:
--   * a number is allocated atomically (row lock on the counter), so concurrent issuers get
--     distinct, increasing values;
--   * numbers are recorded in `issued_document_numbers` and are never reused or deleted, even if the
--     document is later voided (they stay reserved for audit continuity);
--   * changing the prefix/format affects future numbers only (stored numbers are text snapshots);
--   * the user-facing number is NOT a primary key of any document (Step 08 §16).

create table public.numbering_sequences (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  scope text not null check (scope in ('invoice', 'payment_receipt', 'refund_receipt', 'bill', 'journal', 'other')),
  prefix text not null check (prefix ~ '^[A-Z0-9]{1,12}$'),
  separator text not null default '-' check (separator in ('-', '/', '.', '')),
  include_year boolean not null default true,
  padding smallint not null default 4 check (padding between 1 and 10),
  reset_policy text not null default 'yearly' check (reset_policy in ('yearly', 'never')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (entity_id, scope)
);
call app_private.apply_standard_triggers('public.numbering_sequences');
call app_private.secure_table('public.numbering_sequences');
create trigger tg_audit after insert or update or delete on public.numbering_sequences
  for each row execute function app_private.tg_audit('entity_id');

create table public.numbering_counters (
  sequence_id uuid not null references public.numbering_sequences (id) on delete restrict,
  period_key text not null check (period_key ~ '^([0-9]{4}|all)$'),
  last_value bigint not null check (last_value >= 0),
  primary key (sequence_id, period_key)
);
call app_private.secure_table('public.numbering_counters');

create table public.issued_document_numbers (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  scope text not null,
  full_number text not null,
  sequence_id uuid not null,
  period_key text not null,
  sequence_value bigint not null check (sequence_value > 0),
  status text not null default 'issued' check (status in ('issued', 'voided')),
  allocated_at timestamptz not null default now(),
  allocated_by uuid,
  foreign key (entity_id, sequence_id) references public.numbering_sequences (entity_id, id) on delete restrict,
  unique (entity_id, id),
  unique (entity_id, scope, full_number),
  unique (sequence_id, period_key, sequence_value)
);
create trigger tg_forbid_delete before delete on public.issued_document_numbers
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.issued_document_numbers
  for each statement execute function app_private.tg_forbid_truncate();
-- Only issued -> voided is allowed, and nothing else may change.
create function app_private.tg_issued_numbers_guard() returns trigger
language plpgsql as $$
begin
  if (new.id, new.entity_id, new.scope, new.full_number, new.sequence_id, new.period_key, new.sequence_value,
      new.allocated_at, new.allocated_by)
     is distinct from
     (old.id, old.entity_id, old.scope, old.full_number, old.sequence_id, old.period_key, old.sequence_value,
      old.allocated_at, old.allocated_by) then
    raise exception 'Issued document numbers are immutable; only status may change to voided'
      using errcode = 'integrity_constraint_violation';
  end if;
  if not (old.status = 'issued' and new.status = 'voided') and new.status is distinct from old.status then
    raise exception 'Issued number status may only move issued -> voided'
      using errcode = 'integrity_constraint_violation';
  end if;
  return new;
end
$$;
create trigger tg_guard before update on public.issued_document_numbers
  for each row execute function app_private.tg_issued_numbers_guard();
call app_private.secure_table('public.issued_document_numbers');

-- Allocates and records the next number. Call inside the issuing transaction so that a rolled-back
-- issue also rolls back the allocation. `p_business_date` is the Entity-local business date.
create function app_private.allocate_document_number(p_entity uuid, p_scope text, p_business_date date)
returns text
language plpgsql as $$
declare
  v_seq public.numbering_sequences%rowtype;
  v_period text;
  v_value bigint;
  v_number text;
begin
  select * into v_seq
  from public.numbering_sequences
  where entity_id = p_entity and scope = p_scope and is_active;
  if not found then
    raise exception 'No active numbering sequence for entity % scope %', p_entity, p_scope
      using errcode = 'no_data_found';
  end if;

  v_period := case v_seq.reset_policy when 'yearly' then to_char(p_business_date, 'YYYY') else 'all' end;

  -- The upsert takes a row lock on the counter: concurrent callers queue here, so values are unique.
  insert into public.numbering_counters (sequence_id, period_key, last_value)
  values (v_seq.id, v_period, 1)
  on conflict (sequence_id, period_key)
  do update set last_value = public.numbering_counters.last_value + 1
  returning last_value into v_value;

  v_number := v_seq.prefix || v_seq.separator
    || case when v_seq.include_year then to_char(p_business_date, 'YYYY') || v_seq.separator else '' end
    || lpad(v_value::text, v_seq.padding, '0');

  insert into public.issued_document_numbers
    (entity_id, scope, full_number, sequence_id, period_key, sequence_value, allocated_by)
  values (p_entity, p_scope, v_number, v_seq.id, v_period, v_value, auth.uid());

  return v_number;
end
$$;
revoke all on function app_private.allocate_document_number(uuid, text, date) from public;
