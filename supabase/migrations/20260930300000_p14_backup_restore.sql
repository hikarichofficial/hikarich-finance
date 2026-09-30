-- P14 (Step 15 §18 Hardening/Recovery, Step 01 #36, Step 16 §34): Backup & Restore Center, Part 1 --
-- export backend. Authority: Step 01 #36 ("Full Backup, Data-only Backup, Documents Archive;
-- validation before restore; history/reminders; external storage encouraged"), Step 16 §34 (Backup /
-- Recovery Acceptance) and docs/DECISIONS.md line 10 (recovery relies on this in-app Center, not paid
-- Supabase managed backups).
--
-- Decision 223/224: this Center did not exist before this migration -- only a navigation placeholder
-- did (`src/domain/shell/navigation.ts`) -- and `backup.create`/`backup.restore` were already
-- catalogued in `20260920100100_p2_permission_catalog.sql` but never wired to any RPC. OWNER holds
-- both automatically (`app_authz.has_permission`'s own owner-bypass rule); no new grant is needed to
-- any role template.
--
-- Part 1 scope (decision 224): export + history + validate-before-restore, all read-only or
-- append-only. The actual restore-write path is deliberately deferred to a Part 2 increment for its
-- own dedicated build/test/review pass -- it is the higher-stakes half (writing recovered data back
-- over, or alongside, real financial records), matching this project's established practice of
-- splitting high-stakes work into ordered Parts (e.g. the P13 Part 6 Drawer/Global Search retrofit).
--
-- Export design: dynamically enumerates every public-schema base table carrying an `entity_id` column
-- via `information_schema` rather than a hand-maintained table list, so a future migration that adds a
-- new Entity-scoped table is automatically included without this migration needing an update -- the
-- same "never goes stale" reasoning `scripts/db-test.sh`'s `upgrade_test` (decision 221) already
-- established for this project. `backup_jobs` itself is excluded by name (a backup does not back up
-- its own history log).
--
-- Full vs Data-only: "Full" is every Entity-scoped table. "Data-only" is the same set minus
-- `audit_events` (an append-only historical trail, not part of current state to restore) and
-- `documents`/`document_links` (file metadata with no underlying bytes yet -- Supabase Storage is not
-- configured, decision 142 -- so including them in a "data" backup would misleadingly imply a document
-- restore that cannot happen). This distinction is this session's own documented, buildable
-- interpretation: the locked spec (#36) names the two kinds without itemizing which tables each
-- covers.
--
-- Documents Archive: honestly reflects that Supabase Storage is not yet configured (decision 142) --
-- it returns the `documents` row manifest for the Entity (so the *shape* of the feature is complete
-- and ready for when Storage is configured) with an explicit `storage_configured: false` flag and zero
-- attached file bytes, rather than silently omitting the "Documents Archive" kind or pretending file
-- contents exist.

-- ------------------------------------------------------------ history log
create table public.backup_jobs (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id),
  kind text not null check (kind in ('full', 'data_only', 'documents_archive')),
  requested_by uuid not null references public.profiles (id),
  table_count integer not null default 0,
  row_counts jsonb not null default '{}'::jsonb,
  byte_size bigint not null default 0,
  checksum text not null,
  created_at timestamptz not null default now(),
  unique (entity_id, id)
);

create index backup_jobs_entity_created_idx on public.backup_jobs (entity_id, created_at desc);

create trigger tg_lock_entity before update on public.backup_jobs
  for each row execute function app_private.tg_lock_entity();

alter table public.backup_jobs enable row level security;
call app_private.expose_select('public.backup_jobs');
create policy backup_jobs_select on public.backup_jobs for select to authenticated
  using (app_authz.has_permission(entity_id, 'backup.create'));
-- No insert/update/delete grant to `authenticated`: rows are written only by
-- `public.export_backup_snapshot` below (SECURITY DEFINER), matching `audit_events`'s own
-- select-only-to-browsers shape.

-- ------------------------------------------------------------ export
-- The Entity-scoped table list for a given backup kind (`app_private`, not exposed to the Data API).
create function app_private.backup_export_tables(p_kind text) returns text[]
language plpgsql stable as $$
declare
  v_all text[];
  v_exclude text[];
begin
  select array_agg(distinct c.table_name order by c.table_name) into v_all
  from information_schema.columns c
  join information_schema.tables t
    on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
  where c.table_schema = 'public' and c.column_name = 'entity_id' and c.table_name <> 'backup_jobs';

  v_exclude := case when p_kind = 'data_only'
                    then array['audit_events', 'documents', 'document_links']
                    else array[]::text[] end;
  return coalesce(
    (select array_agg(x order by x) from unnest(v_all) x where x <> all (v_exclude)),
    array[]::text[]);
end
$$;

-- Full Backup / Data-only Backup / Documents Archive export (Step 01 #36). Read-only against every
-- source table; the only write is its own `backup_jobs` history row (Step 01 #36's "history").
create function public.export_backup_snapshot(p_entity uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_tables text[];
  v_payload jsonb := '{}'::jsonb;
  v_counts jsonb := '{}'::jsonb;
  v_tbl text;
  v_rows jsonb;
  v_job_id uuid;
  v_checksum text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'backup.create') then
    raise exception 'FORBIDDEN: missing backup.create' using errcode = 'insufficient_privilege';
  end if;
  if p_kind not in ('full', 'data_only', 'documents_archive') then
    raise exception 'INVALID: unknown backup kind %', p_kind using errcode = 'invalid_parameter_value';
  end if;

  v_tables := case when p_kind = 'documents_archive' then array['documents', 'document_links']
                   else app_private.backup_export_tables(p_kind) end;

  foreach v_tbl in array v_tables loop
    execute format(
      -- Not every Entity-scoped table has its own `id` column (e.g. `entity_profiles`, one row per
      -- Entity, keyed by `entity_id` alone) -- row order is not itself meaningful for a backup, so this
      -- never assumes one.
      'select coalesce(jsonb_agg(t), %L::jsonb) from public.%I t where t.entity_id = %L',
      '[]', v_tbl, p_entity)
      into v_rows;
    v_payload := v_payload || jsonb_build_object(v_tbl, v_rows);
    v_counts := v_counts || jsonb_build_object(v_tbl, jsonb_array_length(v_rows));
  end loop;

  if p_kind = 'documents_archive' then
    v_payload := v_payload || jsonb_build_object('storage_configured', false);
  end if;

  v_checksum := md5(v_payload::text);

  insert into public.backup_jobs
    (entity_id, kind, requested_by, table_count, row_counts, byte_size, checksum)
  values
    (p_entity, p_kind, auth.uid(), cardinality(v_tables), v_counts, octet_length(v_payload::text), v_checksum)
  returning id into v_job_id;

  return jsonb_build_object(
    'job_id', v_job_id, 'entity_id', p_entity, 'kind', p_kind, 'checksum', v_checksum,
    'created_at', now(), 'table_counts', v_counts, 'data', v_payload);
end
$$;

-- ------------------------------------------------------------ validate-before-restore (read-only)
-- Validates a previously exported payload's shape before any restore is attempted (Step 01 #36's own
-- "validation before restore"). Never writes anything -- the actual restore/write path is Part 2.
create function public.validate_backup_payload(p_entity uuid, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_errors text[] := array[]::text[];
  v_warnings text[] := array[]::text[];
  v_tables text[];
  v_tbl text;
  v_row jsonb;
  v_foreign_rows integer := 0;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'backup.restore') then
    raise exception 'FORBIDDEN: missing backup.restore' using errcode = 'insufficient_privilege';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    v_errors := array_append(v_errors, 'Berkas backup bukan objek JSON yang valid.');
  elsif not (p_payload ? 'data') or jsonb_typeof(p_payload -> 'data') <> 'object' then
    v_errors := array_append(v_errors, 'Berkas backup tidak memiliki bagian "data" yang diharapkan.');
  else
    if not (p_payload ? 'checksum') then
      v_warnings := array_append(v_warnings, 'Tidak ada checksum untuk diverifikasi silang.');
    end if;
    if (p_payload ->> 'entity_id') is distinct from p_entity::text then
      v_warnings := array_append(v_warnings,
        'Backup ini awalnya dibuat untuk Entity yang berbeda dari Entity saat ini.');
    end if;

    v_tables := app_private.backup_export_tables('full');
    for v_tbl in select unnest(v_tables) loop
      if jsonb_typeof(p_payload -> 'data' -> v_tbl) = 'array' then
        for v_row in select jsonb_array_elements(p_payload -> 'data' -> v_tbl) loop
          if (v_row ->> 'entity_id') is distinct from p_entity::text then
            v_foreign_rows := v_foreign_rows + 1;
          end if;
        end loop;
      end if;
    end loop;
    if v_foreign_rows > 0 then
      v_errors := array_append(v_errors,
        format('%s baris berasal dari Entity lain dan tidak dapat dipulihkan ke Entity ini.',
               v_foreign_rows));
    end if;
  end if;

  return jsonb_build_object(
    'ok', cardinality(v_errors) = 0, 'errors', to_jsonb(v_errors), 'warnings', to_jsonb(v_warnings));
end
$$;

grant execute on function public.export_backup_snapshot(uuid, text) to authenticated;
grant execute on function public.validate_backup_payload(uuid, jsonb) to authenticated;
