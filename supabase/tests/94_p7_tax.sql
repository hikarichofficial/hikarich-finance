-- P7 gate (Step 15 §11, Step 16 §15): the tax engine determines from facts and effective-dated rules, never
-- guesses, keeps the rule version and the facts of every historical result, and reconciles to the ledger.
-- Covers the rule master (draft, publish, immutability, effective dates, repeal), the taxpayer facts, the engine
-- switch, the determination of VAT / withholding / final income tax, NEEDS_REVIEW, overrides, the tax ledger and
-- its GL control, tax payments, filings and authorization. All data is synthetic. One transaction, rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p7 (k text primary key, v uuid not null);
grant all on test_helpers.p7 to public;
create function test_helpers.p7put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p7 values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.p7g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p7 where k = p_k $f$;
grant execute on function test_helpers.p7put(text, uuid), test_helpers.p7g(text) to public;

-- Test-only windows onto the engine's lookups that work whichever role the test acts as.
create function test_helpers.rule_at(p_code text, p_date date) returns public.tax_rule_versions
language sql stable security definer set search_path = pg_catalog, public as
$f$ select (app_private.tax_rule_at(p_code, p_date)).* $f$;
create function test_helpers.profile_at(p_entity uuid, p_date date) returns public.tax_entity_profiles
language sql stable security definer set search_path = pg_catalog, public as
$f$ select (app_private.tax_profile_at(p_entity, p_date)).* $f$;
create function test_helpers.contact_at(p_entity uuid, p_contact uuid, p_date date) returns public.tax_contact_facts
language sql stable security definer set search_path = pg_catalog, public as
$f$ select (app_private.tax_contact_facts_at(p_entity, p_contact, p_date)).* $f$;
create function test_helpers.engine_from(p_entity uuid) returns date
language sql stable security definer set search_path = pg_catalog, public as
$f$ select app_private.tax_engine_from(p_entity) $f$;
grant execute on function test_helpers.rule_at(text, date), test_helpers.profile_at(uuid, date),
  test_helpers.contact_at(uuid, uuid, date), test_helpers.engine_from(uuid) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p7_pt', 'P7 PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name)
  values ('personal', 'p7_pe', 'P7 PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);

  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000002', 'admin');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000003', 'taxer');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000005', 'staff');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000006', 'nobody');
  perform test_helpers.mk_user('d0000000-0000-0000-0000-000000000007', 'pe_admin');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'd0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000002', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000003', 'tax');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_pt, 'd0000000-0000-0000-0000-000000000005', 'finance_staff');
  perform test_helpers.mk_member(v_pe, 'd0000000-0000-0000-0000-000000000007', 'finance_admin');
end
$$;

-- ================================================================ 1. the rule master
do $$
declare
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_taxer uuid := 'd0000000-0000-0000-0000-000000000003';
  v_id uuid;
  v_id2 uuid;
  v_id3 uuid;
  r record;
  v_params jsonb := '{"rate":"0.10","dpp_numerator":10,"dpp_denominator":10,"rounding":{"mode":"half_up","scale":0}}';
