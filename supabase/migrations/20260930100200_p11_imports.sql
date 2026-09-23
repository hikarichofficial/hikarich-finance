-- P11 part 2 (Step 15 §15, Step 08 §17/§19, Step 01 #43): the import staging engine.
-- Authority: Step 15 P11 ("Import staging -> mapping -> validation -> preview -> commit with batch
-- lineage"), Step 08 §19 ("staging -> mapping -> validation -> preview -> commit/rollback, rollback
-- only when safely and completely reversible"), Step 08 §17 (duplicate detection: batch id + row
-- fingerprint), DATA_CUTOVER items 7-8 (open AR/AP left outside the system at cutover).
--
-- Design (docs/DECISIONS.md 143-144, corrected by 147 for the exact kind count already seeded):
--   * CSV/XLSX parsing and column mapping happen in the application layer (src/services/imports).
--     The database receives already-mapped row payloads through stage_import_batch and only
--     validates business rules -- it never parses a file.
--   * import_rows.target_type/target_record_id, once committed, ARE the batch lineage the gate asks
--     for; no separate lineage table exists.
--   * Two domains ship in this phase: `contacts` (delegates the actual write to the existing
--     create_contact command so contacts keep exactly one creation path -- Step 17 §13) and the two
--     DATA_CUTOVER opening-AR/AP importers (`legacy_open_receivables`, `legacy_open_payables`),
--     landing in the new, non-posting `legacy_open_items` table.
--   * Rows may be freely re-validated while their batch is `staging`; once the batch leaves staging
--     its rows are frozen except for the specific status transitions commit/rollback perform
--     themselves (mirrors the P6/P7 document-link guard pattern already in this repository).
--   * Rollback only where Step 08 §19's "safely and completely reversed" test holds (decision 144):
--     a `legacy_open_items` row always reverses cleanly (nothing else can reference it); a `contacts`
--     row is archived only when it has zero references anywhere else in the Entity, and is otherwise
--     left committed and reported, never silently skipped.

-- ------------------------------------------------------------ import_batches / import_rows
create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  domain text not null check (domain in ('contacts', 'legacy_open_receivables', 'legacy_open_payables')),
  status text not null default 'staging' check (status in ('staging', 'validated', 'committed', 'rolled_back')),
  -- The column mapping the caller chose in the import wizard (source column -> target field), kept for
  -- audit/troubleshooting; the database does not interpret it (rows already arrive mapped).
  mapping jsonb not null default '{}'::jsonb,
  source_file_name text check (source_file_name is null or length(source_file_name) <= 300),
  row_count integer not null default 0 check (row_count >= 0),
  validated_at timestamptz,
  validated_by uuid,
  committed_at timestamptz,
  committed_by uuid,
  rolled_back_at timestamptz,
  rolled_back_by uuid,
  rollback_reason text check (rollback_reason is null or length(rollback_reason) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  constraint import_batch_validated_shape check (status = 'staging' or validated_at is not null),
  constraint import_batch_committed_shape check (
    status not in ('committed', 'rolled_back') or (committed_at is not null and committed_by is not null)),
  constraint import_batch_rolled_back_shape check (
    status <> 'rolled_back' or (rolled_back_at is not null and rolled_back_by is not null and rollback_reason is not null)
  )
);
create index import_batches_entity_idx on public.import_batches (entity_id, domain, status);

create table public.import_rows (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  batch_id uuid not null,
  -- Denormalized from the parent batch at insert time so it can be indexed/filtered without a join.
  domain text not null check (domain in ('contacts', 'legacy_open_receivables', 'legacy_open_payables')),
  row_no integer not null check (row_no >= 1),
  raw_payload jsonb not null,
  mapped_payload jsonb,
  fingerprint text,
  status text not null default 'pending'
    check (status in ('pending', 'valid', 'invalid', 'duplicate', 'committed', 'rolled_back')),
  messages jsonb not null default '[]'::jsonb,
  target_type text check (target_type is null or target_type in ('contact', 'legacy_open_item')),
  target_record_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  unique (batch_id, row_no),
  foreign key (entity_id, batch_id) references public.import_batches (entity_id, id) on delete restrict,
  constraint import_row_target_shape check ((target_type is null) = (target_record_id is null))
);
create index import_rows_batch_idx on public.import_rows (batch_id, row_no);
create index import_rows_fingerprint_idx on public.import_rows (entity_id, domain, fingerprint)
  where fingerprint is not null and status in ('valid', 'committed');

-- Rows can be freely re-validated while their batch is `staging`. Once the batch has left `staging`,
-- a row's payload is frozen, and its status may only move valid -> committed or committed -> rolled_back
-- (the exact transitions commit_import_batch/rollback_import_batch perform) -- mirrors the document-link
-- guard's "removed-link immutability" pattern already established in this repository (P6/P11).
create function app_private.tg_import_rows_guard() returns trigger
language plpgsql as $$
declare
  v_batch_status text;
begin
  select status into v_batch_status from public.import_batches where id = new.batch_id;
  if v_batch_status = 'staging' then
    return new;
  end if;
  if new.raw_payload is distinct from old.raw_payload
     or new.batch_id is distinct from old.batch_id
     or new.entity_id is distinct from old.entity_id
     or new.domain is distinct from old.domain
     or new.row_no is distinct from old.row_no then
    raise exception 'INVALID: an import row is frozen once its batch leaves staging' using errcode = 'check_violation';
  end if;
  if new.status is distinct from old.status
     and not (old.status = 'valid' and new.status = 'committed')
     and not (old.status = 'committed' and new.status = 'rolled_back') then
    raise exception 'INVALID: an import row cannot move from % to % once its batch leaves staging', old.status, new.status
      using errcode = 'check_violation';
  end if;
  return new;
end
$$;
create trigger tg_import_rows_guard before update on public.import_rows
  for each row execute function app_private.tg_import_rows_guard();
call app_private.apply_standard_triggers('public.import_rows');
create trigger tg_forbid_delete before delete on public.import_rows
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.import_rows
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.import_rows');
create trigger tg_audit after insert or update or delete on public.import_rows
  for each row execute function app_private.tg_audit('entity_id');

call app_private.apply_standard_triggers('public.import_batches');
create trigger tg_forbid_delete before delete on public.import_batches
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.import_batches
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.import_batches');
create trigger tg_audit after insert or update or delete on public.import_batches
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ legacy_open_items
-- DATA_CUTOVER items 7-8 (option b): a customer invoice or vendor bill still open at cutover whose
-- own record stays outside the system -- the receivable/payable already exists in the opening-balance
-- journal's `other_ledger` bucket (decisions 74/80); this row is purely informational so staff can see
-- and settle it. It never posts to the ledger and never becomes an invoice/bill record.
create table public.legacy_open_items (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  kind text not null check (kind in ('receivable', 'payable')),
  contact_id uuid not null,
  amount public.money_amount not null check (amount > 0),
  currency public.currency_code not null references public.currencies (code),
  txn_date date not null,
  due_date date,
  reference text check (reference is null or length(reference) <= 100),
  note text check (note is null or length(note) <= 1000),
  status text not null default 'open' check (status in ('open', 'settled', 'written_off', 'rolled_back')),
  import_batch_id uuid,
  import_row_id uuid,
  settled_at timestamptz,
  settled_by uuid,
  settled_note text check (settled_note is null or length(settled_note) <= 1000),
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  version integer not null default 1,
  unique (entity_id, id),
  foreign key (entity_id, contact_id) references public.contacts (entity_id, id) on delete restrict,
  foreign key (entity_id, import_batch_id) references public.import_batches (entity_id, id) on delete restrict,
  foreign key (entity_id, import_row_id) references public.import_rows (entity_id, id) on delete restrict,
  constraint legacy_open_item_due check (due_date is null or due_date >= txn_date),
  constraint legacy_open_item_settled_shape check (
    (status in ('settled', 'written_off')) = (settled_at is not null and settled_by is not null)
    or status not in ('settled', 'written_off'))
);
create index legacy_open_items_entity_idx on public.legacy_open_items (entity_id, kind, status);
create index legacy_open_items_contact_idx on public.legacy_open_items (entity_id, contact_id);

-- Append-only once settled/written off/rolled back: a closed legacy item is a historical fact, exactly
-- like a posted journal or a removed document link (Step 08 §21's "immutable once it moves past staging"
-- principle applied here). Reopening is not offered (Step 08 §19 gives rollback, not reopen).
create function app_private.tg_legacy_open_items_guard() returns trigger
language plpgsql as $$
begin
  if old.status <> 'open' then
    raise exception 'INVALID: this legacy open item is already %, and cannot be changed further', old.status
      using errcode = 'check_violation';
  end if;
  if new.entity_id is distinct from old.entity_id or new.kind is distinct from old.kind
     or new.contact_id is distinct from old.contact_id or new.import_batch_id is distinct from old.import_batch_id
     or new.import_row_id is distinct from old.import_row_id then
    raise exception 'INVALID: a legacy open item''s identity cannot change' using errcode = 'check_violation';
  end if;
  return new;
end
$$;
create trigger tg_legacy_open_items_guard before update on public.legacy_open_items
  for each row execute function app_private.tg_legacy_open_items_guard();
create trigger tg_forbid_delete before delete on public.legacy_open_items
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.legacy_open_items
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.apply_standard_triggers('public.legacy_open_items');
call app_private.secure_table('public.legacy_open_items');
create trigger tg_audit after insert or update or delete on public.legacy_open_items
  for each row execute function app_private.tg_audit('entity_id');

-- ------------------------------------------------------------ the raw uploaded file is linkable evidence
-- Registered through the normal register_document/link_document path (decision 141), same as any other
-- evidence. New evidence can only be attached while the batch is still staging or validated; once it is
-- committed or rolled back the upload that produced it is a locked historical fact and cannot be removed
-- either (removable only while staging), matching every other closed-status kind in this catalog.
insert into app_private.document_target_kinds
  (target_type, table_name, view_permission, edit_permission_any, blocked_link_statuses, removable_statuses,
   generic_linker)
values
  ('import_batch', 'public.import_batches', 'system.import', array['system.import'],
   array['committed', 'rolled_back'], array['staging'], true);

-- ------------------------------------------------------------ authorization + shared helpers
create function app_private.import_authorize(p_entity uuid, p_perm text, p_what text) returns void
language plpgsql stable as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, p_perm) then
    raise exception 'FORBIDDEN: % needs %', p_what, p_perm using errcode = 'insufficient_privilege';
  end if;
