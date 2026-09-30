-- P14 gate, part 1 (Step 15 §18, Step 01 #36, Step 16 §34, decision 224): Backup & Restore Center
-- export + validate-before-restore. The restore-write path itself does not exist yet (Part 2,
-- deliberately deferred) -- nothing here exercises a restore. All data is synthetic. The whole file
-- runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p14b (k text primary key, v uuid not null);
grant all on test_helpers.p14b to public;
create function test_helpers.p14put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p14b values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.p14g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p14b where k = p_k $f$;
grant execute on function test_helpers.p14put(text, uuid), test_helpers.p14g(text) to public;

-- ================================================================ 1. fixtures
do $$
declare
  pt1 uuid;
  pt2 uuid;
  v_owner uuid := 'e1400000-0000-0000-0000-000000000001';
  v_admin uuid := 'e1400000-0000-0000-0000-000000000002';
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p14_pt1', 'P14 PT 1 (synthetic)')
  returning id into pt1;
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p14_pt2', 'P14 PT 2 (synthetic)')
  returning id into pt2;
  perform app_private.provision_default_coa(pt1);
  perform app_private.provision_default_coa(pt2);
  perform test_helpers.p14put('pt1', pt1);
  perform test_helpers.p14put('pt2', pt2);

  perform test_helpers.mk_user(v_owner, 'p14-owner');
  perform test_helpers.mk_user(v_admin, 'p14-admin');
  perform test_helpers.p14put('owner', v_owner);
  perform test_helpers.p14put('admin', v_admin);

  -- Owner on both Entities (so an owner-context export of pt1 can be checked against pt2's data never
  -- leaking in); finance_admin on pt1 only, and finance_admin holds neither backup.create nor
  -- backup.restore (Step 06 §3 matrix, confirmed directly against the P2 permission-catalog grants).
  perform test_helpers.mk_member(pt1, v_owner, 'owner');
  perform test_helpers.mk_member(pt2, v_owner, 'owner');
  perform test_helpers.mk_member(pt1, v_admin, 'finance_admin');
end
$$;

-- ================================================================ 2. export: authorization
do $$
declare
  pt1 uuid := test_helpers.p14g('pt1');
  v_owner uuid := test_helpers.p14g('owner');
  v_admin uuid := test_helpers.p14g('admin');
begin
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(
    format('select public.export_backup_snapshot(%L, %L)', pt1, 'full'),
    'FORBIDDEN', 'finance_admin lacks backup.create');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(
    format('select public.export_backup_snapshot(%L, %L)', pt1, 'not_a_kind'),
    'INVALID', 'unknown backup kind is rejected');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. export: full vs data-only vs documents-archive shape
do $$
declare
  pt1 uuid := test_helpers.p14g('pt1');
  v_owner uuid := test_helpers.p14g('owner');
  v_full jsonb;
  v_data_only jsonb;
  v_archive jsonb;
  v_jobs_before bigint;
  v_jobs_after bigint;
begin
  perform test_helpers.login(v_owner);

  v_jobs_before := test_helpers.rows(format('select 1 from public.backup_jobs where entity_id = %L', pt1));

  v_full := public.export_backup_snapshot(pt1, 'full');
  v_data_only := public.export_backup_snapshot(pt1, 'data_only');
  v_archive := public.export_backup_snapshot(pt1, 'documents_archive');

  v_jobs_after := test_helpers.rows(format('select 1 from public.backup_jobs where entity_id = %L', pt1));
  perform test_helpers.assert(v_jobs_after = v_jobs_before + 3,
    'each export appends exactly one backup_jobs history row');

  perform test_helpers.assert((v_full -> 'table_counts') ? 'ledger_accounts',
    'Full Backup includes ledger_accounts (provisioned by default COA)');
  perform test_helpers.assert(jsonb_array_length(v_full -> 'data' -> 'ledger_accounts') > 0,
    'Full Backup carries actual ledger_accounts rows, not an empty array');
  perform test_helpers.assert(not ((v_data_only -> 'table_counts') ? 'documents'),
    'Data-only Backup excludes documents (Storage unconfigured, decision 142)');
  perform test_helpers.assert(not ((v_data_only -> 'table_counts') ? 'audit_events'),
    'Data-only Backup excludes audit_events (append-only history, not current state)');
  perform test_helpers.assert((v_full -> 'table_counts') ? 'documents',
    'Full Backup includes documents (metadata-only, honestly)');

  perform test_helpers.assert((v_archive -> 'data' ->> 'storage_configured') = 'false',
    'Documents Archive honestly reports storage_configured = false (decision 142)');
  perform test_helpers.assert((v_archive -> 'data') ? 'documents',
    'Documents Archive still returns the documents row manifest, even with zero file bytes');

  perform test_helpers.assert(v_full ->> 'checksum' is not null and v_full ->> 'checksum' <> '',
    'export carries a non-empty checksum');

  perform test_helpers.logout();
end
$$;

-- ================================================================ 4. export: Entity isolation
do $$
declare
  pt1 uuid := test_helpers.p14g('pt1');
  pt2 uuid := test_helpers.p14g('pt2');
  v_owner uuid := test_helpers.p14g('owner');
  v_export jsonb;
  v_foreign_rows integer;
begin
  perform test_helpers.login(v_owner);
  v_export := public.export_backup_snapshot(pt1, 'full');
  select count(*) into v_foreign_rows
  from jsonb_array_elements(v_export -> 'data' -> 'ledger_accounts') r
  where (r ->> 'entity_id') is distinct from pt1::text;
  perform test_helpers.assert(v_foreign_rows = 0,
    'a pt1 export never carries a row belonging to pt2 or any other Entity');
  perform test_helpers.assert(pt2 is not null, 'pt2 fixture exists (sanity)');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 5. validate-before-restore
do $$
declare
  pt1 uuid := test_helpers.p14g('pt1');
  pt2 uuid := test_helpers.p14g('pt2');
  v_owner uuid := test_helpers.p14g('owner');
  v_admin uuid := test_helpers.p14g('admin');
  v_export jsonb;
  v_result jsonb;
  v_tampered jsonb;
begin
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(
    format('select public.validate_backup_payload(%L, %L::jsonb)', pt1, '{}'),
    'FORBIDDEN', 'finance_admin lacks backup.restore');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  v_export := public.export_backup_snapshot(pt1, 'full');

  v_result := public.validate_backup_payload(pt1, v_export);
  perform test_helpers.assert((v_result ->> 'ok') = 'true',
    'a payload just exported for pt1 validates clean against pt1');
  perform test_helpers.assert(jsonb_array_length(v_result -> 'errors') = 0,
    'a clean validation carries no errors');

  v_result := public.validate_backup_payload(pt1, '"not an object"'::jsonb);
  perform test_helpers.assert((v_result ->> 'ok') = 'false',
    'a non-object payload fails validation');

  v_result := public.validate_backup_payload(pt1, '{"no_data_key": true}'::jsonb);
  perform test_helpers.assert((v_result ->> 'ok') = 'false',
    'a payload missing the "data" section fails validation');

  -- Tamper: relabel one ledger_accounts row as belonging to pt2 instead of pt1.
  v_tampered := jsonb_set(
    v_export, array['data', 'ledger_accounts', '0', 'entity_id'], to_jsonb(pt2::text));
  v_result := public.validate_backup_payload(pt1, v_tampered);
  perform test_helpers.assert((v_result ->> 'ok') = 'false',
    'a payload carrying a row from a different Entity fails validation');
  perform test_helpers.assert(jsonb_array_length(v_result -> 'errors') > 0,
    'the cross-Entity row is reported as an error, not silently dropped');

  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. backup_jobs RLS
do $$
declare
  pt1 uuid := test_helpers.p14g('pt1');
  v_owner uuid := test_helpers.p14g('owner');
  v_admin uuid := test_helpers.p14g('admin');
begin
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(
    test_helpers.rows(format('select 1 from public.backup_jobs where entity_id = %L', pt1)) > 0,
    'owner (backup.create) sees the pt1 backup history directly');
  perform test_helpers.logout();

  perform test_helpers.login(v_admin);
  perform test_helpers.assert(
    test_helpers.rows(format('select 1 from public.backup_jobs where entity_id = %L', pt1)) = 0,
    'finance_admin (no backup.create) sees no pt1 backup history rows');
  perform test_helpers.logout();
end
$$;

rollback;
