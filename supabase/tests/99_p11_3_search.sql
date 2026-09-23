-- P11 gate, part 3 (Step 06 §11, Step 13 §17, Step 08 §22): Global Search -- kept current from the
-- outbox, permission-filtered before ranking (never merely hidden in the UI), and fully rebuildable.
-- All data is synthetic. The whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p11s (k text primary key, v uuid not null);
grant all on test_helpers.p11s to public;
create function test_helpers.sput(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p11s values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.sg(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p11s where k = p_k $f$;
grant execute on function test_helpers.sput(text, uuid), test_helpers.sg(text) to public;

-- ================================================================ 1. fixtures
do $$
declare
  pt uuid;
  v_owner uuid := 'e1300000-0000-0000-0000-000000000001';
  v_admin uuid := 'e1300000-0000-0000-0000-000000000002';
  v_accountant uuid := 'e1300000-0000-0000-0000-000000000004';
  v_viewer uuid := 'e1300000-0000-0000-0000-000000000005';
  v_tax uuid := 'e1300000-0000-0000-0000-000000000006';
  v_payroll uuid := 'e1300000-0000-0000-0000-000000000007';
  v_contact uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p11s_pt', 'P11 Search PT (synthetic)')
  returning id into pt;
  perform app_private.provision_default_coa(pt);
  perform test_helpers.sput('pt', pt);

  perform test_helpers.mk_user(v_owner, 'p11s-owner');
  perform test_helpers.mk_user(v_admin, 'p11s-admin');
  perform test_helpers.mk_user(v_accountant, 'p11s-accountant');
  perform test_helpers.mk_user(v_viewer, 'p11s-viewer');
  perform test_helpers.mk_user(v_tax, 'p11s-tax');
  perform test_helpers.mk_user(v_payroll, 'p11s-payroll');
  perform test_helpers.sput('owner', v_owner);
  perform test_helpers.sput('admin', v_admin);
  perform test_helpers.sput('accountant', v_accountant);
  perform test_helpers.sput('viewer', v_viewer);
  perform test_helpers.sput('tax', v_tax);
  perform test_helpers.sput('payroll', v_payroll);

  perform test_helpers.mk_member(pt, v_owner, 'owner');
  perform test_helpers.mk_member(pt, v_admin, 'finance_admin');
  perform test_helpers.mk_member(pt, v_accountant, 'accountant');
  perform test_helpers.mk_member(pt, v_viewer, 'viewer_auditor');
  perform test_helpers.mk_member(pt, v_tax, 'tax');
  perform test_helpers.mk_member(pt, v_payroll, 'payroll');

  perform test_helpers.login(v_admin);
  v_contact := public.create_contact(pt, 'key-p11s-c-01', 'customer', 'Widgetsonic Distribution');
  perform test_helpers.sput('contact', v_contact);
end
$$;

-- ================================================================ 2. the outbox keeps the index current
do $$
declare
  pt uuid := test_helpers.sg('pt');
  v_contact uuid := test_helpers.sg('contact');
  v_pending integer;
  v_processed integer;
  v_hits integer;
begin
  -- outbox_events keeps RLS enabled with no policy for browser roles (Step 13 §14-15): direct reads of it,
  -- like every other such check in this suite, happen logged out (as the test runner), never as authenticated.
  perform test_helpers.logout();

  -- creating the contact (fixture, above) queued a SearchReindexRequested event; nothing is indexed yet.
  select count(*) into v_pending from public.outbox_events
    where event_type = 'SearchReindexRequested' and aggregate_type = 'contact' and aggregate_id = v_contact and status = 'pending';
  perform test_helpers.assert(v_pending = 1, '2.1 creating a searchable record queues exactly one reindex event');
  perform test_helpers.assert(
    (select count(*) from public.search_index where entity_id = pt and target_type = 'contact' and target_id = v_contact) = 0,
    '2.2 nothing is indexed until the batch consumer runs');

  perform test_helpers.login(test_helpers.sg('admin'));
  select public.refresh_search_index_batch(100) into v_processed;
  perform test_helpers.assert(v_processed >= 1, '2.3 refresh_search_index_batch processes the pending event');

  perform test_helpers.logout();
  perform test_helpers.assert(
    (select title from public.search_index where entity_id = pt and target_type = 'contact' and target_id = v_contact)
      = 'Widgetsonic Distribution',
    '2.4 the indexed title matches the contact''s display_name, re-derived from the source table');
  perform test_helpers.assert(
    (select status from public.outbox_events where aggregate_type = 'contact' and aggregate_id = v_contact
       and event_type = 'SearchReindexRequested') = 'processed',
    '2.5 the outbox event is marked processed');

  perform test_helpers.login(test_helpers.sg('admin'));
  -- re-running the batch with nothing pending is a no-op, not an error.
  select public.refresh_search_index_batch(100) into v_processed;
  perform test_helpers.assert(v_processed = 0, '2.6 an empty batch processes zero events');

  select count(*) into v_hits from public.search(pt, 'Widgetsonic');
  perform test_helpers.assert(v_hits = 1, '2.7 search finds the newly indexed contact by a partial word');
end
$$;

-- ================================================================ 3. permission filtering before ranking
do $$
declare
  pt uuid := test_helpers.sg('pt');
  v_invoice uuid;
  v_invoice_number text;
  v_count integer;
begin
  perform test_helpers.login(test_helpers.sg('admin'));
  v_invoice := public.create_invoice_draft(pt, 'key-p11s-inv-01', test_helpers.sg('contact'), current_date, current_date + 14,
    jsonb_build_array(jsonb_build_object('description', 'Zephyrmark consulting retainer', 'quantity', 1, 'unit_price', 5000000)),
    'IDR');
  perform test_helpers.assert(public.issue_invoice(v_invoice, 'key-p11s-issue-01') is not null, '3.1 the invoice issues');
  perform public.refresh_search_index_batch(100);

  -- search_reindex_one titles an invoice by its invoice_number (Step 08 §22: derived fields only, no line
  -- item content), so the invoice is found by its number, not by text buried in an invoice line.
  perform test_helpers.logout();
  select invoice_number into v_invoice_number from public.invoices where id = v_invoice;
  perform test_helpers.assert(v_invoice_number is not null, '3.1b the issued invoice was numbered');

  -- finance_admin holds invoices.view: finds it. (The issuing journal entry's own description happens to
  -- mention the invoice number too, and finance_admin holds accounting.view as well, so the raw hit count
  -- includes that journal_entry row -- filter to the invoice row itself, which is the thing under test.)
  perform test_helpers.login(test_helpers.sg('admin'));
  select count(*) into v_count from public.search(pt, v_invoice_number) where target_type = 'invoice';
  perform test_helpers.assert(v_count = 1, '3.2 finance_admin (invoices.view) finds the issued invoice by its number');

  -- viewer_auditor also holds invoices.view (broad read access): finds it too.
  perform test_helpers.login(test_helpers.sg('viewer'));
  select count(*) into v_count from public.search(pt, v_invoice_number) where target_type = 'invoice';
  perform test_helpers.assert(v_count = 1, '3.3 viewer_auditor also finds it (holds invoices.view)');

  -- the payroll role's catalog (Step 06 §11) does not include invoices.view at all: a real permission
  -- gap, not merely hidden in the UI -- the row is excluded from the result set itself.
  perform test_helpers.login(test_helpers.sg('payroll'));
  perform test_helpers.assert(not app_authz.has_permission(pt, 'invoices.view'),
    '3.4 sanity check: the payroll role really does lack invoices.view');
  select count(*) into v_count from public.search(pt, v_invoice_number);
  perform test_helpers.assert(v_count = 0,
    '3.5 the payroll role searches the same index but gets zero hits for a record it cannot open directly');
end
$$;

-- ================================================================ 5. payroll and tax are never indexed
do $$
declare
  pt uuid := test_helpers.sg('pt');
begin
  perform test_helpers.login(test_helpers.sg('admin'));
  -- Nothing in this file ever creates a payroll or tax record, and search_reindex_one only recognizes
  -- the nine business-record kinds -- but the structural guarantee is that no trigger, no reindex path
  -- and no target_type exists for payroll or tax at all (decision 145 / decision 131).
  perform test_helpers.assert(
    not exists (select 1 from public.search_index where target_type in ('payroll_run', 'tax_filing', 'tax_payment')),
    '5.1 payroll and tax target types never appear in the search index');
  perform test_helpers.assert(
    not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                where tg.tgrelid in ('public.payroll_runs'::regclass, 'public.tax_filings'::regclass, 'public.tax_payments'::regclass)
                  and p.proname = 'tg_search_reindex'),
    '5.2 no reindex trigger exists on payroll or tax tables');
end
$$;

-- ================================================================ 6. rebuild is derived and idempotent
do $$
declare
  pt uuid := test_helpers.sg('pt');
  v_before integer;
  v_after integer;
begin
  perform test_helpers.login(test_helpers.sg('admin'));
  select count(*) into v_before from public.search_index where entity_id = pt;
  perform test_helpers.assert(v_before >= 2, '6.1 the index already has the contact and the invoice');

  perform public.rebuild_search_index(pt);
  select count(*) into v_after from public.search_index where entity_id = pt;
  perform test_helpers.assert(v_after = v_before, '6.2 a full rebuild reproduces the same row count (derived, not authoritative)');
end
$$;

-- ================================================================ 7. permission boundaries on the RPCs themselves
do $$
declare
  pt uuid := test_helpers.sg('pt');
begin
  perform test_helpers.login(test_helpers.sg('viewer'));
  perform test_helpers.expect_msg(format($q$select public.rebuild_search_index(%L)$q$, pt),
    'FORBIDDEN', '7.1 viewer_auditor lacks system.import and cannot rebuild the index');
  perform test_helpers.expect_msg('select public.refresh_search_index_batch(100)',
    'FORBIDDEN', '7.2 viewer_auditor lacks system.import and cannot run the batch consumer manually');

  perform test_helpers.login(test_helpers.sg('admin'));
  perform test_helpers.assert(public.rebuild_search_index(pt) >= 0, '7.3 finance_admin (system.import) can rebuild');

  perform test_helpers.expect_msg(format($q$select public.search(%L, '')$q$, pt),
    'INVALID', '7.4 an empty query is rejected');
  perform test_helpers.expect_msg(format($q$select public.search(%L, 'x', 0)$q$, pt),
    'INVALID', '7.5 an out-of-range limit is rejected');
end
$$;

-- ================================================================ 8. RLS / grants defense-in-depth
do $$
begin
  perform test_helpers.as_anon();
  perform test_helpers.expect_error('select * from public.search_index', '42501',
    '8.1 anon cannot read search_index directly');
  perform test_helpers.expect_error(format($q$select public.search(%L, 'anything')$q$, test_helpers.sg('pt')), '42501',
    '8.2 anon cannot call search (not granted execute at all)');
end
$$;

rollback;