end
$$;

-- ------------------------------------------------------------ domain validators
-- Each returns (mapped_payload, fingerprint, status, messages) for one row's raw_payload. They never
-- write anything -- validate_import_batch does all the writing, one UPDATE per row.
create function app_private.validate_import_row_contact(p_entity uuid, p_raw jsonb)
returns table (mapped_payload jsonb, fingerprint text, status text, messages text[])
language plpgsql stable as $$
declare
  v_kind text := nullif(btrim(coalesce(p_raw ->> 'kind', '')), '');
  v_name text := nullif(btrim(coalesce(p_raw ->> 'display_name', '')), '');
  v_email text := nullif(btrim(coalesce(p_raw ->> 'email', '')), '');
  v_phone text := nullif(btrim(coalesce(p_raw ->> 'phone', '')), '');
  v_tax text := nullif(btrim(coalesce(p_raw ->> 'tax_identifier', '')), '');
  v_msgs text[] := array[]::text[];
  d record;
  v_has_exact boolean := false;
  v_has_suspected boolean := false;
begin
  if v_kind is null or v_kind not in ('customer', 'vendor', 'both') then
    v_msgs := v_msgs || array['kind must be customer, vendor or both'];
  end if;
  if v_name is null or length(v_name) > 200 then
    v_msgs := v_msgs || array['display_name is required (up to 200 characters)'];
  end if;
  if cardinality(v_msgs) > 0 then
    return query select p_raw, null::text, 'invalid', v_msgs;
    return;
  end if;

  for d in select * from app_private.contact_duplicates(p_entity, v_name, v_email, v_phone, v_tax, null) loop
    if d.severity = 'exact' then
      v_has_exact := true;
      v_msgs := v_msgs || array[format('duplicate of existing contact %s (%s)', d.display_name, d.reason)];
    else
      v_has_suspected := true;
      v_msgs := v_msgs || array[format('possible duplicate of existing contact %s (same name) -- resolve before import', d.display_name)];
    end if;
  end loop;

  return query select
    jsonb_build_object('kind', v_kind, 'display_name', v_name, 'email', v_email, 'phone', v_phone,
                        'tax_identifier', v_tax, 'legal_name', nullif(btrim(coalesce(p_raw ->> 'legal_name', '')), ''),
                        'notes', nullif(btrim(coalesce(p_raw ->> 'notes', '')), '')),
    md5('contact|' || v_kind || '|' || lower(coalesce(v_tax, '')) || '|' || lower(coalesce(v_email, '')) || '|'
        || lower(regexp_replace(v_name, '\s+', ' ', 'g'))),
    case when v_has_exact then 'duplicate' when v_has_suspected then 'invalid' else 'valid' end,
    v_msgs;