begin
  -- The verified baseline is present, published and readable by tax viewers only.
  perform test_helpers.assert((select count(*) from public.tax_rule_versions where status = 'published') = 7,
    '1.0 seven baseline rules are published');
  perform test_helpers.assert((select params ->> 'rate' from test_helpers.rule_at('PPN_STANDARD', date '2026-09-01')) = '0.12',
    '1.1 PPN 12% applies in September 2026');
  perform test_helpers.assert((select (params ->> 'dpp_numerator') || '/' || (params ->> 'dpp_denominator')
                               from test_helpers.rule_at('PPN_STANDARD', date '2026-09-01')) = '11/12',
    '1.2 DPP Nilai Lain 11/12');
  perform test_helpers.assert(test_helpers.rule_at('PPN_STANDARD', date '2024-12-31') is null
                              or (test_helpers.rule_at('PPN_STANDARD', date '2024-12-31')).id is null,
    '1.3 no rule before the verified effective date (review, not a guess)');
  perform test_helpers.assert((select rule_version from test_helpers.rule_at('PPN_STANDARD', date '2025-01-01')) = 1,
    '1.4 the rule applies on its effective date');

  -- Authority: staff and viewers cannot draft or publish; the tax specialist may draft but publishing needs step-up.
  perform test_helpers.login('d0000000-0000-0000-0000-000000000005');
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-00', null, 'ppn', 'PPN_T', date '2027-01-01', false,
    '{}'::jsonb, 'x source', 'ref', null, current_date, 'verified', null)$q$, 'FORBIDDEN', '1.5 staff cannot draft rules');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-00', null, 'ppn', 'PPN_T', date '2027-01-01', false,
    '{}'::jsonb, 'x source', 'ref', null, current_date, 'verified', null)$q$, 'FORBIDDEN', '1.6 finance admin cannot draft rules');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  -- Shape validation.
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-01', null, 'ppn', 'PPN_T', date '2027-01-01', false,
    '{"rate":"0.12"}'::jsonb, 'Test rule', 'ref', null, current_date, 'verified', null)$q$, 'INVALID', '1.7 params must be complete');
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-02', null, 'ppn', 'PPN_T', date '2027-01-01', false,
    '{"rate":"1.5","dpp_numerator":11,"dpp_denominator":12,"rounding":{"mode":"half_up","scale":0}}'::jsonb, 'Test rule', 'ref', null,
    current_date, 'verified', null)$q$, 'INVALID', '1.8 a rate above 100% is refused');
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-03', null, 'ppn', 'PPN_T', date '2027-01-01', false,
    '{"rate":"0.12","dpp_numerator":13,"dpp_denominator":12,"rounding":{"mode":"half_up","scale":0}}'::jsonb, 'Test rule', 'ref', null,
    current_date, 'verified', null)$q$, 'INVALID', '1.9 a DPP factor above 1 is refused');
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-04', null, 'ppn', 'PPN_T', date '2027-01-01', false,
    '{"rate":"0.12","dpp_numerator":11,"dpp_denominator":12,"rounding":{"mode":"sideways","scale":0}}'::jsonb, 'Test rule', 'ref', null,
    current_date, 'verified', null)$q$, 'INVALID', '1.10 an unknown rounding mode is refused');
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-05', null, 'pph23', 'PPH23_T', date '2027-01-01', false,
    '{"rate":"0.02","non_npwp_multiplier":"2","objects":["wht_none"],"rounding":{"mode":"half_up","scale":0}}'::jsonb, 'Test rule', 'ref',
    null, current_date, 'verified', null)$q$, 'INVALID', '1.11 "not a withholding object" cannot be a taxed object');
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-06', null, 'ppn', 'PPN_T', date '2027-01-01', false,
    '{"rate":"0.12","dpp_numerator":11,"dpp_denominator":12,"rounding":{"mode":"half_up","scale":0}}'::jsonb, 'Test rule', 'ref',
    'http://insecure.example', current_date, 'verified', null)$q$, 'INVALID', '1.12 a source link must be https');
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-07', null, 'ppn', 'PPN_T', null, false,
    '{}'::jsonb, 'Test rule', 'ref', null, current_date, 'verified', null)$q$, 'INVALID', '1.13 the effective date is mandatory');
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-08', null, 'ppn', 'PPN_T', date '2027-01-01', false,
    '{"rate":"0.12","dpp_numerator":11,"dpp_denominator":12,"rounding":{"mode":"half_up","scale":0}}'::jsonb, 'Test rule', 'ref', null,
    current_date + 30, 'verified', null)$q$, 'INVALID', '1.14 a verification date in the future is refused');

  -- A draft, its edit, a replay and the publish workflow.
  v_id := public.tax_rule_draft_save('key-p7-r-10', null, 'ppn', 'PPN_T', date '2027-01-01', false, v_params,
    'Test rule (synthetic)', 'TEST-REF-1', 'https://example.invalid/rule', current_date, 'verified', 'first');
  perform test_helpers.assert(v_id = public.tax_rule_draft_save('key-p7-r-10', null, 'ppn', 'PPN_T', date '2027-01-01', false, v_params,
    'Test rule (synthetic)', 'TEST-REF-1', 'https://example.invalid/rule', current_date, 'verified', 'first'),
    '1.15 a retry with the same key returns the same draft');
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-10', null, 'ppn', 'PPN_T', date '2027-01-01', false, '{}'::jsonb,
    'Other', 'TEST-REF-1', null, current_date, 'verified', null)$q$, 'INVALID', '1.16 the same key for another request is refused');
  perform test_helpers.assert((select rule_version from public.tax_rule_versions where id = v_id) = 1, '1.17 first version is 1');
  perform test_helpers.assert(test_helpers.rule_at('PPN_T', date '2027-06-01') is null
                              or (test_helpers.rule_at('PPN_T', date '2027-06-01')).id is null,
    '1.18 a draft is not in force');
  perform test_helpers.assert(public.tax_rule_draft_save('key-p7-r-11', v_id, 'ppn', 'PPN_T', date '2027-01-01', false,
    v_params, 'Test rule (synthetic, edited)', 'TEST-REF-1', null, current_date, 'verified', 'edited') = v_id,
    '1.19 a draft can be edited');
  perform test_helpers.assert((select source_title from public.tax_rule_versions where id = v_id) = 'Test rule (synthetic, edited)',
    '1.20 the edit is stored');
  -- Publishing needs a recent step-up (the JWT here is 1 minute old; an old one is refused).
  perform test_helpers.logout();
  perform test_helpers.login(v_owner, 'aal2', interval '2 hours');
  perform test_helpers.expect_msg(format($q$select public.tax_rule_publish(%L, 'key-p7-p-01')$q$, v_id), 'STEP_UP_REQUIRED',
    '1.21 publishing needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.tax_rule_publish(v_id, 'key-p7-p-02') = v_id, '1.22 the OWNER publishes');
  perform test_helpers.assert(public.tax_rule_publish(v_id, 'key-p7-p-02') = v_id, '1.23 publishing replays');
  perform test_helpers.expect_msg(format($q$select public.tax_rule_publish(%L, 'key-p7-p-03')$q$, v_id), 'CONFLICT',
    '1.24 a published rule cannot be published again');
  perform test_helpers.expect_msg(format($q$select public.tax_rule_draft_save('key-p7-r-12', %L, 'ppn', 'PPN_T', date '2027-01-01', false, %L::jsonb,
    'Sneaky edit', 'TEST-REF-1', null, current_date, 'verified', null)$q$, v_id, v_params::text), 'CONFLICT',
    '1.25 a published rule cannot be edited through the workflow');
  perform test_helpers.logout();
  -- ... nor by any direct write (superuser included): the row guard holds.
  perform test_helpers.expect_error(format($q$update public.tax_rule_versions set params = '{}'::jsonb where id = %L$q$, v_id),
    '23000', '1.26 published content is immutable at the row level');
  perform test_helpers.expect_error(format($q$update public.tax_rule_versions set effective_from = date '2030-01-01' where id = %L$q$, v_id),
    '23000', '1.27 the effective date of a published rule cannot move');
  perform test_helpers.expect_error(format($q$delete from public.tax_rule_versions where id = %L$q$, v_id), null,
    '1.28 a rule version cannot be deleted');
  perform test_helpers.assert((test_helpers.rule_at('PPN_T', date '2027-01-01')).rule_version = 1, '1.29 in force from its date');
  perform test_helpers.assert(test_helpers.rule_at('PPN_T', date '2026-12-31') is null
                              or (test_helpers.rule_at('PPN_T', date '2026-12-31')).id is null,
    '1.30 not in force the day before');

  -- A second version supersedes the first from its date; the first keeps applying before it (regression by date).
  perform test_helpers.login(v_owner);
  v_id2 := public.tax_rule_draft_save('key-p7-r-20', null, 'ppn', 'PPN_T', date '2028-01-01', false,
    '{"rate":"0.20","dpp_numerator":10,"dpp_denominator":10,"rounding":{"mode":"half_up","scale":0}}'::jsonb,
    'Test rule v2', 'TEST-REF-2', null, current_date, 'verified', null);
  perform test_helpers.assert((select rule_version from public.tax_rule_versions where id = v_id2) = 2, '1.31 next version number');
  perform test_helpers.assert(public.tax_rule_publish(v_id2, 'key-p7-p-04') = v_id2, '1.32 publish the second version');
  perform test_helpers.assert((test_helpers.rule_at('PPN_T', date '2027-12-31')).rule_version = 1, '1.33 before the change: version 1');
  perform test_helpers.assert((test_helpers.rule_at('PPN_T', date '2028-01-01')).rule_version = 2, '1.34 on the change: version 2');
  perform test_helpers.assert((test_helpers.rule_at('PPN_T', date '2027-12-31')).params ->> 'rate' = '0.10',
    '1.35 the old result is reproducible after a new version exists');
  -- Two published versions on the same date are impossible.
  v_id3 := public.tax_rule_draft_save('key-p7-r-21', null, 'ppn', 'PPN_T', date '2028-01-01', false, v_params,
    'Test rule dup date', 'TEST-REF-3', null, current_date, 'verified', null);
  perform test_helpers.expect_msg(format($q$select public.tax_rule_publish(%L, 'key-p7-p-05')$q$, v_id3), 'CONFLICT',
    '1.36 one published version per effective date');
  perform test_helpers.expect_msg(format($q$select public.tax_rule_discard(%L, 'no')$q$, v_id3), 'INVALID', '1.37 a discard needs a reason');
  perform public.tax_rule_discard(v_id3, 'duplicate date, replaced by a later draft');
  perform test_helpers.assert((select status from public.tax_rule_versions where id = v_id3) = 'discarded', '1.38 discarded');
  perform test_helpers.expect_msg(format($q$select public.tax_rule_publish(%L, 'key-p7-p-06')$q$, v_id3), 'CONFLICT',
    '1.39 a discarded draft cannot be published');
  -- A rule that is not verified is never published.
  v_id3 := public.tax_rule_draft_save('key-p7-r-22', null, 'ppn', 'PPN_T', date '2029-01-01', false, v_params,
    'Unverified rule', 'TEST-REF-4', null, current_date, 'needs_review', null);
  perform test_helpers.expect_msg(format($q$select public.tax_rule_publish(%L, 'key-p7-p-07')$q$, v_id3), 'CONFLICT',
    '1.40 unverified statutory values are not published');
  -- A repeal version ends the rule.
  v_id3 := public.tax_rule_draft_save('key-p7-r-23', null, 'ppn', 'PPN_T', date '2030-01-01', true, '{}'::jsonb,
    'Repealed (synthetic)', 'TEST-REF-5', null, current_date, 'verified', null);
  perform public.tax_rule_publish(v_id3, 'key-p7-p-08');
  perform test_helpers.assert(test_helpers.rule_at('PPN_T', date '2030-06-01') is null
                              or (test_helpers.rule_at('PPN_T', date '2030-06-01')).id is null,
    '1.41 after a repeal no rule applies');
  perform test_helpers.assert((test_helpers.rule_at('PPN_T', date '2029-12-31')).rule_version = 2,
    '1.42 before the repeal the last version still applies');
  -- The code belongs to one family.
  perform test_helpers.expect_msg($q$select public.tax_rule_draft_save('key-p7-r-24', null, 'pph23', 'PPN_T', date '2031-01-01', false,
    '{"rate":"0.02","non_npwp_multiplier":"2","objects":["wht_royalty"],"rounding":{"mode":"half_up","scale":0}}'::jsonb, 'Wrong family',
    'ref', null, current_date, 'verified', null)$q$, 'INVALID', '1.43 a code cannot change family');
  perform test_helpers.logout();

  -- Visibility: tax viewers read rules; nobody else does.
  perform test_helpers.login(v_taxer);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.tax_rule_versions') >= 8, '1.44 the tax role reads rules');
  perform test_helpers.assert((select count(*) from public.tax_rule_in_force('PPN_STANDARD', date '2026-09-01')) = 1,
    '1.45 tax_rule_in_force answers');
  perform test_helpers.logout();
  perform test_helpers.login('d0000000-0000-0000-0000-000000000005');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.tax_rule_versions') = 0, '1.46 staff read no rules');
  perform test_helpers.expect_msg($q$select * from public.tax_rule_in_force('PPN_STANDARD', date '2026-09-01')$q$, 'FORBIDDEN',
    '1.47 staff cannot resolve rules');
  perform test_helpers.logout();
  perform test_helpers.login('d0000000-0000-0000-0000-000000000006');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.tax_rule_versions') = 0, '1.48 a stranger reads no rules');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.tax_treatment_catalog') > 0, '1.49 the vocabulary is reference data');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. taxpayer facts
