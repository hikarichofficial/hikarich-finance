-- P14 gate, part 2 (Step 15 §18, Step 07 §21-§22, Step 14 §9, Step 16 §34, decision 247): the restore-write
-- path, exercised as a repeatable non-production restore DRILL -- export an Entity with real records, empty
-- it the way a fresh database would be, restore the file, and prove the restored data is identical to what
-- was exported. Also: preview, authorization, step-up, typed confirmation, checksum/tamper detection, the
-- empty-target rule, a failed restore that leaves nothing behind, and trusted-device revocation. All data is
-- synthetic; the whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p14r (k text primary key, v uuid);
create table test_helpers.p14f (k text primary key, f text not null);
grant all on test_helpers.p14r, test_helpers.p14f to public;

-- ================================================================ 1. fixtures
do $$
declare
  r1 uuid;
  v_owner uuid := 'e1470000-0000-0000-0000-000000000001';
  v_admin uuid := 'e1470000-0000-0000-0000-000000000002';
  v_cat uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p14_r1', 'P14 Restore (synthetic)')
  returning id into r1;
  insert into public.entity_profiles (entity_id, city) values (r1, 'Bandung');
  perform app_private.provision_default_coa(r1);
  perform app_private.ensure_accounting_period(r1, date '2026-09-15');
  insert into public.financial_accounts (entity_id, kind, name, institution_name, currency, ledger_account_id)
  values (r1, 'bank', 'Drill Bank', 'Drill', 'IDR', test_helpers.acct(r1, 'BANK_OPERATING'));
  insert into public.categories (entity_id, name, kind) values (r1, 'Drill Sales', 'revenue') returning id into v_cat;
  insert into public.contacts (entity_id, kind, display_name) values (r1, 'customer', 'Drill Customer');
  insert into public.products (entity_id, kind, sku, name, default_unit_price, default_currency, default_category_id)
  values (r1, 'service', 'DRILL-1', 'Drill Service', 1234567.8900, 'IDR', v_cat);

  perform test_helpers.mk_user(v_owner, 'p14r-owner');
  perform test_helpers.mk_user(v_admin, 'p14r-admin');
  perform test_helpers.mk_member(r1, v_owner, 'owner');
  perform test_helpers.mk_member(r1, v_admin, 'finance_admin');
  insert into test_helpers.p14r values ('r1', r1), ('owner', v_owner), ('admin', v_admin);

  -- A posted journal through the real workflow, with a large exact amount (16 significant digits).
  perform test_helpers.login(v_owner);
  perform public.post_opening_balances(
    r1, gen_random_uuid()::text, date '2026-09-15',
    jsonb_build_array(jsonb_build_object(
      'account_id', test_helpers.acct(r1, 'BANK_OPERATING'), 'debit', '12345678901234.56')), 'drill');
  insert into test_helpers.p14f values ('orig', public.export_backup_file(r1, 'full'));
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. preview refuses a non-empty target
do $$
declare
  r1 uuid := (select v from test_helpers.p14r where k = 'r1');
  v_file text := (select f from test_helpers.p14f where k = 'orig');
  v jsonb;
begin
  perform test_helpers.assert(v_file like '%12345678901234.56%', 'exported file keeps the exact amount text');
  perform test_helpers.login((select v from test_helpers.p14r where k = 'owner'));
  v := public.preview_backup_restore(r1, v_file);
  perform test_helpers.assert(not (v ->> 'ok')::boolean, 'non-empty target is not restorable');
  perform test_helpers.assert(v ->> 'errors' like '%tidak kosong%', 'non-empty target error is explained');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. empty the Entity like a fresh database
-- (test-only superuser shortcut; memberships stay, as an OWNER would have re-created them)
do $$
declare
  r1 uuid := (select v from test_helpers.p14r where k = 'r1');
  t text;
begin
  set local session_replication_role = replica;
  foreach t in array app_private.restore_tables() loop
    execute format('delete from public.%I where entity_id = %L', t, r1);
  end loop;
  set local session_replication_role = origin;
  perform test_helpers.assert(app_private.restore_target_rows(r1) = '{}'::jsonb, 'target is empty');
