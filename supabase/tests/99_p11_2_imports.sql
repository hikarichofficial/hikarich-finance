-- P11 gate, part 2 (Step 15 §15, Step 08 §17/§19, Step 01 #43): the import staging engine --
-- staging, validation (business rules, within- and cross-batch duplicate detection), commit with
-- row-level errors and batch lineage, and rollback only where safely and completely reversible.
-- All data is synthetic. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p11i (k text primary key, v uuid not null);
grant all on test_helpers.p11i to public;
create function test_helpers.iput(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p11i values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.ig(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p11i where k = p_k $f$;
grant execute on function test_helpers.iput(text, uuid), test_helpers.ig(text) to public;

-- ================================================================ 1. fixtures
do $$
declare
  pt uuid;
  v_owner uuid := 'e1200000-0000-0000-0000-000000000001';
  v_admin uuid := 'e1200000-0000-0000-0000-000000000002';
  v_staff uuid := 'e1200000-0000-0000-0000-000000000003';
  v_viewer uuid := 'e1200000-0000-0000-0000-000000000005';
  v_ar_contact uuid;
  v_ap_contact uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p11i_pt', 'P11 Imports PT (synthetic)')
  returning id into pt;
  perform app_private.provision_default_coa(pt);
  perform test_helpers.iput('pt', pt);

  perform test_helpers.mk_user(v_owner, 'p11i-owner');
  perform test_helpers.mk_user(v_admin, 'p11i-admin');
  perform test_helpers.mk_user(v_staff, 'p11i-staff');
  perform test_helpers.mk_user(v_viewer, 'p11i-viewer');
  perform test_helpers.iput('owner', v_owner);
  perform test_helpers.iput('admin', v_admin);
  perform test_helpers.iput('staff', v_staff);
  perform test_helpers.iput('viewer', v_viewer);

  perform test_helpers.mk_member(pt, v_owner, 'owner');
  perform test_helpers.mk_member(pt, v_admin, 'finance_admin');
  perform test_helpers.mk_member(pt, v_staff, 'finance_staff');
  perform test_helpers.mk_member(pt, v_viewer, 'viewer_auditor');

  -- Pre-existing contacts for the legacy AR/AP domains to resolve against (contacts domain is tested
  -- separately below; these two are created directly so the AR/AP tests do not depend on it).
  perform test_helpers.login(v_admin);
  v_ar_contact := public.create_contact(pt, 'key-p11i-ar-01', 'customer', 'Legacy AR Customer');
  v_ap_contact := public.create_contact(pt, 'key-p11i-ap-01', 'vendor', 'Legacy AP Vendor');
  perform test_helpers.iput('ar_contact', v_ar_contact);
  perform test_helpers.iput('ap_contact', v_ap_contact);
end
$$;

-- ================================================================ 2. permission boundaries
do $$
declare
  pt uuid := test_helpers.ig('pt');
begin
  perform test_helpers.login(test_helpers.ig('staff'));
  perform test_helpers.expect_msg(
    format($q$select public.stage_import_batch(%L, 'contacts', '{}'::jsonb, '[{"kind":"customer","display_name":"X"}]'::jsonb)$q$, pt),
    'FORBIDDEN', '2.1 finance_staff lacks system.import and cannot stage a batch');

  perform test_helpers.login(test_helpers.ig('admin'));
  perform test_helpers.assert(app_authz.has_permission(pt, 'system.import'), '2.2 finance_admin holds system.import (decision 146)');
  perform test_helpers.assert(app_authz.has_permission(pt, 'system.rollback_import'), '2.3 finance_admin holds system.rollback_import');
end
$$;

-- ================================================================ 3. contacts domain: staging -> validate -> commit -> rollback
do $$
declare
  pt uuid := test_helpers.ig('pt');
  v_batch uuid;
  v_summary record;
  v_commit record;
  v_rollback record;
  v_row1 uuid;
  v_row2 uuid;
  v_row3 uuid;
  v_contact_id uuid;
  v_invoice uuid;
begin
  perform test_helpers.login(test_helpers.ig('admin'));

  -- row 1: valid new contact. row 2: exact duplicate of an existing contact (email match against the
  -- AR contact fixture is not set up, so instead duplicate row 3 against row 1 within the same batch).
  v_batch := public.stage_import_batch(pt, 'contacts', jsonb_build_object('display_name', 'Name'),
    jsonb_build_array(
      jsonb_build_object('kind', 'customer', 'display_name', 'Imported Customer One', 'email', 'one@example.com'),
      jsonb_build_object('kind', 'bogus_kind', 'display_name', 'Bad Kind Row'),
      jsonb_build_object('kind', 'customer', 'display_name', 'Imported Customer One', 'email', 'one@example.com')
    ), 'contacts.csv');
  perform test_helpers.assert(v_batch is not null, '3.1 staging a contacts batch returns a batch id');
  perform test_helpers.assert(
    (select status from public.import_batches where id = v_batch) = 'staging', '3.2 a fresh batch starts in staging');
  perform test_helpers.assert(
    (select count(*) from public.import_rows where batch_id = v_batch) = 3, '3.3 three rows were staged');

  -- re-staging while staging works freely; re-validating recomputes from scratch.
  select * into v_summary from public.validate_import_batch(v_batch);
  perform test_helpers.assert(v_summary.total_rows = 3 and v_summary.valid_rows = 1
    and v_summary.invalid_rows = 1 and v_summary.duplicate_rows = 1,
    '3.4 validation splits the batch into 1 valid, 1 invalid (bad kind), 1 duplicate (repeats row 1)');
  perform test_helpers.assert(
    (select status from public.import_batches where id = v_batch) = 'validated', '3.5 the batch moves to validated');

  -- once validated, rows are frozen and cannot be re-validated.
  perform test_helpers.expect_msg(format($q$select public.validate_import_batch(%L)$q$, v_batch),
    'INVALID', '3.6 a validated batch cannot be re-validated');

  select row_id into v_row1 from public.get_import_batch_rows(v_batch, 'valid') limit 1;
  select row_id into v_row2 from public.get_import_batch_rows(v_batch, 'invalid') limit 1;
  select row_id into v_row3 from public.get_import_batch_rows(v_batch, 'duplicate') limit 1;
  perform test_helpers.assert(v_row1 is not null and v_row2 is not null and v_row3 is not null,
    '3.7 get_import_batch_rows filters by status');

  -- commit: only the valid row becomes a contact.
  select * into v_commit from public.commit_import_batch(v_batch);
  perform test_helpers.assert(v_commit.committed_rows = 1 and v_commit.skipped_rows = 0,
    '3.8 commit creates exactly the one valid row (invalid/duplicate rows are never committed)');
  perform test_helpers.assert(
    (select status from public.import_batches where id = v_batch) = 'committed', '3.9 the batch moves to committed');
  select target_record_id into v_contact_id from public.import_rows where id = v_row1;
  perform test_helpers.assert(
    (select display_name from public.contacts where id = v_contact_id) = 'Imported Customer One',
    '3.10 the committed row''s target_record_id is the newly created contact');
  perform test_helpers.assert(
    (select status from public.import_rows where id = v_row1) = 'committed', '3.11 the committed row is marked committed');
  perform test_helpers.assert(
    (select status from public.import_rows where id = v_row2) = 'invalid'
    and (select status from public.import_rows where id = v_row3) = 'duplicate',
    '3.12 the invalid and duplicate rows are left as-is, never touched by commit');

  -- a validated batch cannot be committed twice.
  perform test_helpers.expect_msg(format($q$select public.commit_import_batch(%L)$q$, v_batch),
    'INVALID', '3.13 a committed batch cannot be committed again');

  -- rollback: the contact has no references yet, so it is archived and the row reverses cleanly.
  select * into v_rollback from public.rollback_import_batch(v_batch, 'test rollback: undoing the import');
  perform test_helpers.assert(v_rollback.rolled_back_rows = 1 and v_rollback.retained_rows = 0,
    '3.14 an unreferenced imported contact rolls back cleanly');
  perform test_helpers.assert((select status from public.contacts where id = v_contact_id) = 'inactive',
    '3.15 the contact is archived on rollback');
  perform test_helpers.assert((select status from public.import_rows where id = v_row1) = 'rolled_back',
    '3.16 the row is marked rolled_back');
  perform test_helpers.assert((select status from public.import_batches where id = v_batch) = 'rolled_back',
    '3.17 the batch is marked rolled_back');

  -- a second contacts batch whose committed contact goes on to be referenced elsewhere cannot be archived.
  v_batch := public.stage_import_batch(pt, 'contacts', '{}'::jsonb,
    jsonb_build_array(jsonb_build_object('kind', 'customer', 'display_name', 'Referenced Later Co')));
  perform public.validate_import_batch(v_batch);
  perform public.commit_import_batch(v_batch);
  select target_record_id into v_contact_id from public.import_rows where batch_id = v_batch;
  v_invoice := public.create_invoice_draft(pt, 'key-p11i-inv-01', v_contact_id, current_date, current_date + 30,
    jsonb_build_array(jsonb_build_object('description', 'Consulting', 'quantity', 1, 'unit_price', 100000)), 'IDR');
  select * into v_rollback from public.rollback_import_batch(v_batch, 'test rollback: contact now referenced');
  perform test_helpers.assert(v_rollback.rolled_back_rows = 0 and v_rollback.retained_rows = 1,
    '3.18 a contact referenced by an invoice is retained, not archived, on rollback');
  perform test_helpers.assert((select status from public.contacts where id = v_contact_id) = 'active',
    '3.19 the referenced contact stays active');
  perform test_helpers.assert((select status from public.import_batches where id = v_batch) = 'rolled_back',
    '3.20 the batch still moves to rolled_back even though one row was retained (reported, not silently skipped)');
end
$$;

-- ================================================================ 4. legacy AR/AP domains
do $$
declare
  pt uuid := test_helpers.ig('pt');
  v_ar_contact uuid := test_helpers.ig('ar_contact');
  v_ap_contact uuid := test_helpers.ig('ap_contact');
  v_batch uuid;
  v_summary record;
  v_commit record;
  v_item_id uuid;
  v_row_valid uuid;
begin
  perform test_helpers.login(test_helpers.ig('admin'));

  -- legacy_open_receivables: one valid row (by contact_id), one with an unknown contact_id, one missing amount.
  v_batch := public.stage_import_batch(pt, 'legacy_open_receivables', '{}'::jsonb,
    jsonb_build_array(
      jsonb_build_object('contact_id', v_ar_contact, 'amount', 1500000, 'currency', 'idr',
                          'txn_date', '2026-01-15', 'due_date', '2026-02-15', 'reference', 'INV-LEGACY-001'),
      jsonb_build_object('contact_id', gen_random_uuid(), 'amount', 100, 'currency', 'IDR', 'txn_date', '2026-01-01'),
      jsonb_build_object('contact_id', v_ar_contact, 'currency', 'IDR', 'txn_date', '2026-01-01')
    ));
  select * into v_summary from public.validate_import_batch(v_batch);
  perform test_helpers.assert(v_summary.valid_rows = 1 and v_summary.invalid_rows = 2,
    '4.1 an unknown contact_id and a missing amount are both invalid; the well-formed row is valid');
  select * into v_commit from public.commit_import_batch(v_batch);
  perform test_helpers.assert(v_commit.committed_rows = 1, '4.2 only the one valid receivable row commits');
  select target_record_id into v_item_id from public.import_rows where batch_id = v_batch and status = 'committed';
  perform test_helpers.assert(
    (select kind = 'receivable' and status = 'open' and contact_id = v_ar_contact and amount = 1500000 and currency = 'IDR'
     from public.legacy_open_items where id = v_item_id),
    '4.3 the committed row lands in legacy_open_items as an open receivable, currency normalized to uppercase');

  perform test_helpers.assert(
    (select count(*) from public.list_legacy_open_items(pt, 'receivable')) >= 1,
    '4.4 list_legacy_open_items(receivable) surfaces it (gated by invoices.view)');

  -- settle it.
  perform test_helpers.assert(public.settle_legacy_open_item(v_item_id, 'settled', 'paid via bank transfer') = 'settled',
    '4.5 settle_legacy_open_item marks it settled');
  perform test_helpers.expect_msg(format($q$select public.settle_legacy_open_item(%L, 'settled')$q$, v_item_id),
    'INVALID', '4.6 an already-settled item cannot be settled again');

  -- legacy_open_payables: a valid row, then roll the whole batch back.
  v_batch := public.stage_import_batch(pt, 'legacy_open_payables', '{}'::jsonb,
    jsonb_build_array(jsonb_build_object('contact_id', v_ap_contact, 'amount', 750000, 'currency', 'IDR',
                                          'txn_date', '2026-01-20', 'reference', 'BILL-LEGACY-001')));
  perform public.validate_import_batch(v_batch);
  select * into v_commit from public.commit_import_batch(v_batch);
  perform test_helpers.assert(v_commit.committed_rows = 1, '4.7 the payable row commits');
  select target_record_id into v_item_id from public.import_rows where batch_id = v_batch and status = 'committed';
  perform test_helpers.assert((select kind from public.legacy_open_items where id = v_item_id) = 'payable',
    '4.8 it lands as a payable');
  perform public.rollback_import_batch(v_batch, 'test rollback: undoing the payable import');
  perform test_helpers.assert((select status from public.legacy_open_items where id = v_item_id) = 'rolled_back',
    '4.9 a legacy open item always reverses cleanly on rollback (nothing else can reference it)');

  -- cross-batch duplicate detection: re-importing the exact same receivable is flagged, not silently re-committed.
  v_batch := public.stage_import_batch(pt, 'legacy_open_receivables', '{}'::jsonb,
    jsonb_build_array(jsonb_build_object('contact_id', v_ar_contact, 'amount', 1500000, 'currency', 'IDR',
                                          'txn_date', '2026-01-15', 'due_date', '2026-02-15', 'reference', 'INV-LEGACY-001')));
  select * into v_summary from public.validate_import_batch(v_batch);
  perform test_helpers.assert(v_summary.duplicate_rows = 1,
    '4.10 re-importing an already-committed receivable is flagged as a duplicate, not silently re-committed');
end
$$;

-- ================================================================ 5. RLS / grants defense-in-depth
do $$
begin
  perform test_helpers.as_anon();
  perform test_helpers.expect_error('select * from public.import_batches', '42501',
    '5.1 anon cannot read import_batches directly');
  perform test_helpers.expect_error('select * from public.import_rows', '42501',
    '5.2 anon cannot read import_rows directly');
  perform test_helpers.expect_error('select * from public.legacy_open_items', '42501',
    '5.3 anon cannot read legacy_open_items directly');
  perform test_helpers.expect_error(
    format($q$select public.stage_import_batch(%L, 'contacts', '{}'::jsonb, '[{}]'::jsonb)$q$, test_helpers.ig('pt')),
    '42501', '5.4 anon cannot call stage_import_batch (not granted execute at all)');
end
$$;

rollback;
