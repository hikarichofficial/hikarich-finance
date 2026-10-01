-- P14 (Step 15 §18, Step 01 #36, Step 07 §21-§22, Step 14 §9, Step 16 §34): Backup & Restore Center,
-- Part 2 -- the restore-write path -- and trusted-device revocation. Decision 247.
--
-- Restore follows Step 07 §22 exactly: Select Backup -> Validate -> Preview Impact -> Step-up ->
-- Confirm -> Restore -> Integrity Check -> Completed/Failed; OWNER-only by default (`backup.restore`,
-- held only by OWNER); never a single accidental click (the screen demands a typed confirmation); the
-- operation and its integrity result are permanently recorded (`restore_jobs` + `audit_events`).
--
-- OWNER decision (2026-10-01, decision 247): a restore writes ONLY into an EMPTY Entity -- one with no
-- rows in any restorable table other than its memberships and its audit trail. A restore therefore never
-- deletes or overwrites anything, which keeps every locked invariant intact (posted journals immutable,
-- audit trail append-only). The disaster-recovery procedure is: migrate a fresh database, create the
-- Entity with its original id and its OWNER membership, then restore (docs/RELEASE.md).
--
-- Mechanics. Rows are written exactly as backed up (ids, timestamps, statuses) by a SECURITY DEFINER
-- function owned by the tables' owner. Business triggers are switched off for the tables being written,
-- inside this transaction only (`alter table ... disable trigger user`, transactional DDL), because they
-- exist to police live business commands (e.g. "lines cannot be added to a posted journal") rather than
-- the reinstatement of an already-valid history. Foreign keys stay ENFORCED: tables are written in
-- dependency order, and the one FK cycle (tax_determinations <-> tax_overrides, both nullable) is broken
-- by inserting with the cyclic columns null and filling them afterwards -- generically, for any nullable
-- cycle a future migration might add. `entity_memberships` rows in a backup are not restored (access is
-- re-established deliberately, never from a file); they are counted and reported. Supabase does not
-- allow `session_replication_role`, so this is the platform-compatible path.
--
-- Integrity check (before commit): every table holds exactly the backed-up row count, every posted
-- journal balances, and the trial balance as a whole balances. Any failure rolls the restore back
-- completely and records a Failed job.

-- ------------------------------------------------------------ restore history
create table public.restore_jobs (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id),
  requested_by uuid not null references public.profiles (id),
  source_kind text not null,
  source_checksum text not null,
  status text not null check (status in ('completed', 'failed')),
  table_counts jsonb not null default '{}'::jsonb,
  skipped jsonb not null default '{}'::jsonb,
  integrity jsonb not null default '{}'::jsonb,
  error text,
  created_at timestamptz not null default now(),
  unique (entity_id, id)
);
create index restore_jobs_entity_created_idx on public.restore_jobs (entity_id, created_at desc);
create trigger tg_forbid_update before update on public.restore_jobs
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.restore_jobs
  for each row execute function app_private.tg_forbid_delete();
alter table public.restore_jobs enable row level security;
call app_private.expose_select('public.restore_jobs');
create policy restore_jobs_select on public.restore_jobs for select to authenticated
  using (app_authz.has_permission(entity_id, 'backup.restore'));

-- ------------------------------------------------------------ export as exact text
-- Restore history is not part of an Entity's data (like `backup_jobs`): excluded from every backup, so a
-- failed restore attempt never makes the target look non-empty.
create or replace function app_private.backup_export_tables(p_kind text) returns text[]
language plpgsql stable as $$
declare
  v_all text[];
  v_exclude text[];
begin
  select array_agg(distinct c.table_name order by c.table_name) into v_all
  from information_schema.columns c
  join information_schema.tables t
    on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
  where c.table_schema = 'public' and c.column_name = 'entity_id'
    and c.table_name not in ('backup_jobs', 'restore_jobs');

  v_exclude := case when p_kind = 'data_only'
                    then array['audit_events', 'documents', 'document_links']
                    else array[]::text[] end;
  return coalesce(
    (select array_agg(x order by x) from unnest(v_all) x where x <> all (v_exclude)),
    array[]::text[]);
end
$$;

-- The backup file itself, as the database's own JSON text. Part 1 built the file in the browser from
-- the parsed RPC result, which turns money like 100000.0000 into 100000 and can lose precision past ~15
-- significant digits; handing the exact text to the browser keeps every value -- and the checksum --
-- byte-for-byte reproducible on restore (decision 247).
create function public.export_backup_file(p_entity uuid, p_kind text) returns text
language sql security definer set search_path = pg_catalog, public as $$
  select public.export_backup_snapshot(p_entity, p_kind)::text
