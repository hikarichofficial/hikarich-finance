-- P14 decision 248 (OWNER answer to decision 237): the Entity's own timezone and fiscal-year start drive
-- its calendar, and the OWNER can change them from Settings. Covers authorization, step-up, reason,
-- validation, optimistic concurrency, the "no fiscal-year change once periods exist" rule, the audit
-- record, and that "today" for the Entity really follows the configured timezone. Synthetic data; the
-- whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p148 (k text primary key, v uuid);
grant all on test_helpers.p148 to public;

do $$
declare
  e1 uuid;
  v_owner uuid := 'e1480000-0000-0000-0000-000000000001';
  v_admin uuid := 'e1480000-0000-0000-0000-000000000002';
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p14_t1', 'P14 Time (synthetic)')
  returning id into e1;
  perform test_helpers.mk_user(v_owner, 'p148-owner');
  perform test_helpers.mk_user(v_admin, 'p148-admin');
  perform test_helpers.mk_member(e1, v_owner, 'owner');
  perform test_helpers.mk_member(e1, v_admin, 'finance_admin');
  insert into test_helpers.p148 values ('e1', e1), ('owner', v_owner), ('admin', v_admin);
end
$$;

do $$
declare
  e1 uuid := (select v from test_helpers.p148 where k = 'e1');
  v_owner uuid := (select v from test_helpers.p148 where k = 'owner');
  v_admin uuid := (select v from test_helpers.p148 where k = 'admin');
  v_ver integer;
  v_new integer;
  q text;
begin
  select version into v_ver from public.entities where id = e1;
  perform test_helpers.assert((select timezone from public.entities where id = e1) = 'Asia/Jakarta'
    and (select fiscal_year_start_month from public.entities where id = e1) = 1,
    '1.0 Indonesian defaults: WIB and a January fiscal year');

  q := format('select public.update_entity_time_settings(%L, %L, 1, %s, %L)', e1, 'Asia/Makassar', v_ver, 'Kantor di Bali');

  -- 1. authorization, step-up, input validation
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(q, 'FORBIDDEN', '1.1 finance_admin lacks system.entity_config');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner, 'aal2', interval '1 hour');
  perform test_helpers.expect_msg(q, 'STEP_UP_REQUIRED', '1.2 a step-up is required');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.update_entity_time_settings(%L, %L, 1, %s, %L)',
    e1, 'Asia/Makassar', v_ver, 'abc'), 'INVALID', '1.3 a short reason is refused');
  perform test_helpers.expect_msg(format('select public.update_entity_time_settings(%L, %L, 1, %s, %L)',
    e1, 'Mars/Olympus', v_ver, 'Zona tidak dikenal'), 'INVALID', '1.4 an unknown timezone is refused');
  perform test_helpers.expect_msg(format('select public.update_entity_time_settings(%L, %L, 13, %s, %L)',
    e1, 'Asia/Jakarta', v_ver, 'Bulan tidak valid'), 'INVALID', '1.5 month 13 is refused');
  perform test_helpers.expect_msg(format('select public.update_entity_time_settings(%L, %L, 1, %s, %L)',
    e1, 'Asia/Makassar', v_ver + 7, 'Versi lama sekali'), 'CONFLICT', '1.6 a stale version is refused');

  -- 2. a valid change: timezone and fiscal-year start (no periods yet)
  execute format('select public.update_entity_time_settings(%L, %L, 4, %s, %L)',
    e1, 'Asia/Makassar', v_ver, 'Kantor di Bali, tahun buku April') into v_new;
  perform test_helpers.logout();
  perform test_helpers.assert(v_new = v_ver + 1, '2.1 the version advances');
  perform test_helpers.assert((select timezone from public.entities where id = e1) = 'Asia/Makassar'
    and (select fiscal_year_start_month from public.entities where id = e1) = 4, '2.2 both settings stored');
  perform test_helpers.assert(exists (select 1 from public.audit_events where entity_id = e1
    and action = 'entities.time_settings_changed' and reason = 'Kantor di Bali, tahun buku April'
    and before_state ->> 'timezone' = 'Asia/Jakarta' and after_state ->> 'fiscal_year_start_month' = '4'),
    '2.3 audited with the reason and before/after');
  perform test_helpers.assert(app_private.entity_today(e1) = (now() at time zone 'Asia/Makassar')::date,
    '2.4 the Entity''s today follows its configured timezone');

  -- 3. once a period exists, the fiscal-year start is locked; the timezone may still change
  perform app_private.ensure_accounting_period(e1, date '2026-09-15');
  perform test_helpers.assert((select fiscal_year from public.accounting_periods where entity_id = e1
    and period_start = date '2026-09-01') = 2026, '3.0 an April fiscal year labels September 2026 as 2026');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.update_entity_time_settings(%L, %L, 1, %s, %L)',
    e1, 'Asia/Makassar', v_new, 'Kembali ke Januari'), 'CONFLICT', '3.1 fiscal-year start locked once periods exist');
  execute format('select public.update_entity_time_settings(%L, %L, 4, %s, %L)',
    e1, 'Asia/Jayapura', v_new, 'Pindah ke Papua') into v_new;
  perform test_helpers.logout();
  perform test_helpers.assert((select timezone from public.entities where id = e1) = 'Asia/Jayapura',
    '3.2 the timezone can still change');

  -- 4. a no-op change returns the current version and writes no new audit record
  perform test_helpers.login(v_owner);
  execute format('select public.update_entity_time_settings(%L, %L, 4, %s, %L)',
    e1, 'Asia/Jayapura', v_new, 'Tidak ada perubahan') into v_ver;
  perform test_helpers.logout();
  perform test_helpers.assert(v_ver = v_new and not exists (select 1 from public.audit_events
    where entity_id = e1 and reason = 'Tidak ada perubahan'), '4.1 a no-op is a no-op');
end
$$;

rollback;
