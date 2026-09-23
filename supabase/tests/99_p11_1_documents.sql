-- P11 gate, part 1 (Step 15 §15, Step 08 §17/§21, Step 06 §5): the data-driven document target-kind
-- catalog, versioning/storage plumbing and the Documents Center listing. Existing P6/P7 evidence
-- behavior (bill/expense/tax_filing/tax_payment) stays covered by 93_p6_purchases.sql and
-- 95_p7_determination.sql; this file exercises the newly generalized kinds and the new commands.
-- All data is synthetic. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p11d (k text primary key, v uuid not null);
grant all on test_helpers.p11d to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p11d values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p11d where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

-- ================================================================ 1. fixtures
do $$
declare
  pt uuid;
  v_owner uuid := 'e1100000-0000-0000-0000-000000000001';
  v_admin uuid := 'e1100000-0000-0000-0000-000000000002';
  v_staff uuid := 'e1100000-0000-0000-0000-000000000003';
  v_accountant uuid := 'e1100000-0000-0000-0000-000000000004';
  v_viewer uuid := 'e1100000-0000-0000-0000-000000000005';
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p11_pt', 'P11 PT (synthetic)')
  returning id into pt;
  perform app_private.provision_default_coa(pt);
  perform test_helpers.put('pt', pt);

  perform test_helpers.mk_user(v_owner, 'p11-owner');
  perform test_helpers.mk_user(v_admin, 'p11-admin');
  perform test_helpers.mk_user(v_staff, 'p11-staff');
  perform test_helpers.mk_user(v_accountant, 'p11-accountant');
  perform test_helpers.mk_user(v_viewer, 'p11-viewer');
  perform test_helpers.put('owner', v_owner);
  perform test_helpers.put('admin', v_admin);
  perform test_helpers.put('staff', v_staff);
  perform test_helpers.put('accountant', v_accountant);
  perform test_helpers.put('viewer', v_viewer);

  perform test_helpers.mk_member(pt, v_owner, 'owner');
  perform test_helpers.mk_member(pt, v_admin, 'finance_admin');
  perform test_helpers.mk_member(pt, v_staff, 'finance_staff');
  perform test_helpers.mk_member(pt, v_accountant, 'accountant');
  perform test_helpers.mk_member(pt, v_viewer, 'viewer_auditor');
end
$$;

-- ================================================================ 2. generic linking against new kinds
do $$
declare
  pt uuid := test_helpers.g('pt');
  v_admin uuid := test_helpers.g('admin');
  v_staff uuid := test_helpers.g('staff');
  v_viewer uuid := test_helpers.g('viewer');
  v_contact uuid;
  v_doc uuid;
  v_doc2 uuid;
  v_link uuid;
  v_link2 uuid;
  v_today constant date := app_private.entity_today(pt); -- read while still superuser, before any login()
  v_je_draft uuid;
  v_je_posted uuid;
  v_cash uuid;
  v_capital uuid;