$$;

-- Parses an uploaded backup file's text; NULL when it is not a JSON object.
create function app_private.restore_parse(p_text text) returns jsonb
language plpgsql immutable as $$
declare
  v jsonb;
begin
  begin
    v := p_text::jsonb;
  exception when others then
    return null;
  end;
  return case when jsonb_typeof(v) = 'object' then v else null end;
end
$$;

-- ------------------------------------------------------------ helpers
-- Tables a restore may write: every Entity-scoped table a Full backup carries, minus the memberships.
create function app_private.restore_tables() returns text[]
language sql stable as $$
  select coalesce(array_agg(x order by x), array[]::text[])
  from unnest(app_private.backup_export_tables('full')) x
  where x <> 'entity_memberships'
$$;

-- Rows the target Entity already holds in restorable tables (the audit trail does not count: a fresh
-- Entity already has the audit events of its own creation, and the restore only appends to it).
create function app_private.restore_target_rows(p_entity uuid) returns jsonb
language plpgsql stable as $$
declare
  v_tbl text;
  v_n bigint;
  v_out jsonb := '{}'::jsonb;
begin
  foreach v_tbl in array app_private.restore_tables() loop
    continue when v_tbl = 'audit_events';
    execute format('select count(*) from public.%I where entity_id = %L', v_tbl, p_entity) into v_n;
    if v_n > 0 then
      v_out := v_out || jsonb_build_object(v_tbl, v_n);
    end if;
  end loop;
  return v_out;
end
$$;

-- The common checks of preview and restore. Returns errors (blocking) and warnings.
create function app_private.restore_check(p_entity uuid, p_payload jsonb) returns jsonb
language plpgsql stable as $$
declare
  v_errors text[] := array[]::text[];
  v_warnings text[] := array[]::text[];
  v_target jsonb;
  v_tbl text;
  v_row jsonb;
  v_foreign integer := 0;
  v_unknown text[] := array[]::text[];
  v_restorable text[] := app_private.restore_tables();
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or jsonb_typeof(p_payload -> 'data') is distinct from 'object' then
    return jsonb_build_object('errors', jsonb_build_array('Berkas backup tidak berisi bagian "data" yang valid.'),
                              'warnings', '[]'::jsonb);
  end if;
  if (p_payload ->> 'kind') not in ('full', 'data_only') then
    v_errors := array_append(v_errors, 'Hanya Backup Penuh atau Backup Data Saja yang dapat dipulihkan.');
  end if;
  if (p_payload ->> 'checksum') is null then
    v_errors := array_append(v_errors, 'Berkas backup tidak memiliki checksum.');
  elsif md5((p_payload -> 'data')::text) is distinct from (p_payload ->> 'checksum') then
    v_errors := array_append(v_errors,
      'Checksum tidak cocok: isi berkas telah berubah atau rusak sejak backup dibuat.');
  end if;
  if (p_payload ->> 'entity_id') is distinct from p_entity::text then
    v_errors := array_append(v_errors, 'Backup ini milik Entity lain (ID Entity berbeda).');
  end if;

  for v_tbl in select jsonb_object_keys(p_payload -> 'data') loop
    if jsonb_typeof(p_payload -> 'data' -> v_tbl) <> 'array' then
      continue;
    end if;
    if v_tbl <> 'entity_memberships' and not (v_tbl = any (v_restorable)) then
      v_unknown := array_append(v_unknown, v_tbl);
      continue;
    end if;
    for v_row in select jsonb_array_elements(p_payload -> 'data' -> v_tbl) loop
      if (v_row ->> 'entity_id') is distinct from p_entity::text then
        v_foreign := v_foreign + 1;
      end if;
    end loop;
  end loop;
  if v_foreign > 0 then
    v_errors := array_append(v_errors, format('%s baris berasal dari Entity lain.', v_foreign));
  end if;
  if cardinality(v_unknown) > 0 then
    v_errors := array_append(v_errors, format(
      'Tabel tidak dikenal oleh versi aplikasi ini: %s.', array_to_string(v_unknown, ', ')));
  end if;

  v_target := app_private.restore_target_rows(p_entity);
  if v_target <> '{}'::jsonb then
    v_errors := array_append(v_errors,
      'Entity tujuan tidak kosong. Pemulihan hanya dilakukan ke Entity yang belum berisi data (keputusan OWNER).');
  end if;
  if jsonb_typeof(p_payload -> 'data' -> 'entity_memberships') = 'array'
     and jsonb_array_length(p_payload -> 'data' -> 'entity_memberships') > 0 then
    v_warnings := array_append(v_warnings, format(
      '%s keanggotaan pengguna dalam backup tidak dipulihkan; akses diatur ulang di Pengguna & Peran.',
      jsonb_array_length(p_payload -> 'data' -> 'entity_memberships')));
  end if;
  if (p_payload ->> 'kind') = 'data_only' then
    v_warnings := array_append(v_warnings,
      'Backup Data Saja tidak berisi jejak audit maupun metadata dokumen.');
  end if;

  return jsonb_build_object('errors', to_jsonb(v_errors), 'warnings', to_jsonb(v_warnings),
                            'target_rows', v_target);
