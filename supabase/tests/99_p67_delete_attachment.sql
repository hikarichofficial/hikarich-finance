-- Decision 418: an attachment can be deleted whatever the status of its record; the file leaves the storage (the
-- application removes the bytes, the database says which), the tombstone and the audit stay. One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  pt uuid;
  v_admin uuid := 'e6700000-0000-0000-0000-000000000001';
  v_viewer uuid := 'e6700000-0000-0000-0000-000000000002';
  v_cash uuid;
  v_capital uuid;
  v_today date;
  v_je_posted uuid;
  v_contact uuid;
  v_doc uuid;
  v_doc2 uuid;
  v_doc3 uuid;
  v_link uuid;
  v_link2 uuid;
  v_link3 uuid;
  r jsonb;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p67_pt', 'P67 PT (synthetic)') returning id into pt;
  perform app_private.provision_default_coa(pt);
  perform test_helpers.mk_user(v_admin, 'p67_admin');
  perform test_helpers.mk_user(v_viewer, 'p67_viewer');
  perform test_helpers.mk_member(pt, v_admin, 'owner');
  perform test_helpers.mk_member(pt, v_viewer, 'viewer_auditor');
  v_today := app_private.entity_today(pt);
  v_cash := test_helpers.acct(pt, 'CASH');
  v_capital := test_helpers.acct(pt, 'OWNER_CAPITAL');
  v_je_posted := test_helpers.simple_journal(pt, v_today, v_cash, v_capital, 1000000, 'system', false);
  perform test_helpers.post(v_je_posted);

  perform test_helpers.login(v_admin);
  v_contact := public.create_contact(pt, 'key-p67-c-01', 'customer', 'Pelanggan Uji');
  v_doc := public.register_document(pt, 'key-p67-d-01', 'bukti.pdf', 'application/pdf', 1000, repeat('a', 64));
  perform public.finalize_document_upload(v_doc, pt || '/' || v_doc);
  v_link := public.link_document(v_doc, 'journal_entry', v_je_posted, 'receipt');
  -- the old way is closed for a posted record
  perform test_helpers.expect_msg(format($q$select public.unlink_document(%L, 'coba lepas')$q$, v_link), 'CONFLICT', '1.1 releasing evidence of a posted journal is still refused');

  -- 2. a viewer cannot delete, a reason is required
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format($q$select public.delete_attachment(%L, 'tidak boleh')$q$, v_link), 'FORBIDDEN', '2.1 a viewer cannot delete an attachment');
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format($q$select public.delete_attachment(%L, 'x')$q$, v_link), 'INVALID', '2.2 a reason of at least 3 characters is required');

  -- 3. deleting evidence of a posted record: link removed, file purged, path returned
  r := public.delete_attachment(v_link, 'salah berkas');
  perform test_helpers.assert((r ->> 'purged')::boolean and r ->> 'storage_path' = pt || '/' || v_doc, '3.1 the file is marked deleted and its path returned');
  perform test_helpers.assert((select status = 'removed' and removed_reason = 'Dihapus: salah berkas' from public.document_links where id = v_link), '3.2 the link keeps who/why in its removal');
  perform test_helpers.assert((select deleted_at is not null and deleted_by = v_admin and delete_reason = 'salah berkas' from public.documents where id = v_doc), '3.3 the document is a tombstone with who and why');
  perform test_helpers.expect_msg(format($q$select * from public.get_document_download_grant(%L)$q$, v_doc), 'INVALID', '3.4 a deleted file is not served');
  perform test_helpers.assert(not exists (select 1 from public.list_documents(pt) where document_id = v_doc), '3.5 a deleted file is not listed');
  perform test_helpers.assert(not exists (select 1 from public.list_document_archive(pt) where document_id = v_doc), '3.6 nor in the archive');
  perform test_helpers.expect_msg(format($q$select public.delete_attachment(%L, 'sekali lagi')$q$, v_link), 'CONFLICT', '3.7 a link cannot be deleted twice');
  perform public.confirm_document_purge(v_doc);
  perform test_helpers.assert((select storage_path is null from public.documents where id = v_doc), '3.8 after the bytes are gone the document keeps no path');
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format($q$select public.confirm_document_purge(%L)$q$, v_doc), 'FORBIDDEN', '3.9 a viewer cannot confirm a purge');
  perform test_helpers.login(v_admin);

  -- 4. the same content uploaded again is the same document, alive again
  v_doc2 := public.register_document(pt, 'key-p67-d-02', 'bukti-lagi.pdf', 'application/pdf', 1000, repeat('a', 64));
  perform test_helpers.assert(v_doc2 = v_doc and (select deleted_at is null and delete_reason is null from public.documents where id = v_doc), '4.1 uploading the same content again revives the document');
  perform public.finalize_document_upload(v_doc, pt || '/' || v_doc);
  v_link2 := public.link_document(v_doc, 'contact', v_contact, 'receipt');

  -- 5. a file used by two records is only taken off the one
  v_link3 := public.link_document(v_doc, 'journal_entry', v_je_posted, 'receipt');
  r := public.delete_attachment(v_link3, 'bukan untuk jurnal ini');
  perform test_helpers.assert(not (r ->> 'purged')::boolean and r ->> 'storage_path' is null, '5.1 a file still used elsewhere is kept');
  perform test_helpers.assert((select deleted_at is null from public.documents where id = v_doc), '5.2 the document stays alive for the other record');

  -- 6. from the Documents screens: delete the document with all its links
  v_doc3 := public.register_document(pt, 'key-p67-d-03', 'lain.pdf', 'application/pdf', 500, repeat('b', 64));
  perform public.finalize_document_upload(v_doc3, pt || '/' || v_doc3);
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format($q$select public.delete_document(%L, 'tidak boleh')$q$, v_doc3), 'FORBIDDEN', '6.1 a viewer cannot delete a file');
  perform test_helpers.login(v_admin);
  r := public.delete_document(v_doc3, 'tidak dipakai');
  perform test_helpers.assert((r ->> 'purged')::boolean and r ->> 'storage_path' = pt || '/' || v_doc3, '6.2 an unlinked file is deleted and its path returned');
  perform test_helpers.expect_msg(format($q$select public.delete_document(%L, 'lagi')$q$, v_doc3), 'CONFLICT', '6.3 a file cannot be deleted twice');
  r := public.delete_document(v_doc, 'hapus semua tautan');
  perform test_helpers.assert((r ->> 'purged')::boolean and not exists (select 1 from public.document_links where document_id = v_doc and status = 'active'),
    '6.4 deleting the file removes every link it still had');

  -- 7. the audit trail has the reason
  perform test_helpers.assert(exists (select 1 from public.audit_events a where a.entity_id = pt and a.reason = 'salah berkas'), '7.1 the audit trail records the reason of the delete');
  perform test_helpers.logout();
end
$$;

rollback;