end
$$;

-- ================================================================ 4. authorization, step-up, confirmation, tampering
do $$
declare
  r1 uuid := (select v from test_helpers.p14r where k = 'r1');
  v_file text := (select f from test_helpers.p14f where k = 'orig');
  v_tampered text := replace(v_file, '"Drill Customer"', '"Someone Else"');
  v jsonb;
begin
  perform test_helpers.login((select v from test_helpers.p14r where k = 'admin'));
  perform test_helpers.expect_msg(format('select public.preview_backup_restore(%L, %L)', r1, v_file),
    'FORBIDDEN', 'finance_admin cannot preview a restore');
  perform test_helpers.expect_msg(format('select public.restore_backup_snapshot(%L, %L, %L)', r1, v_file, 'p14_r1'),
    'FORBIDDEN', 'finance_admin cannot restore');
  perform test_helpers.logout();

  perform test_helpers.login((select v from test_helpers.p14r where k = 'owner'), 'aal2', interval '1 hour');
  perform test_helpers.expect_msg(format('select public.restore_backup_snapshot(%L, %L, %L)', r1, v_file, 'p14_r1'),
    'STEP_UP_REQUIRED', 'restore needs a recent step-up');
  perform test_helpers.logout();

  perform test_helpers.login((select v from test_helpers.p14r where k = 'owner'));
  perform test_helpers.expect_msg(format('select public.restore_backup_snapshot(%L, %L, %L)', r1, v_file, 'wrong'),
    'INVALID', 'restore needs the typed Entity code');
  v := public.preview_backup_restore(r1, v_tampered);
  perform test_helpers.assert(not (v ->> 'ok')::boolean and v ->> 'errors' like '%Checksum%', 'tampering is detected');
  v := public.preview_backup_restore(r1, 'not json');
  perform test_helpers.assert(not (v ->> 'ok')::boolean, 'a non-JSON file is rejected');
  v := public.preview_backup_restore(r1, v_file);
  perform test_helpers.assert((v ->> 'ok')::boolean, 'the genuine file previews clean on an empty target');
  perform test_helpers.assert((v -> 'table_counts' ->> 'journal_lines')::int >= 2, 'preview reports row counts');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 5. a failing restore leaves nothing behind
do $$
declare
  r1 uuid := (select v from test_helpers.p14r where k = 'r1');
  v_payload jsonb := (select f from test_helpers.p14f where k = 'orig')::jsonb;
  v_data jsonb;
  v jsonb;
begin
  -- A journal line pointing at a journal that does not exist, re-checksummed so it passes validation.
  v_data := jsonb_set(v_payload -> 'data', '{journal_lines,0,journal_id}', to_jsonb(gen_random_uuid()));
  v_payload := jsonb_set(jsonb_set(v_payload, '{data}', v_data), '{checksum}', to_jsonb(md5(v_data::text)));
  perform test_helpers.login((select v from test_helpers.p14r where k = 'owner'));
  v := public.restore_backup_snapshot(r1, v_payload::text, 'p14_r1');
  perform test_helpers.assert(v ->> 'status' = 'failed', 'broken reference fails the restore');
  perform test_helpers.logout();
  perform test_helpers.assert(app_private.restore_target_rows(r1) = '{}'::jsonb, 'failed restore wrote nothing');
  perform test_helpers.assert(
    exists (select 1 from public.restore_jobs where entity_id = r1 and status = 'failed' and error is not null),
    'failed restore is recorded');
  perform test_helpers.assert(
    exists (select 1 from public.audit_events where entity_id = r1 and action = 'restore_jobs.failed'),
    'failed restore is audited');
end
$$;

-- ================================================================ 6. the drill: restore and compare
do $$
declare
  r1 uuid := (select v from test_helpers.p14r where k = 'r1');
  v_orig jsonb := ((select f from test_helpers.p14f where k = 'orig')::jsonb) -> 'data';
  v_after jsonb;
  v jsonb;
  t text;
  n bigint;
