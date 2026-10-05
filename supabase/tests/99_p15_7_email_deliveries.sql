-- P15: "Riwayat Pengiriman Email" (email_deliveries / record_email_delivery). The history is append-only, written
-- only through the function by someone who may manage the invoice link, readable by whoever may view invoices,
-- and refuses a document that is not in the Entity. All data is synthetic; the whole file is rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
  v_other uuid;
begin
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p157_pt', 'P15-7 PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p157_other', 'P15-7 Other (synthetic)') returning id into v_other;
  perform app_private.provision_default_coa(v_other);
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('b0000000-0000-0000-0000-000000000009', 'stranger');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'b0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_other, 'b0000000-0000-0000-0000-000000000009', 'owner');
end
$$;

do $$
declare
  pt uuid := test_helpers.entity('p157_pt');
  other uuid := test_helpers.entity('p157_other');
  v_owner uuid := 'b0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'b0000000-0000-0000-0000-000000000004';
  v_stranger uuid := 'b0000000-0000-0000-0000-000000000009';
  v_customer uuid;
  v_invoice uuid;
  v_id uuid;
begin
  insert into public.contacts (entity_id, kind, display_name) values (pt, 'customer', 'Pelanggan Uji')
  returning id into v_customer;
  perform test_helpers.login(v_owner);
  v_invoice := public.create_invoice_draft(pt, 'key-p157-inv-1', v_customer, current_date, current_date + 14,
    jsonb_build_array(jsonb_build_object('description', 'Jasa', 'quantity', 1, 'unit_price', 100000)));

  -- the owner records a send, and it shows up in the history
  v_id := public.record_email_delivery(pt, 'invoice', v_invoice, 'pelanggan@example.com', 'sent');
  perform test_helpers.assert(v_id is not null, 'a delivery is recorded');
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.email_deliveries where target_id = %L and status = ''sent''', v_invoice)) = 1, 'the owner sees the row');
  perform public.record_email_delivery(pt, 'invoice', v_invoice, 'pelanggan@example.com', 'failed', 'mailbox full');
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.email_deliveries where target_id = %L', v_invoice)) = 2, 'every attempt is kept');

  -- invalid kind/status, and a document that is not in the Entity
  perform test_helpers.expect_msg(format('select public.record_email_delivery(%L, ''sms'', %L, ''a@b.co'', ''sent'')', pt, v_invoice), 'INVALID', 'unknown kind');
  perform test_helpers.expect_msg(format('select public.record_email_delivery(%L, ''invoice'', %L, ''a@b.co'', ''maybe'')', pt, v_invoice), 'INVALID', 'unknown status');
  perform test_helpers.expect_msg(format('select public.record_email_delivery(%L, ''invoice'', gen_random_uuid(), ''a@b.co'', ''sent'')', pt), 'INVALID', 'unknown document');
  perform test_helpers.expect_msg(format('select public.record_email_delivery(%L, ''invoice'', %L, '' '', ''sent'')', pt, v_invoice), 'INVALID', 'recipient required');

  -- append-only, and no direct writes
  perform test_helpers.expect_error(format('update public.email_deliveries set recipient = ''x@y.zz'' where id = %L', v_id), '42501', 'no direct update');
  perform test_helpers.expect_error(format('insert into public.email_deliveries (entity_id, kind, target_id, recipient, status) values (%L, ''invoice'', %L, ''a@b.co'', ''sent'')', pt, v_invoice), '42501', 'no direct insert');
  perform test_helpers.logout();

  -- a viewer can read the history but not write it; a stranger sees nothing and cannot write
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.email_deliveries where target_id = %L', v_invoice)) = 2, 'a viewer reads the history');
  perform test_helpers.expect_msg(format('select public.record_email_delivery(%L, ''invoice'', %L, ''a@b.co'', ''sent'')', pt, v_invoice), 'FORBIDDEN', 'a viewer cannot record');
  perform test_helpers.logout();
  perform test_helpers.login(v_stranger);
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.email_deliveries where target_id = %L', v_invoice)) = 0, 'another Entity sees nothing');
  perform test_helpers.expect_msg(format('select public.record_email_delivery(%L, ''invoice'', %L, ''a@b.co'', ''sent'')', pt, v_invoice), 'FORBIDDEN', 'a stranger cannot record');
  perform test_helpers.expect_msg(format('select public.record_email_delivery(%L, ''invoice'', %L, ''a@b.co'', ''sent'')', other, v_invoice), 'INVALID', 'a document of another Entity is refused');
  perform test_helpers.logout();
end
$$;

rollback;