end
$$;

-- ------------------------------------------------------------ preview impact (read-only)
create function public.preview_backup_restore(p_entity uuid, p_file text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, public as $$
declare
  p_payload jsonb := app_private.restore_parse(p_file);
  v_check jsonb;
  v_counts jsonb := '{}'::jsonb;
  v_tbl text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'backup.restore') then
    raise exception 'FORBIDDEN: missing backup.restore' using errcode = 'insufficient_privilege';
  end if;
  v_check := app_private.restore_check(p_entity, p_payload);
  if jsonb_typeof(p_payload -> 'data') = 'object' then
    for v_tbl in select jsonb_object_keys(p_payload -> 'data') loop
      if jsonb_typeof(p_payload -> 'data' -> v_tbl) = 'array' and v_tbl <> 'entity_memberships' then
        v_counts := v_counts || jsonb_build_object(v_tbl, jsonb_array_length(p_payload -> 'data' -> v_tbl));
      end if;
    end loop;
  end if;
  return jsonb_build_object(
    'ok', jsonb_array_length(v_check -> 'errors') = 0,
    'errors', v_check -> 'errors',
    'warnings', v_check -> 'warnings',
    'target_rows', coalesce(v_check -> 'target_rows', '{}'::jsonb),
    'table_counts', v_counts,
    'step_up_ok', app_authz.recent_step_up());
end
$$;

-- ------------------------------------------------------------ restore
create function app_private.restore_write(p_entity uuid, p_data jsonb) returns jsonb
language plpgsql as $$
declare
  v_tables text[];
  v_done text[] := array[]::text[];
  v_pending text[];
  v_pick text;
  v_null_cols text[];
  v_deferred jsonb := '{}'::jsonb;  -- table -> array of columns to fill after all inserts
  v_cols text;
  v_select text;
  v_col text;
  v_counts jsonb := '{}'::jsonb;
  v_n bigint;