end
$$;

create function app_private.validate_import_row_legacy_open_item(p_entity uuid, p_kind text, p_raw jsonb)
returns table (mapped_payload jsonb, fingerprint text, status text, messages text[])
language plpgsql stable as $$
declare
  v_contact_id uuid := nullif(p_raw ->> 'contact_id', '')::uuid;
  v_contact_name text := nullif(btrim(coalesce(p_raw ->> 'contact_name', '')), '');
  v_amount numeric := nullif(p_raw ->> 'amount', '')::numeric;
  v_currency text := upper(nullif(btrim(coalesce(p_raw ->> 'currency', '')), ''));
  v_txn_date date;
  v_due_date date;
  v_reference text := nullif(btrim(coalesce(p_raw ->> 'reference', '')), '');
  v_note text := nullif(btrim(coalesce(p_raw ->> 'note', '')), '');
  v_msgs text[] := array[]::text[];
  v_matches integer;
begin
  if v_contact_id is null then
    if v_contact_name is null then
      v_msgs := v_msgs || array['contact_id or contact_name is required'];
    else
      select count(*), max(id) into v_matches, v_contact_id
      from public.contacts
      where entity_id = p_entity and normalized_name = lower(regexp_replace(v_contact_name, '\s+', ' ', 'g'));
      if v_matches = 0 then
        v_msgs := v_msgs || array[format('no existing contact matches "%s" -- import contacts first or supply contact_id', v_contact_name)];
        v_contact_id := null;
      elsif v_matches > 1 then
        v_msgs := v_msgs || array[format('"%s" matches more than one existing contact -- supply contact_id', v_contact_name)];
        v_contact_id := null;
      end if;
    end if;
  elsif not exists (select 1 from public.contacts where entity_id = p_entity and id = v_contact_id) then
    v_msgs := v_msgs || array['contact_id does not exist in this Entity'];
    v_contact_id := null;
  end if;

  if v_amount is null or v_amount <= 0 then
    v_msgs := v_msgs || array['amount must be a positive number'];
  end if;
  if v_currency is null or v_currency !~ '^[A-Z]{3}$' or not exists (select 1 from public.currencies where code = v_currency) then
    v_msgs := v_msgs || array['currency must be a known 3-letter currency code'];
  end if;
  begin
    v_txn_date := nullif(p_raw ->> 'txn_date', '')::date;
  exception when others then
    v_msgs := v_msgs || array['txn_date is not a valid date'];
  end;
  if v_txn_date is null and not (v_msgs @> array['txn_date is not a valid date']) then
    v_msgs := v_msgs || array['txn_date is required'];
  end if;
  begin
    v_due_date := nullif(p_raw ->> 'due_date', '')::date;
  exception when others then
    v_msgs := v_msgs || array['due_date is not a valid date'];
  end;
  if v_due_date is not null and v_txn_date is not null and v_due_date < v_txn_date then
    v_msgs := v_msgs || array['due_date cannot be before txn_date'];
  end if;
  if v_reference is not null and length(v_reference) > 100 then
    v_msgs := v_msgs || array['reference must be 100 characters or fewer'];
  end if;

  if cardinality(v_msgs) > 0 then
    return query select p_raw, null::text, 'invalid', v_msgs;
    return;
  end if;

  return query select
    jsonb_build_object('contact_id', v_contact_id, 'amount', v_amount, 'currency', v_currency,
                        'txn_date', v_txn_date, 'due_date', v_due_date, 'reference', v_reference, 'note', v_note),
    md5(p_kind || '|' || v_contact_id::text || '|' || v_amount::text || '|' || v_currency || '|' || v_txn_date::text
        || '|' || coalesce(v_reference, '')),
    'valid',
    v_msgs;