begin
  -- journal fixtures are built with test_helpers.draft_journal/simple_journal, which perform direct
  -- INSERTs under the CALLING role (they are not security definer); create them now, while this
  -- session is still the superuser test-runner, before any login() switches to 'authenticated'.
  -- 'system'-typed (not 'manual'): these fixtures only need valid draft/posted journals to attach
  -- evidence to, and CASH/OWNER_CAPITAL are protected control accounts that would otherwise need a
  -- control_override_reason for a manual entry (Step 04 §11) — orthogonal to what this file tests.
  v_je_draft := test_helpers.draft_journal(pt, v_today, 'system');
  v_cash := test_helpers.acct(pt, 'CASH');
  v_capital := test_helpers.acct(pt, 'OWNER_CAPITAL');
  v_je_posted := test_helpers.simple_journal(pt, v_today, v_cash, v_capital, 1000000, 'system', false);
  perform test_helpers.post(v_je_posted);
  perform test_helpers.put('je_draft', v_je_draft);
  perform test_helpers.put('je_posted', v_je_posted);

  perform test_helpers.login(v_admin);
  v_contact := public.create_contact(pt, 'key-p11-c-01', 'customer', 'P11 Test Customer');
  v_doc := public.register_document(pt, 'key-p11-doc-01', 'contract.pdf', 'application/pdf', 1000, repeat('a', 64));

  -- 2.1 a viewer can neither upload nor attach
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format($q$select public.register_document(%L, 'key-p11-doc-02', 'x.pdf', 'application/pdf', 100, %L)$q$, pt, repeat('b', 64)), 'FORBIDDEN', '2.1 a viewer cannot register a document');

  -- 2.2 finance_staff has documents.upload and contacts.edit: can attach to a contact
  perform test_helpers.login(v_staff);
  v_link := public.link_document(v_doc, 'contact', v_contact, 'other');
  perform test_helpers.assert(v_link is not null, '2.2 finance_staff can attach a document to a contact');

  -- 2.3 attaching the same document to the same target twice returns the same link (idempotent)
  perform test_helpers.assert(public.link_document(v_doc, 'contact', v_contact, 'other') = v_link, '2.3 relinking returns the same link');

  -- 2.4 list_document_links returns it, permission-checked (documents.view + contacts.view)
  perform test_helpers.assert(
    (select count(*) from public.list_document_links(pt, 'contact', v_contact)) = 1,
    '2.4 list_document_links shows the active link');

  -- 2.5 unknown target type is refused
  perform test_helpers.expect_msg(format($q$select public.link_document(%L, 'not_a_kind', %L)$q$, v_doc, v_contact), 'INVALID', '2.5 an unknown target type is refused');

  -- 2.6 the generic linker refuses a dedicated-linker kind (tax evidence keeps its own function)
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format($q$select public.link_document(%L, 'tax_filing', %L)$q$, v_doc, v_contact), 'INVALID', '2.6 the generic linker does not take tax_filing records');

  -- 2.7 unlink requires a reason and the target-kind edit permission
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format($q$select public.unlink_document(%L, 'no')$q$, v_link), 'INVALID', '2.7 too short a reason is refused');
  perform test_helpers.assert(public.unlink_document(v_link, 'attached the wrong file') = 'removed', '2.8 unlink succeeds with a valid reason');
  perform test_helpers.assert(
    (select count(*) from public.list_document_links(pt, 'contact', v_contact)) = 0,
    '2.9 the removed link no longer shows');

  -- 2.10 journal_entry kind: draft takes evidence and can be unlinked; posted takes evidence but cannot be
  -- (journal fixtures were created above, before the first login(), since draft_journal/simple_journal
  -- write directly under the calling role and 'authenticated' has no write grant on journal tables)
  perform test_helpers.login(v_admin);

  -- finance_staff has documents.upload but lacks accounting.journal_create: forbidden
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format($q$select public.link_document(%L, 'journal_entry', %L)$q$, v_doc, test_helpers.g('je_draft')), 'FORBIDDEN', '2.11 finance_staff cannot attach evidence to a journal entry');

  -- accountant has accounting.journal_create but lacks documents.upload (Step 06 role matrix): also forbidden
  perform test_helpers.login(test_helpers.g('accountant'));
  perform test_helpers.expect_msg(format($q$select public.link_document(%L, 'journal_entry', %L)$q$, v_doc, test_helpers.g('je_draft')), 'FORBIDDEN', '2.11b accountant lacks documents.upload and cannot attach evidence either');

  -- owner holds every permission, including both documents.upload and accounting.journal_create:
  -- can attach to both a draft and a posted journal
  perform test_helpers.login(test_helpers.g('owner'));
  v_link := public.link_document(v_doc, 'journal_entry', test_helpers.g('je_draft'), 'other');
  v_link2 := public.link_document(v_doc, 'journal_entry', test_helpers.g('je_posted'), 'other');
  perform test_helpers.assert(v_link is not null and v_link2 is not null, '2.12 evidence attaches to a draft and a posted journal alike');
  perform test_helpers.assert(public.unlink_document(v_link, 'wrong entry') = 'removed', '2.13 evidence on a draft journal can be unlinked');
  perform test_helpers.expect_msg(format($q$select public.unlink_document(%L, 'wrong entry')$q$, v_link2), 'CONFLICT', '2.14 evidence on a posted journal cannot be unlinked');

  perform test_helpers.put('doc1', v_doc);
  perform test_helpers.put('contact1', v_contact);
end
$$;

-- ================================================================ 3. versioning and storage plumbing
do $$
declare
  pt uuid := test_helpers.g('pt');
  v_admin uuid := test_helpers.g('admin');
  v_doc uuid := test_helpers.g('doc1');
  v_doc_v2 uuid;
  v_grant record;
