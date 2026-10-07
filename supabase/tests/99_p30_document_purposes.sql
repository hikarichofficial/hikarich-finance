-- P30: own attachment types. A type is added by someone who may attach files, the same name never makes two
-- types, a link can carry the type, and a type of another Entity (or an invented one) is refused.
-- One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
  v_other uuid;
  v_owner uuid := 'e3300000-0000-0000-0000-000000000001';
  v_viewer uuid := 'e3300000-0000-0000-0000-000000000002';
  v_contact uuid;
  v_doc uuid;
  v_type uuid;
  v_type2 uuid;
  v_foreign uuid;
  v_link uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p30_pt', 'P30 PT (synthetic)') returning id into v_pt;
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p30_other', 'P30 Other (synthetic)') returning id into v_other;
  perform app_private.provision_default_coa(v_pt);
  perform app_private.provision_default_coa(v_other);
  perform test_helpers.mk_user(v_owner, 'p30_owner');
  perform test_helpers.mk_user(v_viewer, 'p30_viewer');
  perform test_helpers.mk_member(v_pt, v_owner, 'owner');
  perform test_helpers.mk_member(v_other, v_owner, 'owner');
  perform test_helpers.mk_member(v_pt, v_viewer, 'viewer_auditor');

  perform test_helpers.login(v_owner);
  v_contact := public.create_contact(v_pt, 'key-p30-ct', 'customer', 'Pelanggan Uji');
  v_doc := public.register_document(v_pt, 'key-p30-doc', 'surat-jalan.pdf', 'application/pdf', 1000, repeat('c', 64));

  v_type := public.create_document_purpose(v_pt, '  Surat   Jalan ');
  perform test_helpers.assert(v_type is not null, '1.1 an attachment type is added');
  v_type2 := public.create_document_purpose(v_pt, 'surat jalan');
  perform test_helpers.assert(v_type2 = v_type, '1.2 the same name (ignoring case and spacing) returns the same type');
  perform test_helpers.assert((select name from public.document_purposes where id = v_type) = 'Surat Jalan', '1.3 the name is stored tidied up');
  perform test_helpers.expect_msg(format($q$select public.create_document_purpose(%L, 'x')$q$, v_pt), 'INVALID', '1.4 a one-letter name is refused');

  v_link := public.link_document(v_doc, 'contact', v_contact, 'custom:' || v_type::text);
  perform test_helpers.assert((select purpose from public.document_links where id = v_link) = 'custom:' || v_type::text, '2.1 a link carries the own type');

  v_foreign := public.create_document_purpose(v_other, 'Milik Entity Lain');
  perform test_helpers.expect_msg(format($q$select public.link_document(%L, 'contact', %L, %L)$q$, v_doc, v_contact, 'custom:' || v_foreign::text),
    'INVALID', '2.2 a type of another Entity is refused');
  perform test_helpers.expect_msg(format($q$select public.link_document(%L, 'contact', %L, %L)$q$, v_doc, v_contact, 'custom:00000000-0000-0000-0000-000000000000'),
    'INVALID', '2.3 an invented type is refused');
  perform test_helpers.expect_msg(format($q$select public.link_document(%L, 'contact', %L, 'whatever')$q$, v_doc, v_contact),
    'INVALID', '2.4 an unknown built-in word is still refused');
  perform test_helpers.logout();

  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format($q$select public.create_document_purpose(%L, 'Bukti Lain')$q$, v_pt), 'FORBIDDEN', '3.1 a viewer cannot add a type');
  perform test_helpers.assert((select count(*) from public.document_purposes where entity_id = v_pt) = 1, '3.2 a viewer can read the types of the Entity');
  perform test_helpers.assert((select count(*) from public.document_purposes where entity_id = v_other) = 0, '3.3 a viewer cannot read another Entity''s types');
  perform test_helpers.logout();
end
$$;

rollback;