end
$$;

-- ------------------------------------------------------------ commands
create function public.stage_import_batch(p_entity uuid, p_domain text, p_mapping jsonb, p_rows jsonb,
                                           p_source_file_name text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_batch uuid;
  v_row jsonb;
  v_n integer := 0;
begin
  perform app_private.import_authorize(p_entity, 'system.import', 'staging an import');
  if p_domain not in ('contacts', 'legacy_open_receivables', 'legacy_open_payables') then
    raise exception 'INVALID: unknown import domain %', p_domain using errcode = 'invalid_parameter_value';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'INVALID: at least one row is required' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'INVALID: an import batch is limited to 5000 rows' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.import_batches (entity_id, domain, mapping, source_file_name, row_count)
  values (p_entity, p_domain, coalesce(p_mapping, '{}'::jsonb), p_source_file_name, jsonb_array_length(p_rows))
  returning id into v_batch;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_n := v_n + 1;
    if jsonb_typeof(v_row) <> 'object' then
      raise exception 'INVALID: row % is not an object', v_n using errcode = 'invalid_parameter_value';
    end if;
    insert into public.import_rows (entity_id, batch_id, domain, row_no, raw_payload)
    values (p_entity, v_batch, p_domain, v_n, v_row);
  end loop;

  return v_batch;
end
$$;

create function public.validate_import_batch(p_batch uuid)
returns table (total_rows integer, valid_rows integer, invalid_rows integer, duplicate_rows integer)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_batch public.import_batches%rowtype;
  r public.import_rows%rowtype;
  v_result record;
  v_status text;
  v_msgs text[];
  v_mapped jsonb;
  v_fp text;
  v_seen_fp text[] := array[]::text[];
begin
  select * into v_batch from public.import_batches where id = p_batch;
  if not found then
    raise exception 'NOT_FOUND: import batch not found' using errcode = 'no_data_found';
  end if;
  perform app_private.import_authorize(v_batch.entity_id, 'system.import', 'validating an import');
  if v_batch.status <> 'staging' then
    raise exception 'INVALID: only a batch that is still staging can be (re)validated' using errcode = 'check_violation';
  end if;

  for r in select * from public.import_rows where batch_id = p_batch order by row_no loop
    if v_batch.domain = 'contacts' then
      select * into v_result from app_private.validate_import_row_contact(v_batch.entity_id, r.raw_payload);
    elsif v_batch.domain = 'legacy_open_receivables' then
      select * into v_result from app_private.validate_import_row_legacy_open_item(v_batch.entity_id, 'receivable', r.raw_payload);
    else
      select * into v_result from app_private.validate_import_row_legacy_open_item(v_batch.entity_id, 'payable', r.raw_payload);
    end if;
    v_mapped := v_result.mapped_payload;
    v_fp := v_result.fingerprint;
    v_status := v_result.status;
    v_msgs := v_result.messages;

    -- Within-batch duplicate detection (Step 08 §17: batch id + row fingerprint): the first row with a
    -- given fingerprint stands; a later row in the same batch with the same fingerprint is a duplicate
    -- of the earlier one, regardless of what the per-row validator above decided.
    if v_status <> 'invalid' and v_fp is not null then
      if v_fp = any(v_seen_fp) then
        v_status := 'duplicate';
        v_msgs := v_msgs || array['duplicate of an earlier row in this same import batch'];
      else
        v_seen_fp := v_seen_fp || v_fp;
        -- Cross-batch duplicate detection: a fingerprint already committed by a previous import.
        if exists (
          select 1 from public.import_rows x
          where x.entity_id = v_batch.entity_id and x.domain = v_batch.domain and x.fingerprint = v_fp
            and x.status = 'committed' and x.batch_id <> p_batch
        ) then
          v_status := 'duplicate';
          v_msgs := v_msgs || array['duplicate of a record already committed by an earlier import'];
        end if;
      end if;
    end if;

    update public.import_rows
      set mapped_payload = v_mapped, fingerprint = v_fp, status = v_status, messages = to_jsonb(v_msgs)
      where id = r.id;
  end loop;

  update public.import_batches
    set status = 'validated', validated_at = now(), validated_by = auth.uid()
    where id = p_batch;

  return query
    select count(*)::int, count(*) filter (where status = 'valid')::int,
           count(*) filter (where status = 'invalid')::int, count(*) filter (where status = 'duplicate')::int
    from public.import_rows where batch_id = p_batch;
end
$$;

create function public.commit_import_batch(p_batch uuid)
returns table (committed_rows integer, skipped_rows integer)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_batch public.import_batches%rowtype;
  r public.import_rows%rowtype;
  v_contact_id uuid;
  v_item_id uuid;
  v_committed integer := 0;
  v_skipped integer := 0;
begin
  select * into v_batch from public.import_batches where id = p_batch;
  if not found then
    raise exception 'NOT_FOUND: import batch not found' using errcode = 'no_data_found';
  end if;
  perform app_private.import_authorize(v_batch.entity_id, 'system.import', 'committing an import');
  if v_batch.domain = 'contacts' then
    perform app_private.import_authorize(v_batch.entity_id, 'contacts.create', 'committing an imported contact');
  end if;
  if v_batch.status <> 'validated' then
    raise exception 'INVALID: only a validated batch can be committed' using errcode = 'check_violation';
  end if;

  for r in select * from public.import_rows where batch_id = p_batch and status = 'valid' order by row_no loop
    begin
      if v_batch.domain = 'contacts' then
        v_contact_id := public.create_contact(
          v_batch.entity_id, 'import:' || p_batch::text || ':' || r.row_no::text,
          r.mapped_payload ->> 'kind', r.mapped_payload ->> 'display_name', r.mapped_payload ->> 'email',
          r.mapped_payload ->> 'phone', r.mapped_payload ->> 'tax_identifier', r.mapped_payload ->> 'legal_name',
          null, null, null, r.mapped_payload ->> 'notes', false);
        update public.import_rows set target_type = 'contact', target_record_id = v_contact_id, status = 'committed'
          where id = r.id;
      else
        insert into public.legacy_open_items
          (entity_id, kind, contact_id, amount, currency, txn_date, due_date, reference, note,
           import_batch_id, import_row_id)
        values
          (v_batch.entity_id, case when v_batch.domain = 'legacy_open_receivables' then 'receivable' else 'payable' end,
           (r.mapped_payload ->> 'contact_id')::uuid, (r.mapped_payload ->> 'amount')::numeric,
           r.mapped_payload ->> 'currency', (r.mapped_payload ->> 'txn_date')::date,
           nullif(r.mapped_payload ->> 'due_date', '')::date, r.mapped_payload ->> 'reference',
           r.mapped_payload ->> 'note', p_batch, r.id)
        returning id into v_item_id;
        update public.import_rows set target_type = 'legacy_open_item', target_record_id = v_item_id, status = 'committed'
          where id = r.id;
      end if;
      v_committed := v_committed + 1;
    exception when others then
      -- Row-level errors (Step 08 §19): one bad row never aborts the whole batch. Left `valid`, so the
      -- reported error is visible and the row can be inspected, but it does not count as committed.
      update public.import_rows
        set messages = messages || to_jsonb(array[format('commit failed: %s', sqlerrm)])
        where id = r.id;
      v_skipped := v_skipped + 1;
    end;
  end loop;

  update public.import_batches set status = 'committed', committed_at = now(), committed_by = auth.uid()
    where id = p_batch;

  return query select v_committed, v_skipped;
end
$$;

-- True when p_contact is referenced by anything other than the import that (maybe) created it -- every
-- table with a `contacts` foreign key in this schema, enumerated (decision 144's "zero references
-- anywhere else in the Entity" test for whether an imported contact can be safely archived on rollback).
create function app_private.contact_is_referenced(p_entity uuid, p_contact uuid) returns boolean
language sql stable as $$
  select
    exists (select 1 from public.contact_bank_accounts where entity_id = p_entity and contact_id = p_contact)
    or exists (select 1 from public.invoices where entity_id = p_entity and customer_id = p_contact)
    or exists (select 1 from public.payments where entity_id = p_entity and customer_id = p_contact)
    or exists (select 1 from public.refunds where entity_id = p_entity and customer_id = p_contact)
    or exists (select 1 from public.bills where entity_id = p_entity and vendor_id = p_contact)
    or exists (select 1 from public.vendor_payments where entity_id = p_entity and vendor_id = p_contact)
    or exists (select 1 from public.expenses where entity_id = p_entity and payee_id = p_contact)
    or exists (select 1 from public.tax_contact_facts where entity_id = p_entity and contact_id = p_contact)
    or exists (select 1 from public.other_obligations where entity_id = p_entity and contact_id = p_contact)
    or exists (select 1 from public.loans where entity_id = p_entity and contact_id = p_contact)
    or exists (select 1 from public.equity_events where entity_id = p_entity and contact_id = p_contact)
    or exists (select 1 from public.legacy_open_items where entity_id = p_entity and contact_id = p_contact and status <> 'rolled_back')
$$;

create function public.rollback_import_batch(p_batch uuid, p_reason text)
returns table (rolled_back_rows integer, retained_rows integer)
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_batch public.import_batches%rowtype;
  r public.import_rows%rowtype;
  v_reversed integer := 0;
  v_retained integer := 0;
begin
  select * into v_batch from public.import_batches where id = p_batch;
  if not found then
    raise exception 'NOT_FOUND: import batch not found' using errcode = 'no_data_found';
  end if;
  perform app_private.import_authorize(v_batch.entity_id, 'system.rollback_import', 'rolling back an import');
  if v_batch.domain = 'contacts' then
    perform app_private.import_authorize(v_batch.entity_id, 'contacts.archive', 'archiving a rolled-back imported contact');
  end if;
  if v_batch.status <> 'committed' then
    raise exception 'INVALID: only a committed batch can be rolled back' using errcode = 'check_violation';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 or length(p_reason) > 1000 then
    raise exception 'INVALID: a rollback reason of 3 to 1000 characters is required' using errcode = 'invalid_parameter_value';
  end if;

  for r in select * from public.import_rows where batch_id = p_batch and status = 'committed' order by row_no desc loop
    if r.target_type = 'legacy_open_item' then
      -- Always safely and completely reversible: nothing else can reference an informational AR/AP row.
      update public.legacy_open_items set status = 'rolled_back' where id = r.target_record_id;
      update public.import_rows set status = 'rolled_back' where id = r.id;
      v_reversed := v_reversed + 1;
    elsif r.target_type = 'contact' then
      if app_private.contact_is_referenced(v_batch.entity_id, r.target_record_id) then
        update public.import_rows
          set messages = messages || to_jsonb(array['not rolled back: this contact is now referenced elsewhere in the Entity'])
          where id = r.id;
        v_retained := v_retained + 1;
      else
        update public.contacts set status = 'inactive' where id = r.target_record_id and entity_id = v_batch.entity_id;
        update public.import_rows set status = 'rolled_back' where id = r.id;
        v_reversed := v_reversed + 1;
      end if;
    else
      v_retained := v_retained + 1;
    end if;
  end loop;

  update public.import_batches
    set status = 'rolled_back', rolled_back_at = now(), rolled_back_by = auth.uid(), rollback_reason = p_reason
    where id = p_batch;

  return query select v_reversed, v_retained;
end
$$;

-- ------------------------------------------------------------ reads
create function public.list_import_batches(p_entity uuid, p_domain text default null)
returns table (batch_id uuid, domain text, status text, row_count integer, source_file_name text,
               created_at timestamptz, created_by uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  perform app_private.import_authorize(p_entity, 'system.import', 'listing imports');
  return query
    select b.id, b.domain, b.status, b.row_count, b.source_file_name, b.created_at, b.created_by
    from public.import_batches b
    where b.entity_id = p_entity and (p_domain is null or b.domain = p_domain)
    order by b.created_at desc;
end
$$;

create function public.get_import_batch_rows(p_batch uuid, p_status text default null)
returns table (row_id uuid, row_no integer, raw_payload jsonb, mapped_payload jsonb, status text,
               messages jsonb, target_type text, target_record_id uuid)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  v_entity uuid;
begin
  select entity_id into v_entity from public.import_batches where id = p_batch;
  if v_entity is null then
    raise exception 'NOT_FOUND: import batch not found' using errcode = 'no_data_found';
  end if;
  perform app_private.import_authorize(v_entity, 'system.import', 'reading import rows');
  return query
    select r.id, r.row_no, r.raw_payload, r.mapped_payload, r.status, r.messages, r.target_type, r.target_record_id
    from public.import_rows r
    where r.batch_id = p_batch and (p_status is null or r.status = p_status)
    order by r.row_no;
end
$$;

-- Kind-gated the same way the rest of this schema gates AR/AP reads: receivables through invoices.view,
-- payables through bills.view (no new permission key -- decision 146's minimalism principle applied here).
create function public.list_legacy_open_items(p_entity uuid, p_kind text, p_status text default null)
returns table (item_id uuid, contact_id uuid, contact_name text, amount public.money_amount, currency public.currency_code,
               txn_date date, due_date date, reference text, status text)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if p_kind not in ('receivable', 'payable') then
    raise exception 'INVALID: kind must be receivable or payable' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.import_authorize(p_entity, case when p_kind = 'receivable' then 'invoices.view' else 'bills.view' end,
                                        'viewing legacy open items');
  return query
    select i.id, i.contact_id, c.display_name, i.amount, i.currency, i.txn_date, i.due_date, i.reference, i.status
    from public.legacy_open_items i
    join public.contacts c on c.id = i.contact_id and c.entity_id = i.entity_id
    where i.entity_id = p_entity and i.kind = p_kind and (p_status is null or i.status = p_status)
    order by i.txn_date desc, i.created_at desc;
end
$$;

create function public.settle_legacy_open_item(p_item uuid, p_status text, p_note text default null)
returns text
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_item public.legacy_open_items%rowtype;
begin
  select * into v_item from public.legacy_open_items where id = p_item;
  if not found then
    raise exception 'NOT_FOUND: legacy open item not found' using errcode = 'no_data_found';
  end if;
  perform app_private.import_authorize(v_item.entity_id,
    case when v_item.kind = 'receivable' then 'invoices.confirm_payment' else 'bills.pay' end,
    'settling a legacy open item');
  if p_status not in ('settled', 'written_off') then
    raise exception 'INVALID: status must be settled or written_off' using errcode = 'invalid_parameter_value';
  end if;
  if v_item.status <> 'open' then
    raise exception 'INVALID: this legacy open item is already %', v_item.status using errcode = 'check_violation';
  end if;
  update public.legacy_open_items
    set status = p_status, settled_at = now(), settled_by = auth.uid(), settled_note = p_note
    where id = p_item;
  return p_status;
end
$$;

-- ------------------------------------------------------------ RLS and privileges
call app_private.expose_select('public.import_batches');
create policy import_batches_select on public.import_batches for select to authenticated
  using (app_authz.has_permission(entity_id, 'system.import'));
call app_private.expose_select('public.import_rows');
create policy import_rows_select on public.import_rows for select to authenticated
  using (app_authz.has_permission(entity_id, 'system.import'));
call app_private.expose_select('public.legacy_open_items');
create policy legacy_open_items_select on public.legacy_open_items for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view') or app_authz.has_permission(entity_id, 'bills.view'));

revoke all on function app_private.import_authorize(uuid, text, text) from public;
revoke all on function app_private.validate_import_row_contact(uuid, jsonb) from public;
revoke all on function app_private.validate_import_row_legacy_open_item(uuid, text, jsonb) from public;
revoke all on function app_private.contact_is_referenced(uuid, uuid) from public;

grant execute on function public.stage_import_batch(uuid, text, jsonb, jsonb, text) to authenticated;
grant execute on function public.validate_import_batch(uuid) to authenticated;
grant execute on function public.commit_import_batch(uuid) to authenticated;
grant execute on function public.rollback_import_batch(uuid, text) to authenticated;
grant execute on function public.list_import_batches(uuid, text) to authenticated;
grant execute on function public.get_import_batch_rows(uuid, text) to authenticated;
grant execute on function public.list_legacy_open_items(uuid, text, text) to authenticated;
grant execute on function public.settle_legacy_open_item(uuid, text, text) to authenticated;