begin
  perform test_helpers.login(v_admin);

  -- 3.1 finalize_document_upload sets storage_path once
  perform public.finalize_document_upload(v_doc, 'p11_pt/documents/contract-v1.pdf');
  perform test_helpers.assert(
    (select storage_path from public.documents where id = v_doc) = 'p11_pt/documents/contract-v1.pdf',
    '3.1 storage_path is set');
  perform test_helpers.expect_msg(format($q$select public.finalize_document_upload(%L, 'p11_pt/documents/other.pdf')$q$, v_doc), 'CONFLICT', '3.2 storage_path cannot be set twice');

  -- 3.3 a corrected file registers as a new document that supersedes the old one
  v_doc_v2 := public.register_document(pt, 'key-p11-doc-01-v2', 'contract-signed.pdf', 'application/pdf', 1200, repeat('c', 64), v_doc);
  perform test_helpers.assert(
    (select supersedes_document_id from public.documents where id = v_doc_v2) = v_doc,
    '3.3 the new document records what it supersedes');
  perform test_helpers.assert(
    (select supersedes_document_id from public.documents where id = v_doc) is null,
    '3.4 the original document itself never changes');

  -- 3.5 replace_document_link swaps the contact's evidence to the new version atomically
  declare
    v_old_link uuid := public.link_document(v_doc, 'contact', test_helpers.g('contact1'), 'other');
    v_new_link uuid;
  begin
    v_new_link := public.replace_document_link(v_old_link, v_doc_v2, 'signed version received');
    perform test_helpers.assert(v_new_link is not null and v_new_link <> v_old_link, '3.5 replace_document_link creates a new link');
    perform test_helpers.assert(
      (select document_id from public.list_document_links(pt, 'contact', test_helpers.g('contact1')) where link_id = v_new_link) = v_doc_v2,
      '3.6 the active link now points at the new version');
    perform test_helpers.assert(
      (select count(*) from public.list_document_links(pt, 'contact', test_helpers.g('contact1')) where link_id = v_old_link) = 0,
      '3.7 the old link is no longer active');
  end;

  -- 3.8 get_document_download_grant: an unlinked document is visible with documents.view alone
  declare
    v_unlinked uuid := public.register_document(pt, 'key-p11-doc-03', 'draft.pdf', 'application/pdf', 500, repeat('d', 64));
  begin
    select * into v_grant from public.get_document_download_grant(v_unlinked);
    perform test_helpers.assert(v_grant.document_id = v_unlinked, '3.8 an unlinked document is downloadable by its uploader');
  end;

  -- 3.9 a linked document is downloadable through the linked target's own view permission
  select * into v_grant from public.get_document_download_grant(v_doc_v2);
  perform test_helpers.assert(v_grant.document_id = v_doc_v2, '3.9 a linked document is downloadable through its target permission');
end
$$;

-- ================================================================ 4. permission boundaries (documents.export, system.import)
do $$
declare
  pt uuid := test_helpers.g('pt');
begin
  perform test_helpers.login(test_helpers.g('admin'));
  perform test_helpers.assert(app_authz.has_permission(pt, 'documents.export'), '4.1 finance_admin holds documents.export');
  perform test_helpers.assert(app_authz.has_permission(pt, 'system.import'), '4.2 finance_admin holds system.import');
  perform test_helpers.assert(app_authz.has_permission(pt, 'system.rollback_import'), '4.3 finance_admin holds system.rollback_import');

  perform test_helpers.login(test_helpers.g('staff'));
  perform test_helpers.assert(not app_authz.has_permission(pt, 'documents.export'), '4.4 finance_staff does not hold documents.export');
  perform test_helpers.assert(not app_authz.has_permission(pt, 'system.import'), '4.5 finance_staff does not hold system.import');
end
$$;

-- ================================================================ 5. Documents Center list (permission-aware)
do $$
declare
  pt uuid := test_helpers.g('pt');
begin
  -- 5.1 finance_admin (contacts.view, accounting.view) sees both the contact- and journal-linked documents
  perform test_helpers.login(test_helpers.g('admin'));
  perform test_helpers.assert((select count(*) from public.list_documents(pt)) >= 2, '5.1 the Documents Center lists reachable documents');

  -- 5.2 filtering by target_type only returns links of that type
  perform test_helpers.assert(
    (select count(*) from public.list_documents(pt, 'journal_entry')) >= 1
    and (select bool_and('journal_entry' = any(target_types)) from public.list_documents(pt, 'journal_entry')),
    '5.2 filtering by target_type narrows the list');

  -- 5.3 a bare view-only role still sees the module through its own view permission
  perform test_helpers.login(test_helpers.g('viewer'));
  perform test_helpers.assert(
    (select count(*) from public.list_documents(pt)) >= 1,
    '5.3 viewer_auditor (accounting.view, contacts.view) still sees the same reachable documents');
end
$$;

-- ================================================================ 6. RLS / grants defense-in-depth
do $$
begin
  perform test_helpers.as_anon();
  perform test_helpers.expect_error('select * from app_private.document_target_kinds', '42501',
    '6.1 anon cannot read the internal target-kind catalog');
  perform test_helpers.expect_error($q$select public.list_documents(gen_random_uuid())$q$, '42501',
    '6.2 anon cannot call list_documents');
  perform test_helpers.logout();

  -- an authenticated stranger with no membership gets the same FORBIDDEN as a permission gap
  perform test_helpers.mk_user('e1100000-0000-0000-0000-00000000009f', 'p11-stranger');
  perform test_helpers.login('e1100000-0000-0000-0000-00000000009f');
  perform test_helpers.expect_msg(format($q$select public.list_documents(%L)$q$, test_helpers.g('pt')), 'FORBIDDEN',
    '6.3 a stranger to the Entity gets FORBIDDEN, not a data leak');
  perform test_helpers.logout();
end
$$;

rollback;