begin
  select coalesce(array_agg(k order by k), array[]::text[]) into v_tables
  from jsonb_object_keys(p_data) k
  where k = any (app_private.restore_tables())
    and jsonb_typeof(p_data -> k) = 'array' and jsonb_array_length(p_data -> k) > 0;

  foreach v_pick in array v_tables loop
    if v_pick <> 'audit_events' then
      execute format('alter table public.%I disable trigger user', v_pick);
    end if;
  end loop;

  v_pending := v_tables;
  while cardinality(v_pending) > 0 loop
    -- 1. a table whose in-set parents are all written
    select t into v_pick from unnest(v_pending) t
    where not exists (
      select 1 from pg_constraint k
      join pg_class c on c.oid = k.conrelid join pg_class p on p.oid = k.confrelid
      join pg_namespace n on n.oid = c.relnamespace
      where k.contype = 'f' and n.nspname = 'public' and c.relname = t
        and p.relname <> t and p.relname = any (v_tables) and not (p.relname = any (v_done)))
    order by t limit 1;
    v_null_cols := array[]::text[];
    -- 2. otherwise break a cycle: a table whose unresolved parent links are all nullable columns
    if v_pick is null then
      select t into v_pick from unnest(v_pending) t
      where not exists (
        select 1 from pg_constraint k
        join pg_class c on c.oid = k.conrelid join pg_class p on p.oid = k.confrelid
        join pg_namespace n on n.oid = c.relnamespace
        join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any (k.conkey)
        where k.contype = 'f' and n.nspname = 'public' and c.relname = t and p.relname <> t
          and p.relname = any (v_tables) and not (p.relname = any (v_done))
          and a.attname <> 'entity_id' and a.attnotnull)
      order by t limit 1;
      if v_pick is null then
        raise exception 'INVALID: tables cannot be ordered for restore (non-nullable FK cycle)'
          using errcode = 'invalid_parameter_value';
      end if;
      select coalesce(array_agg(distinct a.attname::text), array[]::text[]) into v_null_cols
      from pg_constraint k
      join pg_class c on c.oid = k.conrelid join pg_class p on p.oid = k.confrelid
      join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any (k.conkey)
      where k.contype = 'f' and n.nspname = 'public' and c.relname = v_pick and p.relname <> v_pick
        and p.relname = any (v_tables) and not (p.relname = any (v_done)) and a.attname <> 'entity_id';
      v_deferred := v_deferred || jsonb_build_object(v_pick, to_jsonb(v_null_cols));
    end if;

    select string_agg(quote_ident(a.attname), ', ' order by a.attnum),
           string_agg(case when a.attname = any (v_null_cols) then 'null' else 'r.' || quote_ident(a.attname) end,
                      ', ' order by a.attnum)
      into v_cols, v_select
    from pg_attribute a
    where a.attrelid = format('public.%I', v_pick)::regclass and a.attnum > 0
      and not a.attisdropped and a.attgenerated = '';

    execute format(
      'insert into public.%I (%s) overriding system value select %s from jsonb_populate_recordset(null::public.%I, $1) r',
      v_pick, v_cols, v_select, v_pick)
      using p_data -> v_pick;
    get diagnostics v_n = row_count;
    v_counts := v_counts || jsonb_build_object(v_pick, v_n);
    v_done := array_append(v_done, v_pick);
    v_pending := array_remove(v_pending, v_pick);
  end loop;

  -- fill the columns held back to break a cycle
  for v_pick in select jsonb_object_keys(v_deferred) loop
    for v_col in select jsonb_array_elements_text(v_deferred -> v_pick) loop
      execute format(
        'update public.%I t set %I = r.%I from jsonb_populate_recordset(null::public.%I, $1) r
          where t.id = r.id and r.%I is not null',
        v_pick, v_col, v_col, v_pick, v_col)
        using p_data -> v_pick;
    end loop;
  end loop;

  foreach v_pick in array v_tables loop
    if v_pick <> 'audit_events' then
      execute format('alter table public.%I enable trigger user', v_pick);
    end if;
  end loop;
  return v_counts;
end
$$;

-- Integrity after writing: exact row counts, every posted journal balances, trial balance balances.
create function app_private.restore_integrity(p_entity uuid, p_data jsonb, p_counts jsonb) returns jsonb
language plpgsql stable as $$
declare
  v_tbl text;
  v_mismatch text[] := array[]::text[];
  v_unbalanced bigint;
  v_tb numeric;
begin
  for v_tbl in select jsonb_object_keys(p_counts) loop
    if (p_counts ->> v_tbl)::bigint <> jsonb_array_length(p_data -> v_tbl) then
      v_mismatch := array_append(v_mismatch, v_tbl);
    end if;
  end loop;
  select count(*) into v_unbalanced from (
    select l.journal_id from public.journal_lines l
    join public.journal_entries j on j.id = l.journal_id and j.status = 'posted'
    where l.entity_id = p_entity
    group by l.journal_id having sum(l.debit) <> sum(l.credit)) x;
  select coalesce(sum(l.debit - l.credit), 0) into v_tb
  from public.journal_lines l join public.journal_entries j on j.id = l.journal_id and j.status = 'posted'
  where l.entity_id = p_entity;
  return jsonb_build_object(
    'ok', cardinality(v_mismatch) = 0 and v_unbalanced = 0 and v_tb = 0,
    'count_mismatches', to_jsonb(v_mismatch),
    'unbalanced_journals', v_unbalanced,
    'trial_balance_difference', v_tb);
end
$$;

