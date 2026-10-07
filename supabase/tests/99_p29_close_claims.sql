-- Decision 334: a pending payment claim is closed when the invoice is fully paid by another payment, left alone
-- when the invoice is only partly paid, and never touched while it is itself being confirmed.
-- One transaction, rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  v_pt uuid;
  v_owner uuid := 'e2900000-0000-0000-0000-000000000001';
  v_cust uuid;
  v_bank uuid;
  v_today date;
  v_inv uuid;
  v_inv2 uuid;
  v_inv3 uuid;
  v_claim uuid;
  v_claim2 uuid;
  v_claim3 uuid;
  v_pay uuid;
  s public.payment_submissions%rowtype;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p29_pt', 'P29 PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  perform test_helpers.mk_user(v_owner, 'p29_owner');
  perform test_helpers.mk_member(v_pt, v_owner, 'owner');
  v_today := app_private.entity_today(v_pt);

  perform test_helpers.login(v_owner);
  v_cust := public.create_contact(v_pt, 'key-p29-ct', 'customer', 'Pelanggan Uji');
  v_bank := public.create_financial_account(v_pt, 'key-p29-fa', 'bank', 'Bank Uji', 'IDR', test_helpers.acct(v_pt, 'BANK_OPERATING'));

  -- 1. full payment recorded directly closes the waiting claim
  v_inv := public.create_invoice_draft(v_pt, 'key-p29-inv1', v_cust, v_today, v_today + 7,
    jsonb_build_array(jsonb_build_object('description', 'Layanan', 'quantity', 1, 'unit_price', 100000)));
  perform public.issue_invoice(v_inv, 'key-p29-iss1');
  v_claim := public.create_payment_claim(v_inv, 'key-p29-cl1', 100000, v_today, 'Pelanggan Uji');
  perform public.record_payment(v_pt, 'key-p29-py1', v_cust, v_bank, v_today, 100000,
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 100000)));

  -- 2. a partial payment leaves the claim pending
  v_inv2 := public.create_invoice_draft(v_pt, 'key-p29-inv2', v_cust, v_today, v_today + 7,
    jsonb_build_array(jsonb_build_object('description', 'Layanan', 'quantity', 1, 'unit_price', 100000)));
  perform public.issue_invoice(v_inv2, 'key-p29-iss2');
  v_claim2 := public.create_payment_claim(v_inv2, 'key-p29-cl2', 100000, v_today, 'Pelanggan Uji');
  perform public.record_payment(v_pt, 'key-p29-py2', v_cust, v_bank, v_today, 40000,
    jsonb_build_array(jsonb_build_object('invoice_id', v_inv2, 'amount', 40000)));

  -- 3. confirming a claim still works (its own allocation does not close it first)
  v_inv3 := public.create_invoice_draft(v_pt, 'key-p29-inv3', v_cust, v_today, v_today + 7,
    jsonb_build_array(jsonb_build_object('description', 'Layanan', 'quantity', 1, 'unit_price', 100000)));
  perform public.issue_invoice(v_inv3, 'key-p29-iss3');
  v_claim3 := public.create_payment_claim(v_inv3, 'key-p29-cl3', 100000, v_today, 'Pelanggan Uji');
  v_pay := public.confirm_payment_submission(v_claim3, 'key-p29-cf3', v_bank);
  perform test_helpers.logout();

  select * into s from public.payment_submissions where id = v_claim;
  perform test_helpers.assert(s.status = 'rejected' and s.reviewed_at is not null and s.review_reason like 'Invoice sudah lunas%',
    '1.1 a pending claim is closed when another payment settles the invoice');

  perform test_helpers.assert((select status from public.payment_submissions where id = v_claim2) = 'pending',
    '2.1 a partly paid invoice keeps its claim pending');

  select * into s from public.payment_submissions where id = v_claim3;
  perform test_helpers.assert(s.status = 'confirmed' and s.payment_id = v_pay, '3.1 the claim that is confirmed ends confirmed, not rejected');
end
$$;

rollback;