do $$
declare
  pt uuid := test_helpers.entity('p7_pt');
  pe uuid := test_helpers.entity('p7_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd0000000-0000-0000-0000-000000000002';
  v_taxer uuid := 'd0000000-0000-0000-0000-000000000003';
  v_id uuid;
  v_id2 uuid;
  v_vendor uuid;
  p public.tax_entity_profiles%rowtype;
begin
  -- No profile yet: nothing is assumed.
  perform test_helpers.assert(test_helpers.profile_at(pt, current_date) is null
                              or (test_helpers.profile_at(pt, current_date)).id is null, '2.1 no profile means unknown');

  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format($q$select public.tax_record_entity_profile(%L, 'key-p7-f-00', current_date, 'perseroan_perorangan', 'resident',
    'final_umkm', 'none', 'none', 'non_pkp', 'yes', null, null)$q$, pt), 'FORBIDDEN', '2.2 finance admin cannot record tax facts');
  perform test_helpers.logout();

  perform test_helpers.login(v_taxer);
  v_id := public.tax_record_entity_profile(pt, 'key-p7-f-01', date '2026-04-22', 'perseroan_perorangan', 'resident',
    'final_umkm', 'none', 'none', 'non_pkp', 'yes', '01.234.567.8-901.000', 'legal documents checked (synthetic)');
  perform test_helpers.assert(v_id = public.tax_record_entity_profile(pt, 'key-p7-f-01', date '2026-04-22', 'perseroan_perorangan', 'resident',
    'final_umkm', 'none', 'none', 'non_pkp', 'yes', '01.234.567.8-901.000', 'legal documents checked (synthetic)'), '2.3 replay');
  perform test_helpers.expect_msg(format($q$select public.tax_record_entity_profile(%L, 'key-p7-f-02', current_date, 'wizard', 'resident',
    'final_umkm', 'none', 'none', 'non_pkp', 'yes', null, null)$q$, pt), 'INVALID', '2.4 an unknown kind is refused');
  perform test_helpers.expect_msg(format($q$select public.tax_record_entity_profile(%L, 'key-p7-f-03', null, 'individual', 'resident',
    'final_umkm', 'none', 'none', 'non_pkp', 'yes', null, null)$q$, pt), 'INVALID', '2.5 the effective date is required');
  -- The identifier is sensitive: not in the table view, in the RPC for the tax role, never in the audit trail.
  perform test_helpers.expect_error(format($q$select tax_identifier from public.tax_entity_profiles where id = %L$q$, v_id), '42501',
    '2.6 the identifier column is not readable through the table');
  perform test_helpers.assert(public.tax_profile_identifier(pt) = '01.234.567.8-901.000', '2.7 the tax role reads the identifier via the RPC');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.tax_entity_profiles') = 1, '2.8 the profile row is readable');
  perform test_helpers.logout();
  perform test_helpers.assert(not exists (select 1 from public.audit_events a where a.target_table = 'tax_entity_profiles'
                                          and (a.after_state::text like '%01.234.567.8%')),
    '2.9 the tax identifier never reaches the audit trail');
  perform test_helpers.assert(exists (select 1 from public.audit_events a where a.target_table = 'tax_entity_profiles' and a.target_id = v_id),
    '2.10 the profile change is audited');

  perform test_helpers.login('d0000000-0000-0000-0000-000000000004');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.tax_entity_profiles') = 1, '2.11 an auditor sees the profile without the identifier');
  perform test_helpers.expect_msg(format($q$select public.tax_profile_identifier(%L)$q$, pt), 'FORBIDDEN', '2.12 an auditor cannot read the identifier');
  perform test_helpers.logout();
  perform test_helpers.login('d0000000-0000-0000-0000-000000000005');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.tax_entity_profiles') = 0, '2.13 staff see no tax profile');
  perform test_helpers.logout();
  perform test_helpers.login('d0000000-0000-0000-0000-000000000007');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.tax_entity_profiles') = 0, '2.14 another Entity sees nothing');
  perform test_helpers.logout();

  -- Effective dating: a change is a new row; the old one applies before it; a correction supersedes.
  perform test_helpers.login(v_owner);
  v_id2 := public.tax_record_entity_profile(pt, 'key-p7-f-04', date '2026-09-01', 'perseroan_perorangan', 'resident',
    'general', 'none', 'none', 'pkp', 'yes', null, 'PKP registered (synthetic)');
  perform test_helpers.assert((test_helpers.profile_at(pt, date '2026-08-31')).vat_status = 'non_pkp', '2.15 before the change: non PKP');
  perform test_helpers.assert((test_helpers.profile_at(pt, date '2026-09-01')).vat_status = 'pkp', '2.16 from the change: PKP');
  perform test_helpers.assert((test_helpers.profile_at(pt, date '2026-09-01')).income_regime = 'general', '2.17 regime switches with its own date');
  perform test_helpers.assert((test_helpers.profile_at(pt, date '2026-04-21')) is null
                              or (test_helpers.profile_at(pt, date '2026-04-21')).id is null, '2.18 before the first fact: unknown');
  -- Same date again: the earlier row is superseded, not overwritten.
  perform public.tax_record_entity_profile(pt, 'key-p7-f-05', date '2026-09-01', 'perseroan_perorangan', 'resident',
    'general', 'none', 'none', 'non_pkp', 'yes', null, 'correction: not PKP yet (synthetic)');
  perform test_helpers.assert((test_helpers.profile_at(pt, date '2026-09-01')).vat_status = 'non_pkp', '2.19 the correction applies');
  perform test_helpers.assert((select superseded_at is not null from public.tax_entity_profiles where id = v_id2), '2.20 the old fact is kept, superseded');
  perform test_helpers.assert((select count(*) from public.tax_entity_profiles where entity_id = pt) = 3, '2.21 the history stays');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format($q$update public.tax_entity_profiles set vat_status = 'pkp' where id = %L$q$, v_id), '23000',
    '2.22 a recorded fact is never edited');
  perform test_helpers.expect_error(format($q$delete from public.tax_entity_profiles where id = %L$q$, v_id), null, '2.23 nor deleted');

  -- Counterparty facts.
  perform test_helpers.login(v_owner);
  v_vendor := public.create_contact(pt, 'key-p7-ct-01', 'vendor', 'P7 Vendor', 'v@vendor.example.invalid', null, null, 'PT P7 Vendor', null, null, 'ID');
  perform test_helpers.p7put('vendor', v_vendor);
  perform test_helpers.assert(test_helpers.contact_at(pt, v_vendor, current_date) is null
                              or (test_helpers.contact_at(pt, v_vendor, current_date)).id is null,
    '2.24 no counterparty facts means unknown');
  v_id := public.tax_record_contact_facts(v_vendor, 'key-p7-cf-01', date '2026-01-01', 'company', 'resident', 'has_npwp', 'non_pkp', 'none', 'ok');
  perform test_helpers.assert((test_helpers.contact_at(pt, v_vendor, date '2026-06-01')).tax_id_status = 'has_npwp', '2.25 counterparty facts resolve');
  perform public.tax_record_contact_facts(v_vendor, 'key-p7-cf-02', date '2026-07-01', 'company', 'resident', 'no_npwp', 'non_pkp', 'none', 'lapsed');
  perform test_helpers.assert((test_helpers.contact_at(pt, v_vendor, date '2026-06-30')).tax_id_status = 'has_npwp', '2.26 the earlier fact applies before the change');
  perform test_helpers.assert((test_helpers.contact_at(pt, v_vendor, date '2026-07-01')).tax_id_status = 'no_npwp', '2.27 the later fact applies after it');
  perform test_helpers.expect_msg(format($q$select public.tax_record_contact_facts(%L, 'key-p7-cf-03', current_date, 'alien', 'resident', 'has_npwp', 'non_pkp', 'none', null)$q$,
    v_vendor), 'INVALID', '2.28 an unknown party kind is refused');
  perform test_helpers.logout();
  perform test_helpers.login('d0000000-0000-0000-0000-000000000005');
  perform test_helpers.expect_msg(format($q$select public.tax_record_contact_facts(%L, 'key-p7-cf-04', current_date, 'company', 'resident', 'has_npwp', 'non_pkp', 'none', null)$q$,
    v_vendor), 'FORBIDDEN', '2.29 staff cannot record counterparty tax facts');
  perform test_helpers.logout();

  -- Aggregation facts.
  perform test_helpers.login(v_taxer);
  v_id := public.tax_record_aggregation_fact(pt, 'key-p7-ag-01', 2026, '150000000', 'spouse business turnover (synthetic)', 'statement on file');
  perform test_helpers.assert((select amount from public.tax_aggregation_facts where id = v_id) = 150000000, '2.30 aggregation amount stored');
  perform public.tax_record_aggregation_fact(pt, 'key-p7-ag-02', 2026, '175000000', 'spouse business turnover (synthetic, corrected)', null);
  perform test_helpers.assert((select count(*) from public.tax_aggregation_facts where entity_id = pt and tax_year = 2026 and superseded_at is null) = 1,
    '2.31 one current fact per year; the earlier stays as history');
  perform test_helpers.expect_msg(format($q$select public.tax_record_aggregation_fact(%L, 'key-p7-ag-03', 2026, '-1', 'negative amount', null)$q$, pt), 'INVALID',
    '2.32 a negative amount is refused');
  perform test_helpers.expect_msg(format($q$select public.tax_record_aggregation_fact(%L, 'key-p7-ag-04', 1900, '1', 'ancient year', null)$q$, pt), 'INVALID',
    '2.33 an absurd tax year is refused');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. the engine switch