begin
  perform test_helpers.login((select v from test_helpers.p14r where k = 'owner'));
  v := public.restore_backup_snapshot(r1, (select f from test_helpers.p14f where k = 'orig'), 'p14_r1');
  perform test_helpers.assert(v ->> 'status' = 'completed', 'restore completes: ' || coalesce(v ->> 'error', ''));
  perform test_helpers.assert((v -> 'integrity' ->> 'ok')::boolean, 'integrity check passes');
  perform test_helpers.assert((v -> 'integrity' ->> 'trial_balance_difference')::numeric = 0, 'trial balance balances');
  perform test_helpers.assert((v -> 'skipped' ->> 'entity_memberships')::int = 2, 'memberships are reported, not restored');
  v_after := (public.export_backup_file(r1, 'full')::jsonb) -> 'data';
  perform test_helpers.logout();

  for t in select jsonb_object_keys(v_orig) loop
    continue when t in ('audit_events', 'entity_memberships');
    select count(*) into n from (
      select jsonb_array_elements(v_orig -> t) except select jsonb_array_elements(v_after -> t)) x;
    perform test_helpers.assert(n = 0, format('restored %s matches the backup (missing %s)', t, n));
    select count(*) into n from (
      select jsonb_array_elements(v_after -> t) except select jsonb_array_elements(v_orig -> t)) x;
    perform test_helpers.assert(n = 0, format('restored %s has nothing extra (%s)', t, n));
  end loop;
  perform test_helpers.assert(
    (select default_unit_price from public.products where entity_id = r1 and sku = 'DRILL-1') = 1234567.8900,
    'product price restored exactly');
  perform test_helpers.assert(
    (select sum(debit) from public.journal_lines where entity_id = r1) = 12345678901234.56,
    'large journal amount restored exactly');
  perform test_helpers.assert(
    exists (select 1 from public.audit_events where entity_id = r1 and action = 'restore_jobs.completed'),
    'completed restore is audited');

  -- the Entity is no longer empty: a second restore is refused
  perform test_helpers.login((select v from test_helpers.p14r where k = 'owner'));
  perform test_helpers.expect_msg(
    format('select public.restore_backup_snapshot(%L, %L, %L)', r1, (select f from test_helpers.p14f where k = 'orig'), 'p14_r1'),
    'CONFLICT', 'a non-empty Entity cannot be restored over');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 7. trusted device revocation
do $$
declare
  v_owner uuid := (select v from test_helpers.p14r where k = 'owner');
  v_admin uuid := (select v from test_helpers.p14r where k = 'admin');
  d_owner uuid;
  d_admin uuid;
begin
  insert into public.trusted_devices (user_id, fingerprint_hash, label) values (v_owner, 'fp-owner', 'Owner Mac')
  returning id into d_owner;
  insert into public.trusted_devices (user_id, fingerprint_hash, label) values (v_admin, 'fp-admin', 'Admin iPhone')
  returning id into d_admin;

  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.revoke_trusted_device(%L)', d_owner),
    'FORBIDDEN', 'finance_admin cannot revoke someone else''s device');
  perform public.revoke_trusted_device(d_admin, 'lost phone');
  perform test_helpers.logout();
  perform test_helpers.assert(
    (select revoked_at is not null from public.trusted_devices where id = d_admin), 'own device revoked');

  perform test_helpers.login(v_owner, 'aal2', interval '1 hour');
  perform test_helpers.expect_msg(format('select public.revoke_trusted_device(%L)', d_admin),
    'STEP_UP_REQUIRED', 'revoking another person''s device needs step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform public.revoke_trusted_device(d_owner);
  perform test_helpers.logout();
  perform test_helpers.assert(
    (select count(*) from public.security_events where event_type = 'trusted_device.revoked'
       and user_id in (v_owner, v_admin)) = 2, 'each revocation is a security event');
end
$$;

rollback;