create function public.restore_backup_snapshot(p_entity uuid, p_file text, p_confirm text)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  p_payload jsonb := app_private.restore_parse(p_file);
  v_check jsonb;
  v_code text;
  v_counts jsonb;
  v_integrity jsonb;
  v_job uuid;
  v_error text;
  v_skipped jsonb := '{}'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'backup.restore') then
    raise exception 'FORBIDDEN: missing backup.restore' using errcode = 'insufficient_privilege';
  end if;
  if not app_authz.recent_step_up() then
    raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
  end if;
  select code into v_code from public.entities where id = p_entity;
  if p_confirm is distinct from v_code then
    raise exception 'INVALID: type the Entity code to confirm the restore' using errcode = 'invalid_parameter_value';
  end if;
  -- One restore at a time per Entity.
  perform pg_advisory_xact_lock(hashtextextended('restore:' || p_entity::text, 0));

  v_check := app_private.restore_check(p_entity, p_payload);
  if jsonb_array_length(v_check -> 'errors') > 0 then
    raise exception 'CONFLICT: %', v_check ->> 'errors' using errcode = 'integrity_constraint_violation';
  end if;
  if jsonb_typeof(p_payload -> 'data' -> 'entity_memberships') = 'array' then
    v_skipped := jsonb_build_object('entity_memberships',
                                    jsonb_array_length(p_payload -> 'data' -> 'entity_memberships'));
  end if;

  begin
    v_counts := app_private.restore_write(p_entity, p_payload -> 'data');
    v_integrity := app_private.restore_integrity(p_entity, p_payload -> 'data', v_counts);
    if not (v_integrity ->> 'ok')::boolean then
      raise exception 'restore integrity check failed: %', v_integrity::text;
    end if;
  exception when others then
    v_error := sqlerrm;
  end;

  insert into public.restore_jobs
    (entity_id, requested_by, source_kind, source_checksum, status, table_counts, skipped, integrity, error)
  values
    (p_entity, auth.uid(), p_payload ->> 'kind', p_payload ->> 'checksum',
     case when v_error is null then 'completed' else 'failed' end,
     coalesce(v_counts, '{}'::jsonb), v_skipped, coalesce(v_integrity, '{}'::jsonb), v_error)
  returning id into v_job;

  insert into public.audit_events (entity_id, actor_type, actor_id, action, target_table, target_id, after_state, reason)
  values (p_entity, 'user', auth.uid(),
          case when v_error is null then 'restore_jobs.completed' else 'restore_jobs.failed' end,
          'restore_jobs', v_job,
          jsonb_build_object('source_checksum', p_payload ->> 'checksum', 'table_counts', v_counts,
                             'integrity', v_integrity, 'error', v_error),
          'Backup restore');

  return jsonb_build_object('job_id', v_job, 'status', case when v_error is null then 'completed' else 'failed' end,
                            'table_counts', coalesce(v_counts, '{}'::jsonb), 'skipped', v_skipped,
                            'integrity', coalesce(v_integrity, '{}'::jsonb), 'error', v_error);
end
$$;

-- ------------------------------------------------------------ trusted device revocation (Step 07 §21)
-- A person may always revoke their own trusted device; revoking someone else's needs `security.manage`
-- on an Entity both share and a recent step-up. Revocation is final (Active -> Revoked).
create function public.revoke_trusted_device(p_device uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_dev public.trusted_devices%rowtype;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  select * into v_dev from public.trusted_devices where id = p_device for update;
  if not found then
    raise exception 'NOT_FOUND: trusted device not found' using errcode = 'no_data_found';
  end if;
  if v_dev.user_id <> auth.uid() then
    if not app_authz.shares_entity_with(v_dev.user_id, 'security.manage') then
      raise exception 'FORBIDDEN: missing security.manage' using errcode = 'insufficient_privilege';
    end if;
    if not app_authz.recent_step_up() then
      raise exception 'STEP_UP_REQUIRED' using errcode = 'insufficient_privilege';
    end if;
  end if;
  if v_dev.revoked_at is not null then
    return;
  end if;
  update public.trusted_devices set revoked_at = now() where id = p_device;
  insert into public.security_events (user_id, event_type, severity, metadata)
  values (v_dev.user_id, 'trusted_device.revoked', 'warning',
          jsonb_build_object('device_id', p_device, 'revoked_by', auth.uid(),
                             'reason', nullif(btrim(coalesce(p_reason, '')), '')));
end
$$;

revoke all on function app_private.restore_parse(text), app_private.restore_tables(),
  app_private.restore_target_rows(uuid),
  app_private.restore_check(uuid, jsonb), app_private.restore_write(uuid, jsonb),
  app_private.restore_integrity(uuid, jsonb, jsonb) from public;
grant execute on function public.export_backup_file(uuid, text) to authenticated;
grant execute on function public.preview_backup_restore(uuid, text) to authenticated;
grant execute on function public.restore_backup_snapshot(uuid, text, text) to authenticated;
grant execute on function public.revoke_trusted_device(uuid, text) to authenticated;