do $$
declare
  pt uuid := test_helpers.entity('p7_pt');
  pe uuid := test_helpers.entity('p7_pe');
  v_owner uuid := 'd0000000-0000-0000-0000-000000000001';
  v_taxer uuid := 'd0000000-0000-0000-0000-000000000003';
  v_from date := date '2026-09-01';
begin
  perform test_helpers.assert(test_helpers.engine_from(pt) is null, '3.1 the engine is off by default');
  -- Only the OWNER, with a recent step-up, from a complete profile.
  perform test_helpers.login(v_taxer);
  perform test_helpers.expect_msg(format($q$select public.tax_engine_activate(%L, 'key-p7-a-00', %L)$q$, pt, v_from), 'FORBIDDEN',
    '3.2 the tax role cannot activate the engine');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner, 'aal2', interval '2 hours');
  perform test_helpers.expect_msg(format($q$select public.tax_engine_activate(%L, 'key-p7-a-01', %L)$q$, pt, v_from), 'STEP_UP_REQUIRED',
    '3.3 activation needs a recent step-up');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format($q$select public.tax_engine_activate(%L, 'key-p7-a-02', %L)$q$, pe, v_from), 'INVALID',
    '3.4 no profile, no activation');
  -- An incomplete profile is refused with the missing facts named.
  perform public.tax_record_entity_profile(pe, 'key-p7-f-10', date '2026-01-01', 'individual', 'resident', 'unknown', 'unknown', 'unknown', 'non_pkp', 'unknown', null, null);
  perform test_helpers.expect_msg(format($q$select public.tax_engine_activate(%L, 'key-p7-a-03', %L)$q$, pe, v_from), 'INVALID',
    '3.5 an incomplete profile is refused');
  perform test_helpers.assert(test_helpers.sqlerrm_of(format($q$select public.tax_engine_activate(%L, 'key-p7-a-04', %L)$q$, pe, v_from)) like '%income-tax regime%'
    and test_helpers.sqlerrm_of(format($q$select public.tax_engine_activate(%L, 'key-p7-a-05', %L)$q$, pe, v_from)) like '%withholding role%',
    '3.6 the message names what is missing');
  perform test_helpers.assert(public.tax_engine_activate(pt, 'key-p7-a-06', v_from) = v_from, '3.7 the OWNER activates the engine');
  perform test_helpers.assert(test_helpers.engine_from(pt) = v_from, '3.8 the start date is stored');
  perform test_helpers.assert(public.tax_engine_activate(pt, 'key-p7-a-06', v_from) = v_from, '3.9 activation replays');
  perform test_helpers.expect_msg(format($q$select public.tax_engine_activate(%L, 'key-p7-a-07', date '2026-10-01')$q$, pt), 'CONFLICT',
    '3.10 the engine is activated once');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format($q$update public.tax_settings set engine_active_from = date '2026-01-01' where entity_id = %L$q$, pt), '23000',
    '3.11 the start date never changes');
  perform test_helpers.login(v_taxer);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.tax_settings') = 1, '3.12 the tax role reads the switch');
  perform test_helpers.logout();
end
$$;

rollback;
