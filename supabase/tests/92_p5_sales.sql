-- P5 gate (Step 15 §9, Step 16 G5): sales, receivables and refunds reconcile end to end.
-- Covers duplicate-aware customers, draft/issue with server-side arithmetic, payments (partial, exact, FX,
-- overpayment kept as customer advance), credit applications, "Saya Sudah Bayar" claims, the public token surface
-- (anonymous role), cancel/void/correct, refunds from allocations and from the advance, reversals, derived
-- status, AR aging, the AR/advance control against the General Ledger, period-close checks and authorization.
-- All data is synthetic; dates are relative to the Entity's today. The whole file runs in one transaction that
-- is rolled back.
begin;
set local client_min_messages = warning;

-- Scratch space that survives role switches inside this transaction.
create table test_helpers.p5 (k text primary key, v uuid not null);
grant all on test_helpers.p5 to public;
create function test_helpers.put(p_k text, p_v uuid) returns uuid
language sql as $f$ insert into test_helpers.p5 values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v $f$;
create function test_helpers.g(p_k text) returns uuid
language sql stable as $f$ select v from test_helpers.p5 where k = p_k $f$;
grant execute on function test_helpers.put(text, uuid), test_helpers.g(text) to public;

-- Test-only windows that work whichever role the test acts as.
create function test_helpers.mc(p_entity uuid, p_as_of date default null)
returns table (financial_account_id uuid, name text, kind text, currency text, is_active boolean,
               movement_balance numeric, movement_base_balance numeric, ledger_balance numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.money_control_rows(p_entity, p_as_of) $f$;
create function test_helpers.arc(p_entity uuid, p_as_of date default null)
returns table (sub_ledger numeric, ledger_sales numeric, ledger_total numeric,
               advance_sub_ledger numeric, advance_ledger_sales numeric, advance_ledger_total numeric)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.ar_control(p_entity, p_as_of) $f$;
create function test_helpers.pos(p_entity uuid, p_as_of date default null)
returns table (invoice_id uuid, invoice_number text, customer_id uuid, currency public.currency_code, status text,
               issue_date date, due_date date, total numeric, settled numeric, outstanding numeric, base_total numeric,
               base_settled numeric, base_outstanding numeric, refunded numeric, settlement_status text,
               refund_status text, is_overdue boolean, days_overdue integer)
language sql security definer set search_path = pg_catalog, public as
$f$ select * from app_private.invoice_positions(p_entity, p_as_of) $f$;
grant execute on function test_helpers.mc(uuid, date), test_helpers.arc(uuid, date), test_helpers.pos(uuid, date) to public;

-- Ledger balance (debit - credit) of an account by system key, as of today.
create function test_helpers.bal(p_entity uuid, p_key text) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select coalesce(sum(l.debit - l.credit), 0)
  from public.journal_lines l
  join public.journal_entries j on j.id = l.journal_id and j.entity_id = l.entity_id and j.status = 'posted'
  join public.ledger_accounts a on a.id = l.ledger_account_id and a.entity_id = l.entity_id
  where l.entity_id = p_entity and a.system_key = p_key $f$;
grant execute on function test_helpers.bal(uuid, text) to public;
create function test_helpers.adv(p_payment uuid) returns numeric
language sql security definer set search_path = pg_catalog, public as $f$
  select rem_amount from app_private.payment_advance_state(p_payment) $f$;
grant execute on function test_helpers.adv(uuid) to public;

-- ================================================================ fixtures (superuser)
do $$
declare
  v_pt uuid;
  v_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name)
  values ('company', 'p5_pt', 'P5 PT (synthetic)') returning id into v_pt;
  perform app_private.provision_default_coa(v_pt);
  insert into public.entities (entity_type, code, legal_name)
  values ('personal', 'p5_pe', 'P5 PERSONAL (synthetic)') returning id into v_pe;
  perform app_private.provision_default_coa(v_pe);

  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000002', 'admin');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000003', 'approver');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000007', 'nobody');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000008', 'staff');
  perform test_helpers.mk_user('c0000000-0000-0000-0000-000000000009', 'pe_admin');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pe, 'c0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000002', 'finance_admin');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000003', 'approver');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_member(v_pt, 'c0000000-0000-0000-0000-000000000008', 'finance_staff');
  perform test_helpers.mk_member(v_pe, 'c0000000-0000-0000-0000-000000000009', 'finance_admin');
end
$$;

-- ================================================================ 1. customers, products and accounts
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  pe uuid := test_helpers.entity('p5_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_alfa uuid;
  v_alfa2 uuid;
  v_beta uuid;
  v_vendor uuid;
  v_pe_cust uuid;
  v_cat uuid;
  v_prod uuid;
begin
  perform test_helpers.login(v_owner);
  v_alfa := public.create_contact(pt, 'key-p5-ct-01', 'customer', 'Alfa Customer', 'alfa@example.invalid', '+62 812-0000-1111',
    null, 'PT Alfa Customer', 'Jl. Contoh 1', 'Jakarta', 'ID');
  perform test_helpers.assert(public.create_contact(pt, 'key-p5-ct-01', 'customer', 'Alfa Customer', 'alfa@example.invalid', '+62 812-0000-1111',
    null, 'PT Alfa Customer', 'Jl. Contoh 1', 'Jakarta', 'ID') = v_alfa, 'creating a customer replays on the same key');
  v_beta := public.create_contact(pt, 'key-p5-ct-02', 'customer', 'Beta Buyer', 'beta@example.invalid');
  v_vendor := public.create_contact(pt, 'key-p5-ct-03', 'vendor', 'Only A Vendor');
  perform test_helpers.put('alfa', v_alfa);
  perform test_helpers.put('beta', v_beta);
  perform test_helpers.put('vendor', v_vendor);

  -- duplicate awareness (Step 08 §15/§17): nothing is merged, the user is told
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-ct-04'', ''customer'', ''Different Name'', ''ALFA@example.invalid'')', pt),
    'CONFLICT', 'the same e-mail is an exact duplicate whatever the case');
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-ct-05'', ''customer'', ''Other Person'', null, ''0812 0000 1111'')', pt),
    'CONFLICT', 'the same phone number in another notation is an exact duplicate');
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-ct-06'', ''customer'', ''  alfa   CUSTOMER '')', pt),
    'CONFLICT', 'the same name is suspected and needs confirmation');
  v_alfa2 := public.create_contact(pt, 'key-p5-ct-07', 'customer', 'Alfa Customer', null, null, null, null, null, null, null, null, true);
  perform test_helpers.assert(v_alfa2 <> v_alfa, 'a confirmed same-name party can be created as a different contact');
  perform test_helpers.assert((select count(*) from public.find_contact_duplicates(pt, 'Alfa Customer', 'alfa@example.invalid')) >= 2
    and exists (select 1 from public.find_contact_duplicates(pt, null, 'alfa@example.invalid') where contact_id = v_alfa and severity = 'exact'),
    'find_contact_duplicates lists the candidates with their severity');
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-ct-08'', ''supplier'', ''X'')', pt), 'INVALID', 'unknown kind');
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-ct-09'', ''customer'', ''  '')', pt), 'INVALID', 'a name is required');
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-ct-10'', ''customer'', ''X'', null, null, null, null, null, null, ''idn'')', pt), 'INVALID', 'country code shape');
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-ct-01'', ''customer'', ''Changed Name'')', pt), 'INVALID', 'a key cannot be reused for another request');
  v_pe_cust := public.create_contact(pe, 'key-p5-ct-11', 'customer', 'Personal Client');
  perform test_helpers.put('pe_cust', v_pe_cust);
  perform test_helpers.logout();

  -- staff can create customers; a viewer and a stranger cannot; a tax identifier needs the sensitive permission
  perform test_helpers.login(v_staff);
  perform public.create_contact(pt, 'key-p5-ct-12', 'customer', 'Staff Made Customer');
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-ct-13'', ''customer'', ''With Tax'', null, null, ''01.234.567.8-901.000'')', pt),
    'FORBIDDEN', 'a tax identifier needs contacts.view_sensitive');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-ct-14'', ''customer'', ''Viewer Made'')', pt), 'FORBIDDEN', 'a viewer cannot create contacts');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select * from public.find_contact_duplicates(%L, ''Alfa Customer'')', pt), 'FORBIDDEN', 'a stranger cannot probe for duplicates');
  perform test_helpers.logout();

  -- products and a revenue category mapped for the sales context (superuser: master-data screens are P1/P2 scope)
  insert into public.categories (entity_id, name, kind) values (pt, 'Digital Courses', 'revenue') returning id into v_cat;
  insert into public.category_account_mappings (entity_id, category_id, context, credit_ledger_account_id, effective_from)
  values (pt, v_cat, 'sales', test_helpers.acct(pt, 'EBOOK_REVENUE'), date '2000-01-01');
  insert into public.products (entity_id, kind, name, default_unit_price, default_currency, default_category_id)
  values (pt, 'service', 'Course A', 1000000, 'IDR', v_cat) returning id into v_prod;
  perform test_helpers.put('cat', v_cat);
  perform test_helpers.put('prod', v_prod);
  insert into public.products (entity_id, kind, name, default_unit_price, default_currency, is_active)
  values (pt, 'service', 'Retired Course', 5, 'IDR', false) returning id into v_prod;
  perform test_helpers.put('prod_off', v_prod);

  -- financial accounts (owner: creates the child ledger accounts)
  perform test_helpers.login(v_owner);
  perform test_helpers.put('bca', public.create_financial_account(pt, 'key-p5-fa-01', 'bank', 'BCA Main', 'IDR', test_helpers.acct(pt, 'BANK_OPERATING'), 'BCA', 'ACC-SECRET-555', 'PT P5'));
  perform test_helpers.put('cash', public.create_financial_account(pt, 'key-p5-fa-02', 'cash', 'Petty Cash', 'IDR', test_helpers.acct(pt, 'CASH')));
  perform test_helpers.put('usd', public.create_financial_account(pt, 'key-p5-fa-03', 'bank', 'USD Account', 'USD'));
  perform test_helpers.put('pe_bank', public.create_financial_account(pe, 'key-p5-fa-04', 'bank', 'Personal BCA', 'IDR', test_helpers.acct(pe, 'PERSONAL_BANK')));
  perform test_helpers.logout();
  insert into public.payment_channels (entity_id, method_kind, name, settlement_financial_account_id)
  values (pt, 'bank_transfer', 'Transfer BCA', test_helpers.g('bca'));
  perform test_helpers.put('chan_bca', (select id from public.payment_channels where entity_id = pt and name = 'Transfer BCA'));
end
$$;

-- ================================================================ 2. draft invoices: server-side arithmetic and validation
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  pe uuid := test_helpers.entity('p5_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_alfa uuid := test_helpers.g('alfa');
  v_beta uuid := test_helpers.g('beta');
  v_vendor uuid := test_helpers.g('vendor');
  v_prod uuid := test_helpers.g('prod');
  v_today date := test_helpers.today(pt);
  v_a uuid;
  v_a2 uuid;
  i public.invoices%rowtype;
  v_ver integer;
  v_lines jsonb;
begin
  perform test_helpers.login(v_staff);
  v_lines := jsonb_build_array(
    jsonb_build_object('product_id', v_prod, 'quantity', '1'),
    jsonb_build_object('description', 'Consulting', 'quantity', '2.5', 'unit_price', '320000', 'discount_type', 'percent', 'discount_value', '10'),
    jsonb_build_object('description', 'Workshop seats', 'quantity', 3, 'unit_price', 100000, 'discount_type', 'fixed', 'discount_value', 50000));
  -- the browser never supplies a total: everything is computed on the server
  v_a := public.create_invoice_draft(pt, 'key-p5-inv-01', v_alfa, v_today - 10, v_today + 20, v_lines, null, null,
    'Thank you', 'Net 30', 'Pay to BCA', 'internal: VIP customer', test_helpers.g('bca'), test_helpers.g('chan_bca'));
  perform test_helpers.put('inv_a', v_a);
  perform test_helpers.assert(public.create_invoice_draft(pt, 'key-p5-inv-01', v_alfa, v_today - 10, v_today + 20, v_lines, null, null,
    'Thank you', 'Net 30', 'Pay to BCA', 'internal: VIP customer', test_helpers.g('bca'), test_helpers.g('chan_bca')) = v_a, 'creating a draft replays on the same key');
  select * into i from public.invoices where id = v_a;
  perform test_helpers.assert(i.status = 'draft' and i.invoice_number is null and i.journal_id is null and i.currency = 'IDR'
    and i.subtotal = 2100000 and i.discount_total = 130000 and i.total = 1970000 and i.tax_total = 0,
    'draft totals are computed: 1,000,000 + 800,000 + 300,000 less 80,000 and 50,000');
  perform test_helpers.assert((select array_agg(line_total::numeric order by line_no) from public.invoice_lines where invoice_id = v_a) = array[1000000, 720000, 250000]::numeric[]
    and (select description from public.invoice_lines where invoice_id = v_a and line_no = 1) = 'Course A'
    and (select unit_price from public.invoice_lines where invoice_id = v_a and line_no = 1) = 1000000
    and (select category_id from public.invoice_lines where invoice_id = v_a and line_no = 1) = test_helpers.g('cat'),
    'line totals, the product name/price/category default');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where source_type = 'invoice' and source_id = v_a)
    and not exists (select 1 from public.invoice_public_links where invoice_id = v_a), 'a draft has no journal and no public link');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-01'', %L, %L, %L)', pt, v_alfa, v_today - 9, v_today + 20),
    'INVALID', 'a key cannot be reused for a different invoice');
  perform test_helpers.logout();

  -- header validation
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-02'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, v_vendor, v_today, v_today),
    'INVALID', 'a vendor-only contact cannot be invoiced');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-03'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, test_helpers.g('pe_cust'), v_today, v_today),
    'INVALID', 'a customer of another Entity is refused');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-04'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, v_alfa, v_today, v_today - 1),
    'INVALID', 'the due date cannot precede the issue date');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-05'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', null, 15000)', pt, v_alfa, v_today, v_today),
    'INVALID', 'a base-currency invoice has no rate');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-06'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', ''USD'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a foreign-currency invoice needs a rate');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-07'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', ''ZZZ'', 1)', pt, v_alfa, v_today, v_today),
    'INVALID', 'unknown currency');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-08'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', null, null, null, null, null, null, %L)', pt, v_alfa, v_today, v_today, test_helpers.g('usd')),
    'INVALID', 'the payment destination must be in the invoice currency');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-09'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'', null, null, null, null, null, null, %L, %L)', pt, v_alfa, v_today, v_today, test_helpers.g('cash'), test_helpers.g('chan_bca')),
    'INVALID', 'a channel must settle into the chosen account');
  -- line validation
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-10'', %L, %L, %L, ''[{"description":"x","quantity":"0","unit_price":1}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a quantity must be positive');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-11'', %L, %L, %L, ''[{"description":"x","quantity":"1.00001","unit_price":1}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a quantity has at most 4 decimals');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-12'', %L, %L, %L, ''[{"description":"x","unit_price":"abc"}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a price must be a number');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-13'', %L, %L, %L, ''[{"description":"x","unit_price":"NaN"}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'NaN is never a price');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-14'', %L, %L, %L, ''[{"description":"x","unit_price":-1}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a price cannot be negative');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-15'', %L, %L, %L, ''[{"unit_price":1}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a line needs a description or a product');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-16'', %L, %L, %L, ''[{"description":"x","unit_price":100,"discount_type":"percent","discount_value":101}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a percentage discount cannot exceed 100');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-17'', %L, %L, %L, ''[{"description":"x","unit_price":100,"discount_type":"fixed","discount_value":101}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a fixed discount cannot exceed the line');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-18'', %L, %L, %L, ''[{"description":"x","unit_price":100,"discount_type":"fixed","discount_value":1.555}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a fixed discount must fit the currency minor unit (2 decimals)');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-19'', %L, %L, %L, ''[{"description":"x","unit_price":100,"discount_value":5}]'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'a discount value needs a discount type');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-20'', %L, %L, %L, ''[{"product_id":"%s","unit_price":1}]'')', pt, v_alfa, v_today, v_today, test_helpers.g('prod_off')),
    'INVALID', 'an inactive product cannot be sold');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-21'', %L, %L, %L, ''[{"description":"x","unit_price":1,"category_id":"%s"}]'')', pt, v_alfa, v_today, v_today, gen_random_uuid()),
    'INVALID', 'an unknown category is refused');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-22'', %L, %L, %L, ''{"a":1}'')', pt, v_alfa, v_today, v_today),
    'INVALID', 'lines must be a list');
  -- rounding is half-up in the currency's minor unit, once per line and once per discount
  v_a2 := public.create_invoice_draft(pt, 'key-p5-inv-23', v_alfa, v_today, v_today,
    '[{"description":"Rounding","unit_price":"10.005","discount_type":"percent","discount_value":"33.3333"}]');
  select * into i from public.invoices where id = v_a2;
  perform test_helpers.assert(i.subtotal = 10.01 and i.discount_total = 3.34 and i.total = 6.67, 'half-up rounding: 10.005 -> 10.01, 33.3333% -> 3.34');
  perform public.cancel_invoice(v_a2, 'key-p5-inv-24', 'Rounding probe');
  -- the browser can never write invoices directly
  perform test_helpers.expect_error(format('insert into public.invoices (entity_id, customer_id, currency, issue_date, due_date) values (%L, %L, ''IDR'', %L, %L)', pt, v_alfa, v_today, v_today),
    '42501', 'no direct insert into invoices');
  perform test_helpers.expect_error(format('update public.invoices set total = 1 where id = %L', v_a), '42501', 'no direct update of invoices');
  perform test_helpers.logout();

  -- editing: only a draft, with a version check and a whitelist
  perform test_helpers.login(v_staff);
  select version into v_ver from public.invoices where id = v_a;
  perform test_helpers.assert(public.update_invoice_draft(v_a, jsonb_build_object('notes', 'Updated note', 'due_date', (v_today + 25)::text), v_ver) = v_ver + 1, 'update bumps the version');
  perform test_helpers.expect_msg(format('select public.update_invoice_draft(%L, ''{"notes":"stale"}'', %s)', v_a, v_ver), 'CONFLICT', 'a stale version is refused');
  perform test_helpers.expect_msg(format('select public.update_invoice_draft(%L, ''{"total":5}'')', v_a), 'INVALID', 'a total cannot be patched');
  perform test_helpers.expect_msg(format('select public.update_invoice_draft(%L, ''{"status":"issued"}'')', v_a), 'INVALID', 'the status cannot be patched');
  perform test_helpers.expect_msg(format('select public.update_invoice_draft(%L, ''{"due_date":"%s"}'')', v_a, v_today - 30), 'INVALID', 'a due date before the issue date');
  perform test_helpers.assert((select total from public.invoices where id = v_a) = 1970000, 'a rejected edit changes nothing');
  -- lines are replaced as a whole and re-computed
  v_a2 := public.create_invoice_draft(pt, 'key-p5-inv-30', v_alfa, v_today - 10, v_today + 20, '[{"description":"Temp","unit_price":10}]');
  perform public.update_invoice_draft(v_a2, jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('description', 'Replaced', 'quantity', 3, 'unit_price', 7))));
  perform test_helpers.assert((select total from public.invoices where id = v_a2) = 21 and (select count(*) from public.invoice_lines where invoice_id = v_a2) = 1, 'replacing the lines recomputes the total');
  perform public.cancel_invoice(v_a2, 'key-p5-inv-31', 'Created by mistake');
  perform test_helpers.assert((select status from public.invoices where id = v_a2) = 'cancelled' and not exists (select 1 from public.journal_entries where source_id = v_a2),
    'cancelling a draft has no accounting effect');
  perform test_helpers.expect_msg(format('select public.update_invoice_draft(%L, ''{"notes":"x"}'')', v_a2), 'CONFLICT', 'a cancelled draft cannot be edited');
  perform test_helpers.logout();

  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-inv-40'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pt, v_alfa, v_today, v_today), 'FORBIDDEN', 'a viewer cannot create invoices');
  perform test_helpers.expect_msg(format('select public.update_invoice_draft(%L, ''{"notes":"x"}'')', v_a), 'FORBIDDEN', 'a viewer cannot edit');
  perform test_helpers.logout();
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select public.update_invoice_draft(%L, ''{"notes":"x"}'')', v_a), 'FORBIDDEN', 'a stranger cannot edit (same answer as not found)');
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-inv-41'')', v_a), 'FORBIDDEN', 'a stranger cannot issue');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.invoices') = 0 and test_helpers.rows('select 1 from public.invoice_lines') = 0, 'a stranger sees no invoices');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. issuing: the one step that books, numbers and freezes
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  pe uuid := test_helpers.entity('p5_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_alfa uuid := test_helpers.g('alfa');
  v_beta uuid := test_helpers.g('beta');
  v_today date := test_helpers.today(pt);
  v_a uuid := test_helpers.g('inv_a');
  v_tmp uuid;
  v_j uuid;
  i public.invoices%rowtype;
  v_ar_before numeric;
  v_pi uuid;
begin
  -- refusals before anything is booked
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-is-01'')', v_a), 'FORBIDDEN', 'staff (no invoices.issue) cannot issue');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  v_tmp := public.create_invoice_draft(pt, 'key-p5-is-02', v_alfa, v_today + 3, v_today + 30, '[{"description":"Future","unit_price":100}]');
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-is-03'')', v_tmp), 'INVALID', 'a future-dated invoice stays a draft until its date');
  v_tmp := public.create_invoice_draft(pt, 'key-p5-is-04', v_alfa, v_today, v_today, '[]');
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-is-05'')', v_tmp), 'INVALID', 'an invoice needs at least one line');
  v_tmp := public.create_invoice_draft(pt, 'key-p5-is-06', v_alfa, v_today, v_today, '[{"description":"Free","unit_price":100,"discount_type":"percent","discount_value":100}]');
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-is-07'')', v_tmp), 'INVALID', 'a zero-value invoice cannot be issued');
  v_tmp := public.create_invoice_draft(pt, 'key-p5-is-08', v_alfa, v_today, v_today, '[{"description":"Taxed","unit_price":100}]');
  perform test_helpers.logout();
  -- tax is produced by the tax engine (P7); nothing is guessed until then
  update public.invoice_lines set tax_amount = 11, line_total = 111 where invoice_id = v_tmp;
  update public.invoices set tax_total = 11, total = 111 where id = v_tmp;
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-is-09'')', v_tmp), 'CONFLICT', 'an invoice that already carries tax is refused, not guessed');
  perform test_helpers.assert(not exists (select 1 from public.journal_entries where source_id = v_tmp) and (select status from public.invoices where id = v_tmp) = 'draft',
    'every refused issue leaves nothing behind');
  perform public.cancel_invoice(v_tmp, 'key-p5-is-10', 'Tax not supported yet');
  perform test_helpers.logout();

  -- issue A
  perform test_helpers.login(v_admin);
  v_ar_before := test_helpers.bal(pt, 'ACCOUNTS_RECEIVABLE');
  perform test_helpers.assert(public.issue_invoice(v_a, 'key-p5-is-11') = v_a, 'issue returns the invoice');
  perform test_helpers.assert(public.issue_invoice(v_a, 'key-p5-is-11') = v_a, 'issuing replays on the same key');
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-is-12'')', v_a), 'CONFLICT', 'an issued invoice cannot be issued again');
  perform test_helpers.logout();
  select * into i from public.invoices where id = v_a;
  perform test_helpers.assert(i.status = 'issued' and i.invoice_number like 'HKD%' and i.journal_id is not null and i.issued_at is not null
    and i.issued_by = v_admin and i.base_total = 1970000 and i.base_discount_total = 130000, 'issued: numbered with the company prefix, journal linked, base values stored');
  v_j := i.journal_id;
  perform test_helpers.assert((select status from public.journal_entries where id = v_j) = 'posted'
    and (select source_type from public.journal_entries where id = v_j) = 'invoice'
    and (select entry_date from public.journal_entries where id = v_j) = i.issue_date, 'one posted journal from the posting engine on the issue date');
  perform test_helpers.assert(test_helpers.bal(pt, 'ACCOUNTS_RECEIVABLE') - v_ar_before = 1970000, 'the receivable rises by the invoice total');
  perform test_helpers.assert((select sum(debit) from public.journal_lines where journal_id = v_j) = 2100000
    and (select sum(credit) from public.journal_lines where journal_id = v_j) = 2100000, 'balanced: 1,970,000 + 130,000 = 2,100,000');
  perform test_helpers.assert((select debit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = v_j and a.system_key = 'SALES_CONTRA') = 130000
    and (select credit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = v_j and a.system_key = 'EBOOK_REVENUE') = 1000000
    and (select sum(credit) from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = v_j and a.system_key = 'OTHER_OPERATING_REVENUE') = 1100000,
    'discount on the contra account; revenue by the category mapping (course) and by the default account (the rest)');
  perform test_helpers.assert((select array_agg(base_amount::numeric order by line_no) from public.invoice_lines where invoice_id = v_a) = array[1000000, 800000, 300000]::numeric[]
    and (select bool_and(revenue_account_id is not null) from public.invoice_lines where invoice_id = v_a), 'each line keeps its base amount and revenue account');
  perform test_helpers.assert(i.issuer_snapshot ->> 'legal_name' = 'P5 PT (synthetic)' and i.customer_snapshot ->> 'display_name' = 'Alfa Customer'
    and not (i.customer_snapshot ? 'tax_identifier') and i.payment_snapshot ->> 'institution_name' = 'BCA', 'issuer, customer and payment facts are frozen; no customer tax identifier');
  perform test_helpers.assert((select count(*) from public.invoice_public_links where invoice_id = v_a and status = 'active') = 1
    and exists (select 1 from public.outbox_events where aggregate_id = v_a and event_type = 'InvoiceIssued'), 'an active public link and an outbox event appear');

  -- frozen after issue
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.update_invoice_draft(%L, ''{"notes":"late"}'')', v_a), 'CONFLICT', 'an issued invoice cannot be edited');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format('update public.invoices set customer_id = %L where id = %L', v_beta, v_a), null, 'the customer of an issued invoice is frozen at the database');
  perform test_helpers.expect_error(format('update public.invoices set total = total + 1 where id = %L', v_a), null, 'the total of an issued invoice is frozen');
  perform test_helpers.expect_error(format('update public.invoice_lines set unit_price = 1 where invoice_id = %L', v_a), null, 'issued lines are frozen');
  perform test_helpers.expect_error(format('delete from public.invoice_lines where invoice_id = %L', v_a), null, 'issued lines cannot be deleted');
  perform test_helpers.expect_error(format('delete from public.invoices where id = %L', v_a), null, 'invoices are never deleted');
  perform test_helpers.expect_error(format('update public.invoices set invoice_number = ''HKD-9'' where id = %L', v_a), null, 'the number is frozen');
  perform test_helpers.expect_error(format('update public.invoices set status = ''draft'' where id = %L', v_a), null, 'an issued invoice never returns to draft');

  -- the due date is the one commercial term that may change, with a reason and never before the issue date
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(public.update_invoice_due_date(v_a, v_today + 30, 'Customer asked for time') = v_today + 30, 'the due date can move after issue');
  perform test_helpers.expect_msg(format('select public.update_invoice_due_date(%L, %L, ''too early'')', v_a, v_today - 11), 'INVALID', 'not before the issue date');
  perform test_helpers.expect_msg(format('select public.update_invoice_due_date(%L, %L, '' '')', v_a, v_today), 'INVALID', 'a reason is required');
  perform test_helpers.logout();
  perform test_helpers.assert(exists (select 1 from public.audit_events where target_table = 'invoices' and target_id = v_a and reason = 'Customer asked for time'), 'the due date change is audited with its reason');
  perform test_helpers.assert((select customer_snapshot ->> 'display_name' from public.invoices where id = v_a) = 'Alfa Customer', 'the snapshot is untouched');

  -- editing the customer master afterwards does not rewrite the issued document
  update public.contacts set display_name = 'Alfa Renamed' where id = v_alfa;
  perform test_helpers.assert((select customer_snapshot ->> 'display_name' from public.invoices where id = v_a) = 'Alfa Customer'
    and app_private.invoice_document_json(v_a, false) #>> '{customer,display_name}' = 'Alfa Customer', 'a renamed customer does not change the issued invoice document');
  update public.contacts set display_name = 'Alfa Customer' where id = v_alfa;
end
$$;

-- ================================================================ 4. more invoices, then payments (partial, exact, multi, advance)
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  pe uuid := test_helpers.entity('p5_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_alfa uuid := test_helpers.g('alfa');
  v_beta uuid := test_helpers.g('beta');
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_cash uuid := test_helpers.g('cash');
  v_usd uuid := test_helpers.g('usd');
  v_a uuid := test_helpers.g('inv_a');
  v_b uuid;
  v_c uuid;
  v_d uuid;
  v_u uuid;
  v_s uuid;
  v_pe1 uuid;
begin
  perform test_helpers.login(v_admin);
  v_b := public.create_invoice_draft(pt, 'key-p5-in-01', v_beta, v_today - 60, v_today - 40, '[{"description":"Old order","unit_price":500000}]');
  v_c := public.create_invoice_draft(pt, 'key-p5-in-02', v_alfa, v_today - 10, v_today + 5, '[{"description":"Order C","unit_price":1000000}]', null, null, null, null, null, null, v_bca);
  v_d := public.create_invoice_draft(pt, 'key-p5-in-03', v_alfa, v_today - 5, v_today + 10, '[{"description":"Order D","unit_price":400000}]');
  v_u := public.create_invoice_draft(pt, 'key-p5-in-04', v_alfa, v_today - 8, v_today + 20,
    '[{"description":"Export order","unit_price":"1000","discount_type":"percent","discount_value":"10"}]', 'USD', 15000, null, null, null, null, v_usd);
  v_s := public.create_invoice_draft(pt, 'key-p5-in-05', v_beta, v_today - 2, v_today + 14, '[{"description":"Order S","unit_price":1000000}]');
  perform public.issue_invoice(v_b, 'key-p5-in-11');
  perform public.issue_invoice(v_c, 'key-p5-in-12');
  perform public.issue_invoice(v_d, 'key-p5-in-13');
  perform public.issue_invoice(v_u, 'key-p5-in-14');
  perform public.issue_invoice(v_s, 'key-p5-in-15');
  perform test_helpers.put('inv_b', v_b);
  perform test_helpers.put('inv_c', v_c);
  perform test_helpers.put('inv_d', v_d);
  perform test_helpers.put('inv_u', v_u);
  perform test_helpers.put('inv_s', v_s);
  perform test_helpers.assert((select count(distinct invoice_number) from public.invoices where entity_id = pt and status = 'issued') = 6
    and (select invoice_number from public.invoices where id = v_a) < (select invoice_number from public.invoices where id = v_b), 'six issued invoices, six distinct gapless numbers (in issue order)');
  perform test_helpers.assert((select total = 900 and base_total = 13500000 and base_discount_total = 1500000 and exchange_rate = 15000 from public.invoices where id = v_u),
    'the USD invoice books 900 USD x 15,000 = 13,500,000 (gross 15,000,000 less 1,500,000 discount)');
  perform test_helpers.assert((select l.original_amount from public.journal_lines l join public.journal_entries j on j.id = l.journal_id
      join public.ledger_accounts a on a.id = l.ledger_account_id where j.source_id = v_u and a.system_key = 'ACCOUNTS_RECEIVABLE') = 900, 'the receivable line keeps the original USD amount');
  perform test_helpers.logout();

  -- a personal invoice: the discount and the income use the personal income account (no contra account exists)
  perform test_helpers.login(v_owner);
  v_pe1 := public.create_invoice_draft(pe, 'key-p5-in-20', test_helpers.g('pe_cust'), v_today - 3, v_today + 10,
    '[{"description":"Personal service","unit_price":200000,"discount_type":"fixed","discount_value":20000}]');
  perform public.issue_invoice(v_pe1, 'key-p5-in-21');
  perform test_helpers.put('inv_pe1', v_pe1);
  perform test_helpers.assert((select invoice_number like 'INV%' and total = 180000 from public.invoices where id = v_pe1), 'a personal invoice uses the INV prefix, not the company one');
  perform test_helpers.assert(test_helpers.bal(pe, 'ACCOUNTS_RECEIVABLE') = 180000 and test_helpers.bal(pe, 'OTHER_PERSONAL_INCOME') = -180000, 'personal: income 200,000 less discount 20,000 on the same account');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after issuing');
  perform test_helpers.controls(pe, 'personal after issuing');
end
$$;

-- ================================================================ 5. payments
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  pe uuid := test_helpers.entity('p5_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_alfa uuid := test_helpers.g('alfa');
  v_beta uuid := test_helpers.g('beta');
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_cash uuid := test_helpers.g('cash');
  v_usd uuid := test_helpers.g('usd');
  v_a uuid := test_helpers.g('inv_a');
  v_b uuid := test_helpers.g('inv_b');
  v_c uuid := test_helpers.g('inv_c');
  v_d uuid := test_helpers.g('inv_d');
  v_u uuid := test_helpers.g('inv_u');
  v_p1 uuid;
  v_p2 uuid;
  v_p3 uuid;
  v_p4 uuid;
  v_pu1 uuid;
  v_pu2 uuid;
  v_pe_pay uuid;
  v_cred uuid;
  p public.payments%rowtype;
  v_j uuid;
  v_bca_before numeric;
begin
  perform test_helpers.login(v_admin);
  -- ---- refusals (nothing is booked by any of them)
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-01'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'')', pt, v_beta, v_bca, v_today - 5, v_a),
    'INVALID', 'an invoice of another customer cannot be paid');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-02'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'')', pt, v_alfa, v_bca, v_today - 5, v_u),
    'INVALID', 'a USD invoice cannot be paid into an IDR account');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-03'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'')', pt, v_alfa, v_bca, v_today + 1, v_a),
    'INVALID', 'a payment cannot be dated in the future');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-04'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'')', pt, v_alfa, v_bca, v_today - 11, v_a),
    'INVALID', 'a payment cannot precede the invoice');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-05'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'', 15000)', pt, v_alfa, v_bca, v_today - 5, v_a),
    'INVALID', 'an IDR account takes no rate');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-06'', %L, %L, %L, 1970001, ''[{"invoice_id":"%s","amount":1970001}]'')', pt, v_alfa, v_bca, v_today - 5, v_a),
    'INVALID', 'an allocation cannot exceed what is outstanding');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-07'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":200}]'')', pt, v_alfa, v_bca, v_today - 5, v_a),
    'INVALID', 'allocations cannot exceed the payment');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-08'', %L, %L, %L, 5000000, ''[{"invoice_id":"%s","amount":1970000}]'')', pt, v_alfa, v_bca, v_today - 5, v_a),
    'INVALID', 'money beyond the invoices is not silently kept: the user must say it is an advance');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-09'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":50},{"invoice_id":"%s","amount":50}]'')', pt, v_alfa, v_bca, v_today - 5, v_a, v_a),
    'INVALID', 'an invoice appears once in the allocations');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-10'', %L, %L, %L, 100.001, ''[{"invoice_id":"%s","amount":100}]'')', pt, v_alfa, v_bca, v_today - 5, v_a),
    'INVALID', 'too many decimals');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-11'', %L, %L, %L, 0, ''[]'')', pt, v_alfa, v_bca, v_today - 5),
    'INVALID', 'a zero payment');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-12'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'')', pt, v_alfa, gen_random_uuid(), v_today - 5, v_a),
    'INVALID', 'an unknown account');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-13'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'')', pt, test_helpers.g('vendor'), v_bca, v_today - 5, v_a),
    'INVALID', 'a vendor cannot pay an invoice');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-14'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'')', pt, v_alfa, v_bca, v_today - 5, gen_random_uuid()),
    'INVALID', 'an unknown invoice');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-15'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":-5}]'')', pt, v_alfa, v_bca, v_today - 5, v_a),
    'INVALID', 'a negative allocation');
  perform test_helpers.assert(not exists (select 1 from public.payments where entity_id = pt) and not exists (select 1 from public.money_movements where entity_id = pt and source_type = 'payment'),
    'refused payments leave nothing behind');

  -- ---- a partial payment
  select movement_balance into v_bca_before from test_helpers.mc(pt) where financial_account_id = v_bca;
  v_p1 := public.record_payment(pt, 'key-p5-py-20', v_alfa, v_bca, v_today - 5, 800000, jsonb_build_array(jsonb_build_object('invoice_id', v_a, 'amount', 800000)),
    null, 'TRX-001', 'Alfa Customer', test_helpers.g('chan_bca'), false, 'first instalment');
  perform test_helpers.put('pay_1', v_p1);
  perform test_helpers.assert(public.record_payment(pt, 'key-p5-py-20', v_alfa, v_bca, v_today - 5, 800000, jsonb_build_array(jsonb_build_object('invoice_id', v_a, 'amount', 800000)),
    null, 'TRX-001', 'Alfa Customer', test_helpers.g('chan_bca'), false, 'first instalment') = v_p1, 'recording a payment replays on the same key: one payment, one movement');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-20'', %L, %L, %L, 900000, ''[]'', null, null, null, null, true)', pt, v_alfa, v_bca, v_today - 5),
    'INVALID', 'the key cannot be reused for another payment');
  perform test_helpers.logout();
  select * into p from public.payments where id = v_p1;
  perform test_helpers.assert(p.status = 'confirmed' and p.payment_number like 'RCP%' and p.amount = 800000 and p.base_amount = 800000 and p.allocated_amount = 800000
    and p.advance_amount = 0 and p.fx_difference = 0 and p.reference = 'TRX-001' and p.receipt_snapshot ? 'issuer' and p.receipt_snapshot ? 'customer',
    'a confirmed payment with a receipt number and a frozen receipt snapshot');
  v_j := p.journal_id;
  perform test_helpers.assert((select count(*) from public.journal_lines where journal_id = v_j) = 2
    and (select debit from public.journal_lines l where l.journal_id = v_j and l.ledger_account_id = (select ledger_account_id from public.financial_accounts where id = v_bca)) = 800000
    and (select credit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = v_j and a.system_key = 'ACCOUNTS_RECEIVABLE') = 800000,
    'Dr bank 800,000 / Cr accounts receivable 800,000');
  perform test_helpers.assert((select movement_balance from test_helpers.mc(pt) where financial_account_id = v_bca) - v_bca_before = 800000
    and (select count(*) from public.money_movements where source_type = 'payment' and source_id = v_p1) = 1
    and (select direction from public.money_movements where source_type = 'payment' and source_id = v_p1) = 'in', 'the bank balance rises by exactly the payment through one movement');
  perform test_helpers.assert((select settled = 800000 and outstanding = 1170000 and settlement_status = 'partial' and refund_status = 'none' from test_helpers.pos(pt) where invoice_id = v_a),
    'the invoice is partially paid: derived, not stored');
  perform test_helpers.assert((select status from public.invoices where id = v_a) = 'issued', 'the stored invoice status stays "issued"');
  perform test_helpers.assert((select count(*) from public.payment_allocations where payment_id = v_p1 and kind = 'payment' and status = 'active') = 1
    and (select base_ar_amount from public.payment_allocations where payment_id = v_p1) = 800000, 'one allocation with its receivable value');
  perform test_helpers.controls(pt, 'after the first payment');

  -- the database stops what the RPC would also stop
  perform test_helpers.expect_error(format('update public.payments set amount = 1 where id = %L', v_p1), null, 'a payment amount is frozen');
  perform test_helpers.expect_error(format('update public.payments set customer_id = %L where id = %L', v_beta, v_p1), null, 'a payment cannot change customer');
  perform test_helpers.expect_error(format('delete from public.payments where id = %L', v_p1), null, 'payments are never deleted');
  perform test_helpers.expect_error(format('update public.payment_allocations set amount = 1 where payment_id = %L', v_p1), null, 'allocations are append-only');
  perform test_helpers.expect_error(format('delete from public.payment_allocations where payment_id = %L', v_p1), null, 'allocations are never deleted');
  perform test_helpers.expect_error(format('insert into public.payment_allocations (entity_id, payment_id, invoice_id, kind, amount, base_ar_amount, allocation_date, journal_id) values (%L, %L, %L, ''payment'', 1170001, 1170001, %L, %L)', pt, v_p1, v_a, v_today, v_j),
    null, 'the database refuses an over-allocation whoever writes it');
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_error(format('insert into public.payments (entity_id, payment_number, customer_id, financial_account_id, currency, amount, base_amount, payment_date, allocated_amount, receipt_snapshot, journal_id) values (%L, ''X'', %L, %L, ''IDR'', 1, 1, %L, 1, ''{}'', %L)', pt, v_alfa, v_bca, v_today, v_j),
    '42501', 'browser roles cannot insert payments');
  perform test_helpers.logout();

  -- ---- the rest of A settles it
  perform test_helpers.login(v_admin);
  v_p2 := public.record_payment(pt, 'key-p5-py-21', v_alfa, v_bca, v_today - 4, 1170000, jsonb_build_array(jsonb_build_object('invoice_id', v_a, 'amount', 1170000)));
  perform test_helpers.put('pay_2', v_p2);
  perform test_helpers.assert((select settlement_status = 'paid' and outstanding = 0 and settled = 1970000 from test_helpers.pos(pt) where invoice_id = v_a), 'the invoice is paid');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-22'', %L, %L, %L, 1, ''[{"invoice_id":"%s","amount":1}]'')', pt, v_alfa, v_bca, v_today - 3, v_a),
    'INVALID', 'a paid invoice cannot be paid again');
  perform test_helpers.assert((select payment_number from public.payments where id = v_p2) > (select payment_number from public.payments where id = v_p1), 'receipt numbers run in order');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'A paid');

  -- ---- one payment settling two invoices (cash account)
  perform test_helpers.login(v_admin);
  v_p3 := public.record_payment(pt, 'key-p5-py-30', v_alfa, v_cash, v_today - 3, 700000,
    jsonb_build_array(jsonb_build_object('invoice_id', v_c, 'amount', 600000), jsonb_build_object('invoice_id', v_d, 'amount', 100000)));
  perform test_helpers.put('pay_3', v_p3);
  perform test_helpers.assert((select count(*) from public.payment_allocations where payment_id = v_p3) = 2
    and (select outstanding from test_helpers.pos(pt) where invoice_id = v_c) = 400000
    and (select outstanding from test_helpers.pos(pt) where invoice_id = v_d) = 300000, 'two allocations from one payment');
  perform test_helpers.assert((select count(*) from public.journal_lines where journal_id = (select journal_id from public.payments where id = v_p3)) = 3, 'one journal: Dr cash, Cr AR per invoice (two lines)');

  -- ---- an overpayment: only kept as a customer advance when the user says so
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-31'', %L, %L, %L, 800000, %L::jsonb)', pt, v_alfa, v_bca, v_today - 2,
    jsonb_build_array(jsonb_build_object('invoice_id', v_c, 'amount', 400000))::text), 'INVALID', 'overpayment without the explicit choice is refused');
  v_p4 := public.record_payment(pt, 'key-p5-py-32', v_alfa, v_bca, v_today - 2, 800000,
    jsonb_build_array(jsonb_build_object('invoice_id', v_c, 'amount', 400000)), null, 'TRX-004', null, null, true, 'overpaid on purpose');
  perform test_helpers.put('pay_4', v_p4);
  select * into p from public.payments where id = v_p4;
  perform test_helpers.assert(p.allocated_amount = 400000 and p.advance_amount = 400000 and p.advance_base = 400000, 'allocated 400,000 and 400,000 kept as customer advance');
  perform test_helpers.assert((select credit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = p.journal_id and a.system_key = 'CUSTOMER_ADVANCE') = 400000
    and test_helpers.bal(pt, 'CUSTOMER_ADVANCE') = -400000, 'the advance is a liability (credit) on the customer advance account, not revenue');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after the advance');

  -- ---- applying the advance to another invoice of the same customer
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.apply_payment_credit(%L, %L, 100000, ''key-p5-cr-01'')', v_p4, v_b), 'INVALID', 'an advance cannot be applied to another customer''s invoice');
  perform test_helpers.expect_msg(format('select public.apply_payment_credit(%L, %L, 400001, ''key-p5-cr-02'')', v_p4, v_d), 'INVALID', 'more than the advance or the outstanding amount');
  perform test_helpers.expect_msg(format('select public.apply_payment_credit(%L, %L, 100000, ''key-p5-cr-03'')', v_p4, v_a), 'INVALID', 'a paid invoice takes no credit');
  perform test_helpers.expect_msg(format('select public.apply_payment_credit(%L, %L, 100000, ''key-p5-cr-04'', %L)', v_p4, v_d, v_today - 3), 'INVALID', 'the application cannot precede the payment');
  v_cred := public.apply_payment_credit(v_p4, v_d, 300000, 'key-p5-cr-05', v_today - 1);
  perform test_helpers.put('credit_1', v_cred);
  perform test_helpers.assert(public.apply_payment_credit(v_p4, v_d, 300000, 'key-p5-cr-05', v_today - 1) = v_cred, 'applying replays on the same key');
  perform test_helpers.logout();
  perform test_helpers.assert((select outstanding = 0 and settlement_status = 'paid' from test_helpers.pos(pt) where invoice_id = v_d)
    and test_helpers.adv(v_p4) = 100000, 'D is paid from the advance; 100,000 of the advance remains');
  perform test_helpers.assert(test_helpers.bal(pt, 'CUSTOMER_ADVANCE') = -100000
    and (select kind = 'credit' and advance_base_used = 300000 and fx_difference = 0 from public.payment_allocations where id = v_cred), 'the advance account falls by the applied amount; no cash moved');
  perform test_helpers.assert((select count(*) from public.money_movements where source_type = 'payment_credit') = 0, 'applying an advance creates no money movement');
  perform test_helpers.controls(pt, 'after applying the advance');

  -- ---- a personal payment: no advance account exists for a Personal Entity, so an overpayment is refused
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-40'', %L, %L, %L, 300000, %L::jsonb, null, null, null, null, true)', pe, test_helpers.g('pe_cust'), test_helpers.g('pe_bank'), v_today - 2,
    jsonb_build_array(jsonb_build_object('invoice_id', test_helpers.g('inv_pe1'), 'amount', 180000))::text), 'CONFLICT', 'a Personal Entity has no advance account: nothing is guessed');
  v_pe_pay := public.record_payment(pe, 'key-p5-py-41', test_helpers.g('pe_cust'), test_helpers.g('pe_bank'), v_today - 2, 180000,
    jsonb_build_array(jsonb_build_object('invoice_id', test_helpers.g('inv_pe1'), 'amount', 180000)));
  perform test_helpers.put('pay_pe', v_pe_pay);
  perform test_helpers.assert((select outstanding = 0 from test_helpers.pos(pe) where invoice_id = test_helpers.g('inv_pe1')), 'the personal invoice is paid');
  perform test_helpers.logout();
  perform test_helpers.controls(pe, 'personal after payment');

  -- ---- foreign currency: the difference between the invoice rate and the payment rate is booked, per part
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-fx-01'', %L, %L, %L, 400, %L::jsonb)', pt, v_alfa, v_usd, v_today - 6,
    jsonb_build_array(jsonb_build_object('invoice_id', v_u, 'amount', 400))::text), 'INVALID', 'a USD account needs a rate');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-fx-02'', %L, %L, %L, 400, %L::jsonb, 25000)', pt, v_alfa, v_usd, v_today - 6,
    jsonb_build_array(jsonb_build_object('invoice_id', v_u, 'amount', 400))::text), 'INVALID', 'an exchange difference above 20% is a typing mistake');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-fx-03'', %L, %L, %L, 400, %L::jsonb, 15200.12345678901)', pt, v_alfa, v_usd, v_today - 6,
    jsonb_build_array(jsonb_build_object('invoice_id', v_u, 'amount', 400))::text), 'INVALID', 'a rate has at most 10 decimals');
  v_pu1 := public.record_payment(pt, 'key-p5-fx-04', v_alfa, v_usd, v_today - 6, 400,
    jsonb_build_array(jsonb_build_object('invoice_id', v_u, 'amount', 400)), 15200);
  select * into p from public.payments where id = v_pu1;
  perform test_helpers.assert(p.currency = 'USD' and p.base_amount = 6080000 and p.fx_difference = 80000
    and (select base_ar_amount from public.payment_allocations where payment_id = v_pu1) = 6000000, 'USD 400 at 15,200 = 6,080,000 against 6,000,000 of receivable: a gain of 80,000');
  perform test_helpers.assert((select credit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = p.journal_id and a.system_key = 'FX_GAIN_LOSS') = 80000, 'the gain is credited to FX gain/loss');
  perform test_helpers.assert((select outstanding = 500 and base_outstanding = 7500000 from test_helpers.pos(pt) where invoice_id = v_u), 'USD 500 / 7,500,000 remain');
  v_pu2 := public.record_payment(pt, 'key-p5-fx-05', v_alfa, v_usd, v_today - 4, 500,
    jsonb_build_array(jsonb_build_object('invoice_id', v_u, 'amount', 500)), 14900);
  select * into p from public.payments where id = v_pu2;
  perform test_helpers.assert(p.base_amount = 7450000 and p.fx_difference = -50000 and (select base_ar_amount from public.payment_allocations where payment_id = v_pu2) = 7500000,
    'the last part clears exactly the remaining 7,500,000: a loss of 50,000');
  perform test_helpers.assert((select outstanding = 0 and base_outstanding = 0 and settlement_status = 'paid' from test_helpers.pos(pt) where invoice_id = v_u), 'the USD invoice is paid with nothing left over');
  perform test_helpers.put('pay_u1', v_pu1);
  perform test_helpers.put('pay_u2', v_pu2);
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after foreign-currency payments');
  perform test_helpers.assert((select movement_balance = 900 and movement_base_balance = 13530000 and ledger_balance = 13530000 from test_helpers.mc(pt) where financial_account_id = v_usd),
    'the USD account holds 900 USD carried at 13,530,000 in both the money layer and the ledger');

  -- ---- who can record a payment
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-50'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'')', pt, v_beta, v_bca, v_today - 1, v_b), 'FORBIDDEN', 'staff cannot confirm a payment');
  perform test_helpers.logout();
  perform test_helpers.login(v_viewer);
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-py-51'', %L, %L, %L, 100, ''[{"invoice_id":"%s","amount":100}]'')', pt, v_beta, v_bca, v_today - 1, v_b), 'FORBIDDEN', 'a viewer cannot confirm a payment');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. "Saya Sudah Bayar": claims, the public token surface, confirmation
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_beta uuid := test_helpers.g('beta');
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_s uuid := test_helpers.g('inv_s');
  v_b uuid := test_helpers.g('inv_b');
  v_a uuid := test_helpers.g('inv_a');
  v_tok text;
  v_tok_b text;
  v_r jsonb;
  v_c1 uuid;
  v_c1b uuid;
  v_pay uuid;
  v_ids uuid[] := '{}';
  v_sub uuid;
  v_n integer;
  v_client text := 'client-hash-aaaaaaaaaa';
  v_mov bigint;
  v_jr bigint;
  v_num text;
  v_pn1 text;
  v_pn2 text;
begin
  select invoice_number into v_num from public.invoices where id = v_s;
  select payment_number into v_pn1 from public.payments where id = test_helpers.g('pay_1');
  select token into v_tok from public.invoice_public_links where invoice_id = v_s and status = 'active';
  select token into v_tok_b from public.invoice_public_links where invoice_id = v_b and status = 'active';
  select count(*) into v_mov from public.money_movements where entity_id = pt;
  select count(*) into v_jr from public.journal_entries where entity_id = pt;

  -- ---- the anonymous role: nothing but the three token functions
  perform test_helpers.as_anon();
  perform test_helpers.expect_error('select * from public.invoices', '42501', 'anon cannot read invoices');
  perform test_helpers.expect_error('select * from public.invoice_public_links', '42501', 'anon cannot read links (tokens)');
  perform test_helpers.expect_error('select * from public.payment_submissions', '42501', 'anon cannot read claims');
  perform test_helpers.expect_error('select * from public.payments', '42501', 'anon cannot read payments');
  perform test_helpers.expect_error(format('select public.record_payment(%L, ''key-p5-an-01'', %L, %L, %L, 1, ''[]'')', pt, v_beta, v_bca, v_today), '42501', 'anon cannot record a payment');
  perform test_helpers.expect_error(format('select public.issue_invoice(%L, ''key-p5-an-02'')', v_s), '42501', 'anon cannot issue');
  perform test_helpers.expect_error(format('select public.invoice_public_link(%L)', v_s), '42501', 'anon cannot read a token through the staff function');
  perform test_helpers.expect_error(format('select public.invoice_document(%L)', v_s), '42501', 'anon cannot read the staff document function');
  perform test_helpers.expect_error('select app_private.public_link_lookup(''x'')', '42501', 'anon cannot reach the private lookup');
  v_r := public.public_invoice_view(v_tok);
  perform test_helpers.assert(v_r ->> 'state' = 'ok' and v_r -> 'invoice' ->> 'invoice_number' = v_num
    and (v_r -> 'invoice' ->> 'outstanding')::numeric = 1000000 and (v_r ->> 'can_claim')::boolean and not (v_r ->> 'pending_claim')::boolean,
    'a valid token shows the invoice, what is outstanding and that a claim can be made');
  perform test_helpers.assert(v_r::text !~* '(internal|entity_id|customer_id|journal|"id"|tax_identifier|note_to_self)' and not (v_r -> 'invoice' ? 'document'),
    'the public view carries no ids, internal notes, journal facts or tax identifiers');
  perform test_helpers.assert(public.public_invoice_view('short') ->> 'state' = 'unavailable'
    and public.public_invoice_view(repeat('A', 43)) ->> 'state' = 'unavailable'
    and public.public_invoice_view(repeat('!', 43)) ->> 'state' = 'unavailable'
    and public.public_invoice_view(null) ->> 'state' = 'unavailable'
    and public.public_invoice_view(v_tok || 'x') ->> 'state' = 'unavailable',
    'unknown, malformed, empty and altered tokens are indistinguishable');
  perform test_helpers.logout();

  -- ---- staff claim, idempotency and de-duplication
  perform test_helpers.login(v_staff);
  v_c1 := public.create_payment_claim(v_s, 'key-p5-cl-01', 200000, v_today - 1, 'Beta Buyer', 'REF-1', test_helpers.g('chan_bca'), 'sent by transfer');
  perform test_helpers.assert(public.create_payment_claim(v_s, 'key-p5-cl-01', 200000, v_today - 1, 'Beta Buyer', 'REF-1', test_helpers.g('chan_bca'), 'sent by transfer') = v_c1, 'a claim replays on the same key');
  perform test_helpers.assert(public.create_payment_claim(v_s, 'key-p5-cl-02', 200000, v_today - 1, 'Beta Buyer', 'ref-1 ') = v_c1, 'an identical pending claim (whatever the case of the reference) returns the same claim');
  perform test_helpers.expect_msg(format('select public.create_payment_claim(%L, ''key-p5-cl-03'', 1000001, %L)', v_s, v_today), 'INVALID', 'a claim above what is outstanding');
  perform test_helpers.expect_msg(format('select public.create_payment_claim(%L, ''key-p5-cl-04'', 100, %L)', v_s, v_today + 1), 'INVALID', 'a claim dated in the future');
  perform test_helpers.expect_msg(format('select public.create_payment_claim(%L, ''key-p5-cl-05'', 100, %L)', v_s, v_today - 30), 'INVALID', 'a claim before the invoice date');
  perform test_helpers.expect_msg(format('select public.create_payment_claim(%L, ''key-p5-cl-06'', 0, %L)', v_s, v_today), 'INVALID', 'a zero claim');
  perform test_helpers.expect_msg(format('select public.create_payment_claim(%L, ''key-p5-cl-07'', 100, %L)', v_a, v_today - 5), 'CONFLICT', 'a paid invoice takes no claim');
  perform test_helpers.logout();
  perform test_helpers.assert((select status = 'pending' and source = 'staff' and amount = 200000 from public.payment_submissions where id = v_c1)
    and (select count(*) from public.payment_submissions where invoice_id = v_s) = 1, 'one pending staff claim');

  -- ---- the customer's claim through the token
  perform test_helpers.as_anon();
  v_r := public.public_submit_payment_claim(v_tok, 300000, v_today - 1, 'Beta Buyer', 'PUB-1', 'paid from my phone', v_client);
  perform test_helpers.assert(v_r ->> 'state' = 'pending' and not (v_r ->> 'already_received')::boolean, 'a public claim is accepted as pending');
  v_r := public.public_submit_payment_claim(v_tok, 300000, v_today - 1, 'Beta Buyer', 'PUB-1', 'paid from my phone', v_client);
  perform test_helpers.assert((v_r ->> 'already_received')::boolean, 'pressing the button twice does not create two claims');
  perform test_helpers.assert((public.public_invoice_view(v_tok) ->> 'pending_claim')::boolean, 'the invoice page then says a claim is being verified');
  perform test_helpers.expect_msg(format('select public.public_submit_payment_claim(%L, 1000001, %L, ''x'', ''y'', ''z'', %L)', v_tok, v_today, v_client), 'INVALID', 'a claim above what is outstanding');
  perform test_helpers.expect_msg(format('select public.public_submit_payment_claim(%L, 100, %L, ''x'', ''y'', ''z'', %L)', v_tok, v_today + 2, v_client), 'INVALID', 'a future-dated claim');
  perform test_helpers.expect_msg(format('select public.public_submit_payment_claim(%L, 100, %L, ''x'', ''y'', ''z'', ''short'')', v_tok, v_today), 'INVALID', 'a request without a client fingerprint');
  perform test_helpers.expect_msg(format('select public.public_submit_payment_claim(%L, 100, %L, ''x'', ''y'', ''z'', %L)', repeat('B', 43), v_today, v_client), 'UNAVAILABLE', 'an unknown token');
  perform test_helpers.expect_msg(format('select public.public_submit_payment_claim(null, 100, %L, ''x'', ''y'', ''z'', %L)', v_today, v_client), 'UNAVAILABLE', 'a missing token');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.money_movements where entity_id = pt) = v_mov and (select count(*) from public.journal_entries where entity_id = pt) = v_jr,
    'claims have no cash and no accounting effect');
  select id into v_c1b from public.payment_submissions where invoice_id = v_s and payer_reference = 'PUB-1';
  perform test_helpers.assert((select source = 'public' and status = 'pending' and created_by is null and client_hash = v_client from public.payment_submissions where id = v_c1b), 'the public claim is stored as pending with the requester hash');
  perform test_helpers.assert(exists (select 1 from public.audit_events where target_table = 'payment_submissions' and target_id = v_c1b and actor_type = 'public_token' and action = 'payment_submissions.insert' and actor_id is not null),
    'the audit trail records that a public token created the claim');
  perform test_helpers.assert(not exists (select 1 from public.audit_events where target_table = 'payment_submissions' and (after_state::text like '%' || v_client || '%')), 'the requester hash never enters the audit trail');
  -- control characters are stripped, over-long text is refused
  perform test_helpers.as_anon();
  perform public.public_submit_payment_claim(v_tok, 1000, v_today - 1, E'Evil\x01Name\x7f', E'PUB-\x02X', 'n', 'client-hash-bbbbbbbbbb');
  perform test_helpers.expect_msg(format('select public.public_submit_payment_claim(%L, 1001, %L, %L, ''r'', ''n'', ''client-hash-bbbbbbbbbb'')', v_tok, v_today - 1, repeat('x', 201)), 'INVALID', 'an over-long name');
  perform test_helpers.logout();
  perform test_helpers.assert((select payer_name = 'EvilName' and payer_reference = 'PUB-X' from public.payment_submissions where invoice_id = v_s and amount = 1000), 'control characters are removed from public text');

  -- ---- abuse limits: at most five claims waiting per invoice
  perform test_helpers.as_anon();
  perform public.public_submit_payment_claim(v_tok, 1100, v_today - 1, 'X', 'PUB-3', 'n', 'client-hash-cccccccccc');
  perform public.public_submit_payment_claim(v_tok, 1200, v_today - 1, 'X', 'PUB-4', 'n', 'client-hash-dddddddddd');
  perform test_helpers.expect_msg(format('select public.public_submit_payment_claim(%L, 1300, %L, ''X'', ''PUB-5'', ''n'', ''client-hash-eeeeeeeeee'')', v_tok, v_today - 1), 'THROTTLED', 'a sixth waiting claim is throttled');
  perform test_helpers.logout();

  -- ---- reviewing: reject, duplicate, confirm
  perform test_helpers.login(v_admin);
  select id into v_sub from public.payment_submissions where invoice_id = v_s and payer_reference = 'PUB-4';
  perform test_helpers.expect_msg(format('select public.reject_payment_submission(%L, ''no'')', v_sub), 'INVALID', 'a rejection needs a reason');
  perform test_helpers.assert(public.reject_payment_submission(v_sub, 'No such transfer on the statement') = 'rejected', 'a claim is rejected with a reason');
  perform test_helpers.expect_msg(format('select public.reject_payment_submission(%L, ''again please'')', v_sub), 'CONFLICT', 'a reviewed claim cannot be reviewed twice');
  perform test_helpers.expect_msg(format('select public.confirm_payment_submission(%L, ''key-p5-cf-00'', %L)', v_sub, v_bca), 'CONFLICT', 'a rejected claim cannot be confirmed');
  select id into v_sub from public.payment_submissions where invoice_id = v_s and payer_reference = 'PUB-3';
  perform test_helpers.expect_msg(format('select public.mark_submission_duplicate(%L, %L, ''same transfer'')', v_sub, v_sub), 'INVALID', 'a claim cannot be its own duplicate');
  perform test_helpers.expect_msg(format('select public.mark_submission_duplicate(%L, %L, ''same transfer'')', v_sub, gen_random_uuid()), 'INVALID', 'the other claim must exist on the same invoice');
  perform test_helpers.assert(public.mark_submission_duplicate(v_sub, v_c1b, 'Same transfer as PUB-1') = 'duplicate', 'a claim is marked as a duplicate of another');
  perform test_helpers.assert((select status = 'duplicate' and duplicate_of = v_c1b from public.payment_submissions where id = v_sub), 'the duplicate keeps the pointer');

  -- confirming needs a receiving account (the invoice names none)
  perform test_helpers.expect_msg(format('select public.confirm_payment_submission(%L, ''key-p5-cf-01'')', v_c1), 'INVALID', 'the reviewer must say which account received the money');
  perform test_helpers.expect_msg(format('select public.confirm_payment_submission(%L, ''key-p5-cf-02'', %L, %L, 300000)', v_c1, v_bca, v_today + 1), 'INVALID', 'a confirmation date in the future');
  v_pay := public.confirm_payment_submission(v_c1, 'key-p5-cf-03', v_bca, null, 200000);
  perform test_helpers.put('pay_s1', v_pay);
  perform test_helpers.assert(public.confirm_payment_submission(v_c1, 'key-p5-cf-03', v_bca, null, 200000) = v_pay, 'confirming replays on the same key');
  perform test_helpers.expect_msg(format('select public.confirm_payment_submission(%L, ''key-p5-cf-04'', %L)', v_c1, v_bca), 'CONFLICT', 'a claim is confirmed once');
  perform test_helpers.logout();
  perform test_helpers.assert((select status = 'confirmed' and payment_id = v_pay and reviewed_by = v_admin from public.payment_submissions where id = v_c1)
    and (select submission_id = v_c1 and amount = 200000 and payment_date = v_today - 1 and reference = 'REF-1' and payer_name = 'Beta Buyer' from public.payments where id = v_pay)
    and (select outstanding = 800000 and settlement_status = 'partial' from test_helpers.pos(pt) where invoice_id = v_s), 'the confirmed claim became one real payment allocated to the invoice');
  perform test_helpers.controls(pt, 'after confirming a claim');

  -- the reviewer confirms what was actually received, not what was claimed; an over-amount needs the explicit advance choice
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.confirm_payment_submission(%L, ''key-p5-cf-05'', %L, null, 900000)', v_c1b, v_bca), 'INVALID', 'received more than the invoice needs: the advance must be explicit');
  v_pay := public.confirm_payment_submission(v_c1b, 'key-p5-cf-06', v_bca, null, 250000, null, false, 'customer rounded down');
  perform test_helpers.assert((select amount = 250000 and allocated_amount = 250000 and note = 'customer rounded down' from public.payments where id = v_pay)
    and (select outstanding = 550000 from test_helpers.pos(pt) where invoice_id = v_s), 'confirmed for the amount actually received (250,000, not the 300,000 claimed)');
  perform test_helpers.put('pay_s2', v_pay);
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after the second claim');

  -- ---- the public receipt: only what a payer may see, only for payments on this invoice
  select payment_number into v_pn2 from public.payments where id = v_pay;
  perform test_helpers.as_anon();
  v_r := public.public_receipt_view(v_tok, v_pn2);
  perform test_helpers.assert(v_r ->> 'state' = 'ok' and v_r -> 'receipt' ->> 'amount' is not null and not (v_r -> 'receipt' ? 'payer_name') and not (v_r -> 'receipt' ? 'advance_amount')
    and v_r::text !~* '(account_number|ACC-SECRET|entity_id|journal)', 'the public receipt shows the payment without payer details, advance or account numbers');
  perform test_helpers.assert(public.public_receipt_view(v_tok, v_pn1) ->> 'state' = 'unavailable'
    and public.public_receipt_view(v_tok, 'RCP-NOPE') ->> 'state' = 'unavailable'
    and public.public_receipt_view(v_tok_b, v_pn2) ->> 'state' = 'unavailable'
    and public.public_receipt_view(v_tok, null) ->> 'state' = 'unavailable', 'a receipt of another invoice, an unknown number or the wrong token show nothing');
  v_r := public.public_invoice_view(v_tok);
  perform test_helpers.assert(jsonb_array_length(v_r -> 'invoice' -> 'payments') = 2 and (v_r -> 'invoice' ->> 'outstanding')::numeric = 550000, 'the public invoice lists the receipts and the new outstanding amount');
  perform test_helpers.logout();

  -- ---- per-requester limit: eight claims an hour from one client, whatever the invoice
  perform test_helpers.as_anon();
  for v_n in 1 .. 8 loop
    perform public.public_submit_payment_claim(v_tok_b, 1000 + v_n, v_today - 1, 'Bot', 'BOT-' || v_n, 'n', 'client-hash-throttle-1');
    perform test_helpers.logout();
    perform test_helpers.login(v_admin);
    perform public.reject_payment_submission((select id from public.payment_submissions where invoice_id = v_b and payer_reference = 'BOT-' || v_n), 'Spam');
    perform test_helpers.logout();
    perform test_helpers.as_anon();
  end loop;
  perform test_helpers.expect_msg(format('select public.public_submit_payment_claim(%L, 2000, %L, ''Bot'', ''BOT-9'', ''n'', ''client-hash-throttle-1'')', v_tok_b, v_today - 1), 'THROTTLED', 'the ninth request of one requester in an hour is throttled');
  v_r := public.public_submit_payment_claim(v_tok_b, 2000, v_today - 1, 'Human', 'HUM-1', 'n', 'client-hash-throttle-2');
  perform test_helpers.assert(v_r ->> 'state' = 'pending', 'another requester is unaffected');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 7. approval rule and reversals
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_alfa uuid := test_helpers.g('alfa');
  v_beta uuid := test_helpers.g('beta');
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_usd uuid := test_helpers.g('usd');
  v_s uuid := test_helpers.g('inv_s');
  v_d uuid := test_helpers.g('inv_d');
  v_u uuid := test_helpers.g('inv_u');
  v_cred uuid := test_helpers.g('credit_1');
  v_pu2 uuid := test_helpers.g('pay_u2');
  v_p4 uuid := test_helpers.g('pay_4');
  v_claim uuid;
  v_pay uuid;
  v_v1 uuid;
  v_v2 uuid;
  v_pv uuid;
  v_cred2 uuid;
  v_rev uuid;
  v_bal_before numeric;
  p public.payments%rowtype;
  v_adv_before numeric;
begin
  -- ---- maker-checker (Step 06 §7): the person who created the claim may not confirm it; the OWNER may
  insert into public.approval_rules (entity_id, module, action, min_amount, requires_approval, allow_self_approval, effective_from)
  values (pt, 'payments', 'confirm', 0, true, false, v_today - 30);
  perform test_helpers.login(v_admin);
  v_claim := public.create_payment_claim(v_s, 'key-p5-mc-01', 5000, v_today - 1, 'Beta', 'MC-1');
  perform test_helpers.expect_msg(format('select public.confirm_payment_submission(%L, ''key-p5-mc-02'', %L)', v_claim, v_bca), 'FORBIDDEN', 'the creator of a claim cannot confirm it under an approval rule');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-mc-03'', %L, %L, %L, 5000, %L::jsonb)', pt, v_beta, v_bca, v_today - 1,
    jsonb_build_array(jsonb_build_object('invoice_id', v_s, 'amount', 5000))::text), 'FORBIDDEN', 'recording a payment is the same act as confirming it');
  perform test_helpers.assert(not exists (select 1 from public.payments where reference = 'MC-1'), 'the refused confirmations booked nothing');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.confirm_payment_submission(v_claim, 'key-p5-mc-04', v_bca) is not null, 'the OWNER may act on any event');
  perform test_helpers.logout();
  delete from public.approval_rules where entity_id = pt;
  perform test_helpers.controls(pt, 'after the approval rule');

  -- ---- reversing a payment that has a credit application: the application goes first, then the payment
  perform test_helpers.login(v_admin);
  v_v1 := public.create_invoice_draft(pt, 'key-p5-rv-01', v_alfa, v_today - 3, v_today + 30, '[{"description":"Reversal V1","unit_price":300000}]');
  v_v2 := public.create_invoice_draft(pt, 'key-p5-rv-02', v_alfa, v_today - 3, v_today + 30, '[{"description":"Reversal V2","unit_price":150000}]');
  perform public.issue_invoice(v_v1, 'key-p5-rv-03');
  perform public.issue_invoice(v_v2, 'key-p5-rv-04');
  perform test_helpers.put('inv_v1', v_v1);
  perform test_helpers.put('inv_v2', v_v2);
  v_pv := public.record_payment(pt, 'key-p5-rv-05', v_alfa, v_bca, v_today - 2, 500000, jsonb_build_array(jsonb_build_object('invoice_id', v_v1, 'amount', 300000)), null, 'RV-1', null, null, true);
  v_cred2 := public.apply_payment_credit(v_pv, v_v2, 150000, 'key-p5-rv-06', v_today - 1);
  perform test_helpers.assert((select outstanding from test_helpers.pos(pt) where invoice_id = v_v1) = 0 and (select outstanding from test_helpers.pos(pt) where invoice_id = v_v2) = 0
    and test_helpers.adv(v_pv) = 50000, 'V1 paid, V2 paid from the advance, 50,000 of advance left');
  perform test_helpers.expect_msg(format('select public.reverse_payment(%L, ''key-p5-rv-07'', %L, ''bad'')', v_pv, v_today), 'INVALID', 'a reversal needs a reason of at least 5 characters');
  perform test_helpers.expect_msg(format('select public.reverse_payment(%L, ''key-p5-rv-08'', %L, ''Wrong customer paid'')', v_pv, v_today + 1), 'INVALID', 'a reversal cannot be dated in the future');
  perform test_helpers.expect_msg(format('select public.reverse_payment(%L, ''key-p5-rv-09'', %L, ''Wrong customer paid'')', v_pv, v_today - 3), 'INVALID', 'a reversal cannot precede the payment');
  select movement_balance into v_bal_before from test_helpers.mc(pt) where financial_account_id = v_bca;
  v_rev := public.reverse_payment(v_pv, 'key-p5-rv-10', v_today, 'Wrong customer paid');
  perform test_helpers.assert(public.reverse_payment(v_pv, 'key-p5-rv-10', v_today, 'Wrong customer paid') = v_rev, 'reversing replays on the same key');
  perform test_helpers.expect_msg(format('select public.reverse_payment(%L, ''key-p5-rv-11'', %L, ''Wrong customer paid'')', v_pv, v_today), 'CONFLICT', 'a payment is reversed once');
  perform test_helpers.expect_msg(format('select public.apply_payment_credit(%L, %L, 1000, ''key-p5-rv-12'')', v_pv, v_v2), 'CONFLICT', 'a reversed payment cannot be applied');
  perform test_helpers.expect_msg(format('select public.reverse_credit_application(%L, ''key-p5-rv-13'', %L, ''Already gone via payment'')', v_cred2, v_today), 'CONFLICT', 'the application went with the payment');
  perform test_helpers.logout();
  select * into p from public.payments where id = v_pv;
  perform test_helpers.assert(p.status = 'reversed' and p.reversal_journal_id is not null and p.reverse_reason = 'Wrong customer paid' and p.reversed_by = v_admin and p.reversed_date = v_today,
    'the payment is marked reversed with who, when and why; nothing was deleted');
  perform test_helpers.assert((select outstanding = 300000 from test_helpers.pos(pt) where invoice_id = v_v1) and (select outstanding = 150000 from test_helpers.pos(pt) where invoice_id = v_v2)
    and (select status = 'reversed' from public.payment_allocations where id = v_cred2)
    and (select bool_and(status = 'reversed') from public.payment_allocations where payment_id = v_pv), 'both invoices are open again and every allocation is reversed');
  perform test_helpers.assert(v_bal_before - (select movement_balance from test_helpers.mc(pt) where financial_account_id = v_bca) = 500000
    and (select count(*) from public.money_movements where source_type = 'payment' and source_id = v_pv) = 2, 'the bank balance falls by 500,000 through a reversing movement (the original stays)');
  perform test_helpers.assert(test_helpers.bal(pt, 'CUSTOMER_ADVANCE') = -100000, 'the advance ledger is back to the remaining 100,000 of the other payment');
  perform test_helpers.controls(pt, 'after reversing a payment with a credit application');

  -- ---- reversing a credit application alone gives the advance back and reopens the invoice
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.reverse_credit_application(%L, ''key-p5-cr-10'', %L, ''nope'')', v_cred, v_today), 'INVALID', 'a reason of at least 5 characters');
  perform test_helpers.expect_msg(format('select public.reverse_credit_application(%L, ''key-p5-cr-11'', %L, ''Applied to the wrong invoice'')', test_helpers.g('pay_1'), v_today), 'FORBIDDEN', 'only a credit application can be reversed this way');
  v_adv_before := test_helpers.adv(v_p4);
  perform public.reverse_credit_application(v_cred, 'key-p5-cr-12', v_today, 'Applied to the wrong invoice');
  perform test_helpers.assert((select outstanding = 300000 from test_helpers.pos(pt) where invoice_id = v_d)
    and test_helpers.adv(v_p4) = v_adv_before + 300000 and test_helpers.bal(pt, 'CUSTOMER_ADVANCE') = -400000, 'D is open again and the advance is 400,000 again');
  perform test_helpers.controls(pt, 'after reversing a credit application');
  perform test_helpers.expect_msg(format('select public.reverse_credit_application(%L, ''key-p5-cr-13'', %L, ''Applied to the wrong invoice'')', v_cred, v_today), 'CONFLICT', 'reversed once');
  v_cred := public.apply_payment_credit(v_p4, v_d, 300000, 'key-p5-cr-14', v_today - 1);
  perform test_helpers.put('credit_1', v_cred);
  perform test_helpers.assert((select outstanding = 0 from test_helpers.pos(pt) where invoice_id = v_d), 'the advance can be applied again to the right invoice');
  perform test_helpers.logout();

  -- ---- reversing a foreign-currency payment restores the receivable at the ORIGINAL base value, and re-paying can differ
  perform test_helpers.login(v_admin);
  perform public.reverse_payment(v_pu2, 'key-p5-fxr-01', v_today - 3, 'Bank returned the transfer');
  perform test_helpers.assert((select outstanding = 500 and base_outstanding = 7500000 and settlement_status = 'partial' from test_helpers.pos(pt) where invoice_id = v_u)
    and (select movement_balance = 400 and movement_base_balance = 6080000 and ledger_balance = 6080000 from test_helpers.mc(pt) where financial_account_id = v_usd),
    'USD 500 / 7,500,000 is receivable again; the USD account holds 400 USD at 6,080,000 in both layers');
  perform test_helpers.controls(pt, 'after reversing the USD payment');
  v_pay := public.record_payment(pt, 'key-p5-fxr-02', v_alfa, v_usd, v_today - 3, 500, jsonb_build_array(jsonb_build_object('invoice_id', v_u, 'amount', 500)), 15000);
  perform test_helpers.assert((select fx_difference = 0 from public.payments where id = v_pay) and (select outstanding = 0 and base_outstanding = 0 from test_helpers.pos(pt) where invoice_id = v_u), 're-paying at the invoice rate leaves no exchange difference');
  perform test_helpers.put('pay_u2', v_pay);
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after re-paying in USD');

  -- ---- who may reverse
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select public.reverse_payment(%L, ''key-p5-rv-20'', %L, ''Staff cannot do this'')', test_helpers.g('pay_1'), v_today), 'FORBIDDEN', 'staff cannot reverse a payment');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 8. cancel, void, correct and the public link
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_alfa uuid := test_helpers.g('alfa');
  v_today date := test_helpers.today(pt);
  v_s uuid := test_helpers.g('inv_s');
  v_x1 uuid;
  v_x2 uuid;
  v_x3 uuid;
  v_x3b uuid;
  v_claim uuid;
  v_tok text;
  v_tok2 text;
  v_jrev uuid;
  i public.invoices%rowtype;
  v_ar_before numeric;
  v_j uuid;
begin
  perform test_helpers.login(v_admin);
  v_x1 := public.create_invoice_draft(pt, 'key-p5-cx-01', v_alfa, v_today - 1, v_today + 10, '[{"description":"Cancel me","unit_price":50000}]');
  v_x2 := public.create_invoice_draft(pt, 'key-p5-cx-02', v_alfa, v_today - 1, v_today + 10, '[{"description":"Void me","unit_price":60000}]');
  v_x3 := public.create_invoice_draft(pt, 'key-p5-cx-03', v_alfa, v_today - 1, v_today + 10,
    '[{"description":"Wrong quantity","quantity":2,"unit_price":70000},{"description":"Second line","unit_price":10000,"discount_type":"percent","discount_value":50}]', null, null, 'Customer note', 'Net 10', 'Pay soon', 'internal only');
  perform public.issue_invoice(v_x1, 'key-p5-cx-04');
  perform public.issue_invoice(v_x2, 'key-p5-cx-05');
  perform public.issue_invoice(v_x3, 'key-p5-cx-06');
  select token into v_tok from public.invoice_public_link(v_x1);
  perform test_helpers.logout();
  v_ar_before := test_helpers.bal(pt, 'ACCOUNTS_RECEIVABLE');

  -- a pending claim exists on X1; cancelling closes it
  perform test_helpers.login(v_staff);
  v_claim := public.create_payment_claim(v_x1, 'key-p5-cx-07', 1000, v_today, 'Someone', 'CX-1');
  perform test_helpers.expect_msg(format('select public.cancel_invoice(%L, ''key-p5-cx-08'', ''Staff may only cancel drafts'')', v_x1), 'FORBIDDEN', 'staff cannot cancel an issued invoice');
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-cx-09'', ''Staff may not void anything'')', v_x1), 'FORBIDDEN', 'staff cannot void');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-cx-10'', ''Finance admin has no void right'')', v_x2), 'FORBIDDEN', 'a finance admin cannot void (invoices.void is an owner-level right)');
  perform test_helpers.logout();

  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.cancel_invoice(%L, ''key-p5-cx-11'', ''no'')', v_x1), 'INVALID', 'a reason of at least 5 characters');
  perform test_helpers.expect_msg(format('select public.cancel_invoice(%L, ''key-p5-cx-12'', ''Issued by mistake'', %L)', v_x1, v_today + 1), 'INVALID', 'a closing date in the future');
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-cx-13'', ''Sold to the wrong party'')', v_s), 'CONFLICT', 'an invoice with active payments cannot be voided until they are reversed');
  perform test_helpers.assert(public.cancel_invoice(v_x1, 'key-p5-cx-14', 'Issued by mistake') = v_x1, 'an issued invoice is cancelled');
  perform test_helpers.assert(public.cancel_invoice(v_x1, 'key-p5-cx-14', 'Issued by mistake') = v_x1, 'cancelling replays on the same key');
  perform test_helpers.expect_msg(format('select public.cancel_invoice(%L, ''key-p5-cx-15'', ''Issued by mistake twice'')', v_x1), 'CONFLICT', 'a closed invoice cannot be closed again');
  perform test_helpers.logout();
  select * into i from public.invoices where id = v_x1;
  perform test_helpers.assert(i.status = 'cancelled' and i.closed_reason = 'Issued by mistake' and i.closed_by = v_owner and i.closed_date = v_today and i.reversal_journal_id is not null
    and i.invoice_number is not null, 'cancelled: reason, who, when and the reversal journal are kept; the number stays used');
  perform test_helpers.assert((select reverses_journal_id = i.journal_id and status = 'posted' from public.journal_entries where id = i.reversal_journal_id), 'the reversal journal is linked to the issuing journal');
  perform test_helpers.assert((select status = 'rejected' and review_reason like '%cancelled%' from public.payment_submissions where id = v_claim), 'the pending claim was closed with the invoice');
  perform test_helpers.assert((select status = 'revoked' from public.invoice_public_links where invoice_id = v_x1), 'the public link is revoked');
  perform test_helpers.as_anon();
  perform test_helpers.assert(public.public_invoice_view(v_tok) ->> 'state' = 'unavailable', 'the customer link no longer shows a cancelled invoice');
  perform test_helpers.expect_msg(format('select public.public_submit_payment_claim(%L, 100, %L, ''x'', ''y'', ''z'', ''client-hash-ffffffffff'')', v_tok, v_today), 'UNAVAILABLE', 'nor accepts a claim');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format('update public.invoices set notes = ''x'' where id = %L', v_x1), null, 'a cancelled invoice is frozen');
  perform test_helpers.expect_error(format('update public.invoices set status = ''issued'' where id = %L', v_x1), null, 'a cancelled invoice never reopens');
  perform test_helpers.assert((select outstanding = 0 and status = 'cancelled' from test_helpers.pos(pt) where invoice_id = v_x1)
    and (select outstanding = 50000 and status = 'issued' from test_helpers.pos(pt, v_today - 1) where invoice_id = v_x1), 'positions are time-aware: outstanding yesterday, nothing today');
  perform test_helpers.controls(pt, 'after cancelling');

  -- void (same accounting; the wording differs) and its permanence
  perform test_helpers.login(v_owner);
  perform public.void_invoice(v_x2, 'key-p5-cx-20', 'Duplicate of another invoice');
  perform test_helpers.assert((select status = 'void' and closed_reason = 'Duplicate of another invoice' from public.invoices where id = v_x2), 'voided with its reason');
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-cx-21'', ''Voiding twice over'')', v_x2), 'CONFLICT', 'a void invoice cannot be voided again');
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-cx-22'', ''A draft cannot be voided'')', (select id from public.invoices where entity_id = pt and status = 'cancelled' limit 1)), 'CONFLICT', 'a cancelled invoice cannot be voided');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after voiding');

  -- correction by replacement
  perform test_helpers.login(v_owner);
  v_x3b := public.correct_invoice(v_x3, 'key-p5-cx-30', 'The quantity was 3, not 2');
  perform test_helpers.assert(public.correct_invoice(v_x3, 'key-p5-cx-30', 'The quantity was 3, not 2') = v_x3b, 'correcting replays on the same key');
  perform test_helpers.expect_msg(format('select public.correct_invoice(%L, ''key-p5-cx-31'', ''Correcting the voided one again'')', v_x3), 'CONFLICT', 'a voided invoice cannot be corrected again');
  perform test_helpers.logout();
  select * into i from public.invoices where id = v_x3;
  perform test_helpers.assert(i.status = 'void' and i.replaced_by_invoice_id = v_x3b and i.reversal_journal_id is not null, 'the original is void and points to its replacement');
  select * into i from public.invoices where id = v_x3b;
  perform test_helpers.assert(i.status = 'draft' and i.replaces_invoice_id = v_x3 and i.invoice_number is null and i.total = 145000 and i.notes = 'Customer note' and i.terms = 'Net 10'
    and i.internal_note like 'Replaces %: The quantity was 3, not 2' and (select count(*) from public.invoice_lines where invoice_id = v_x3b) = 2, 'the replacement is a draft copy with the same lines and notes and a link back');
  perform test_helpers.login(v_owner);
  perform public.update_invoice_draft(v_x3b, '{"lines":[{"description":"Wrong quantity","quantity":3,"unit_price":70000},{"description":"Second line","unit_price":10000,"discount_type":"percent","discount_value":50}]}');
  perform public.issue_invoice(v_x3b, 'key-p5-cx-32');
  perform test_helpers.assert((select total = 215000 and invoice_number is not null and invoice_number <> (select invoice_number from public.invoices where id = v_x3) from public.invoices where id = v_x3b), 'the corrected invoice is issued under a new number');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after correcting');

  -- ---- the public link: regenerate, expiry, revoke
  perform test_helpers.login(v_admin);
  select token into v_tok from public.invoice_public_link(v_s);
  v_tok2 := public.regenerate_invoice_link(v_s, 'key-p5-ln-01');
  perform test_helpers.assert(public.regenerate_invoice_link(v_s, 'key-p5-ln-01') = v_tok2 and v_tok2 <> v_tok and length(v_tok2) >= 43, 'a new unguessable token; replaying the key returns the same one');
  perform test_helpers.assert((select token from public.invoice_public_link(v_s)) = v_tok2 and (select count(*) from public.invoice_public_links where invoice_id = v_s and status = 'active') = 1, 'exactly one active link');
  perform test_helpers.expect_msg(format('select public.regenerate_invoice_link(%L, ''key-p5-ln-02'', now() - interval ''1 day'')', v_s), 'INVALID', 'an expiry in the past');
  perform test_helpers.expect_msg(format('select public.regenerate_invoice_link(%L, ''key-p5-ln-03'')', v_x3), 'CONFLICT', 'a void invoice has no link');
  perform test_helpers.logout();
  perform test_helpers.as_anon();
  perform test_helpers.assert(public.public_invoice_view(v_tok) ->> 'state' = 'unavailable' and public.public_invoice_view(v_tok2) ->> 'state' = 'ok', 'the old link is dead, the new one works');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform public.set_invoice_link_expiry(v_s, now() + interval '2 days');
  perform test_helpers.expect_msg(format('select public.set_invoice_link_expiry(%L, now() + interval ''6 years'')', v_s), 'INVALID', 'an expiry beyond five years');
  perform test_helpers.logout();
  update public.invoice_public_links set expires_at = now() - interval '1 second' where invoice_id = v_s and status = 'active';
  perform test_helpers.as_anon();
  perform test_helpers.assert(public.public_invoice_view(v_tok2) ->> 'state' = 'unavailable', 'an expired link shows nothing');
  perform test_helpers.logout();
  update public.invoice_public_links set expires_at = null where invoice_id = v_s and status = 'active';
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.revoke_invoice_link(%L, ''x'')', v_s), 'INVALID', 'a reason is required');
  perform test_helpers.assert(public.revoke_invoice_link(v_s, 'Link was shared by mistake') = 'revoked' and public.revoke_invoice_link(v_s, 'Link was shared by mistake') = 'no_active_link', 'a link is revoked; revoking again is a no-op');
  perform test_helpers.assert(public.regenerate_invoice_link(v_s, 'key-p5-ln-04') <> v_tok2, 'a fresh link can be issued after a revoke');
  perform test_helpers.logout();
  perform test_helpers.expect_error(format('update public.invoice_public_links set token = repeat(''z'', 43) where invoice_id = %L and status = ''active''', v_s), null, 'a token can never be rewritten');
  perform test_helpers.expect_error(format('update public.invoice_public_links set status = ''active'' where invoice_id = %L and status = ''revoked''', v_s), null, 'a revoked link stays revoked');
  perform test_helpers.assert(not exists (select 1 from public.audit_events where target_table = 'invoice_public_links' and (after_state ? 'token' or before_state ? 'token')), 'tokens never enter the audit trail');
end
$$;

-- ================================================================ 9. refunds: from an allocation, from the advance, in USD
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  pe uuid := test_helpers.entity('p5_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_approver uuid := 'c0000000-0000-0000-0000-000000000003';
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_cash uuid := test_helpers.g('cash');
  v_usd uuid := test_helpers.g('usd');
  v_a uuid := test_helpers.g('inv_a');
  v_p1 uuid := test_helpers.g('pay_1');
  v_p4 uuid := test_helpers.g('pay_4');
  v_pu1 uuid := test_helpers.g('pay_u1');
  v_al1 uuid;
  v_alc uuid;
  v_alcred uuid;
  v_alu uuid;
  v_r1 uuid;
  v_r2 uuid;
  v_r3 uuid;
  v_r4 uuid;
  v_bal numeric;
  v_rev uuid;
  r public.refunds%rowtype;
  v_j uuid;
begin
  select id into v_al1 from public.payment_allocations where payment_id = v_p1 and kind = 'payment';
  select id into v_alc from public.payment_allocations where payment_id = v_p4 and kind = 'payment';
  select id into v_alcred from public.payment_allocations where payment_id = v_p4 and kind = 'credit' and status = 'active';
  select id into v_alu from public.payment_allocations where payment_id = v_pu1;

  -- ---- who may refund
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-01'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 1000))::text), 'FORBIDDEN', 'a finance admin cannot create a refund');
  perform test_helpers.assert((select count(*) from public.payment_refund_options(v_p1)) = 1, 'a finance admin can see what is refundable (refunds.view)');
  perform test_helpers.logout();
  perform test_helpers.login(v_approver);
  perform test_helpers.expect_msg(format('select public.confirm_refund(%L, ''key-p5-rf-02'')', gen_random_uuid()), 'FORBIDDEN', 'an approver cannot confirm what does not exist for them (same answer as no right)');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select * from public.payment_refund_options(%L)', v_p1), 'FORBIDDEN', 'staff cannot even see refund options');
  perform test_helpers.logout();

  -- ---- refusals
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-10'', %L, %L, %L::jsonb, null, ''  '')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 1000))::text), 'INVALID', 'a reason is required');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-11'', %L, %L, ''[]'', null, ''Goodwill'')', v_p1, v_bca, v_today), 'INVALID', 'a refund needs items');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-12'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_bca, v_today + 1,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 1000))::text), 'INVALID', 'a refund cannot be dated in the future');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-13'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_bca, v_today - 9,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 1000))::text), 'INVALID', 'a refund cannot precede the payment');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-14'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_usd, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 1000))::text), 'INVALID', 'the paying-out account must be in the payment currency');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-15'', %L, %L, %L::jsonb, 15000, ''Goodwill'')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 1000))::text), 'INVALID', 'an IDR refund takes no rate');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-16'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_alc, 'amount', 1000))::text), 'INVALID', 'an allocation of another payment');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-17'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 500), jsonb_build_object('allocation_id', v_al1, 'amount', 500))::text), 'INVALID', 'an allocation appears once');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-18'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('source', 'advance', 'amount', 500))::text), 'INVALID', 'this payment has no advance to refund');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-19'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 800001))::text), 'INVALID', 'more than the allocation');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-1a'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 0))::text), 'INVALID', 'a zero item');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-1b'', %L, %L, %L::jsonb, null, ''Goodwill'')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 10.001))::text), 'INVALID', 'too many decimals');
  perform test_helpers.assert(not exists (select 1 from public.refunds where entity_id = pt), 'refused refunds leave nothing behind');

  -- ---- a draft books nothing; confirmation books once
  v_r1 := public.create_refund(v_p1, 'key-p5-rf-20', v_bca, v_today, jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 200000)), null, 'Customer returned part of the order', 'Partial return', 'RF-REF-1');
  perform test_helpers.assert(public.create_refund(v_p1, 'key-p5-rf-20', v_bca, v_today, jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 200000)), null, 'Customer returned part of the order', 'Partial return', 'RF-REF-1') = v_r1, 'a refund draft replays on the same key');
  perform test_helpers.assert((select status = 'draft' and refund_number is null and journal_id is null from public.refunds where id = v_r1)
    and not exists (select 1 from public.money_movements where source_type = 'refund' and source_id = v_r1), 'a draft refund books nothing');
  select movement_balance into v_bal from test_helpers.mc(pt) where financial_account_id = v_bca;
  perform test_helpers.assert(public.confirm_refund(v_r1, 'key-p5-rf-21') = v_r1 and public.confirm_refund(v_r1, 'key-p5-rf-21') = v_r1, 'confirming replays on the same key');
  perform test_helpers.expect_msg(format('select public.confirm_refund(%L, ''key-p5-rf-22'')', v_r1), 'CONFLICT', 'a refund is confirmed once');
  perform test_helpers.logout();
  select * into r from public.refunds where id = v_r1;
  perform test_helpers.assert(r.status = 'confirmed' and r.refund_number like 'RFD%' and r.amount = 200000 and r.base_amount = 200000 and r.confirmed_by = v_owner and r.journal_id is not null
    and r.receipt_snapshot ? 'issuer', 'confirmed: numbered, base value stored, receipt facts frozen');
  perform test_helpers.assert((select debit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = r.journal_id and a.system_key = 'SALES_CONTRA') = 200000
    and (select credit from public.journal_lines l where l.journal_id = r.journal_id and l.ledger_account_id = (select ledger_account_id from public.financial_accounts where id = v_bca)) = 200000,
    'Dr sales refunds/discounts 200,000 / Cr bank 200,000 - not an expense and not a deleted payment');
  perform test_helpers.assert(v_bal - (select movement_balance from test_helpers.mc(pt) where financial_account_id = v_bca) = 200000
    and (select direction = 'out' and amount = 200000 from public.money_movements where source_type = 'refund' and source_id = v_r1), 'the bank balance falls by exactly 200,000 through one outgoing movement');
  perform test_helpers.assert((select settlement_status = 'paid' and refund_status = 'partial' and refunded = 200000 and settled = 1970000 from test_helpers.pos(pt) where invoice_id = v_a),
    'the invoice stays paid; its refund status is partial (both derived)');
  perform test_helpers.controls(pt, 'after the first refund');
end
$$;

do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  pe uuid := test_helpers.entity('p5_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_today date := test_helpers.today(pt);
  v_bca uuid := test_helpers.g('bca');
  v_usd uuid := test_helpers.g('usd');
  v_a uuid := test_helpers.g('inv_a');
  v_c uuid := test_helpers.g('inv_c');
  v_d uuid := test_helpers.g('inv_d');
  v_p1 uuid := test_helpers.g('pay_1');
  v_p4 uuid := test_helpers.g('pay_4');
  v_pu1 uuid := test_helpers.g('pay_u1');
  v_al1 uuid;
  v_alc uuid;
  v_alcred uuid;
  v_alu uuid;
  v_r1 uuid;
  v_r2 uuid;
  v_r3 uuid;
  v_r4 uuid;
  v_rev uuid;
  v_bal numeric;
  v_usd_bal numeric;
  r public.refunds%rowtype;
  v_doc jsonb;
begin
  select id into v_al1 from public.payment_allocations where payment_id = v_p1 and kind = 'payment';
  select id into v_alc from public.payment_allocations where payment_id = v_p4 and kind = 'payment';
  select id into v_alcred from public.payment_allocations where payment_id = v_p4 and kind = 'credit' and status = 'active';
  select id into v_alu from public.payment_allocations where payment_id = v_pu1;
  select id into v_r1 from public.refunds where payment_id = v_p1;

  perform test_helpers.login(v_owner);
  -- ---- the refundable amount can never be exceeded, even by two drafts made before either is confirmed
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-30'', %L, %L, %L::jsonb, null, ''Too much'', null, null, true)', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 600001))::text), 'INVALID', 'more than the 600,000 still refundable is refused');
  perform test_helpers.assert((select count(*) from public.refunds where payment_id = v_p1) = 1, 'and leaves no draft behind');
  v_r2 := public.create_refund(v_p1, 'key-p5-rf-31', v_bca, v_today, jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 400000)), null, 'Second return');
  v_r3 := public.create_refund(v_p1, 'key-p5-rf-32', v_bca, v_today, jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 400000)), null, 'Same goods again');
  perform test_helpers.assert(public.confirm_refund(v_r2, 'key-p5-rf-33') = v_r2, 'the first draft confirms');
  perform test_helpers.expect_msg(format('select public.confirm_refund(%L, ''key-p5-rf-34'')', v_r3), 'INVALID', 'the second draft can no longer be confirmed: only 200,000 remains');
  perform test_helpers.assert((select status from public.refunds where id = v_r3) = 'draft', 'and stays a draft');
  perform test_helpers.expect_msg(format('select public.reject_refund(%L, ''x'')', v_r3), 'INVALID', 'a rejection needs a reason');
  perform test_helpers.assert(public.reject_refund(v_r3, 'Duplicate of the previous refund') = 'rejected', 'a draft is rejected');
  perform test_helpers.expect_msg(format('select public.confirm_refund(%L, ''key-p5-rf-35'')', v_r3), 'CONFLICT', 'a rejected refund cannot be confirmed');
  perform test_helpers.expect_msg(format('select public.cancel_refund(%L, ''Already rejected'')', v_r3), 'CONFLICT', 'nor cancelled');
  v_r4 := public.create_refund(v_p1, 'key-p5-rf-36', v_bca, v_today, jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 200000)), null, 'Final return');
  perform test_helpers.assert(public.cancel_refund(v_r4, 'Changed my mind') = 'cancelled', 'a draft is cancelled');
  perform test_helpers.expect_msg(format('select public.reject_refund(%L, ''Already cancelled'')', v_r4), 'CONFLICT', 'a cancelled refund cannot be rejected');
  perform test_helpers.assert(public.create_refund(v_p1, 'key-p5-rf-37', v_bca, v_today, jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 200000)), null, 'Final return', null, null, true) is not null, 'the last 200,000 is refunded in one step (create and confirm)');
  perform test_helpers.assert((select refund_status = 'full' and refundable::numeric = 0 and refunded::numeric = 800000 from public.list_payments(pt) where payment_id = v_p1), 'the payment is fully refunded');
  perform test_helpers.assert((select refund_status = 'partial' from test_helpers.pos(pt) where invoice_id = v_a), 'A: 800,000 of 1,970,000 settled is refunded');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-rf-38'', %L, %L, %L::jsonb, null, ''One too many'')', v_p1, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_al1, 'amount', 1))::text), 'INVALID', 'nothing is left to refund');
  perform test_helpers.expect_msg(format('select public.reverse_payment(%L, ''key-p5-rf-39'', %L, ''Refunded payments cannot be reversed'')', v_p1, v_today), 'CONFLICT', 'a payment with confirmed refunds cannot be reversed');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after refunding a whole payment');

  -- ---- frozen after confirmation
  perform test_helpers.expect_error(format('update public.refunds set amount = 1 where id = %L', v_r1), null, 'a confirmed refund is frozen');
  perform test_helpers.expect_error(format('update public.refund_items set amount = 1 where refund_id = %L', v_r1), null, 'its items are frozen');
  perform test_helpers.expect_error(format('delete from public.refund_items where refund_id = %L', v_r1), null, 'items are never deleted');
  perform test_helpers.expect_error(format('delete from public.refunds where id = %L', v_r1), null, 'refunds are never deleted');
  perform test_helpers.expect_error(format('insert into public.refund_items (entity_id, refund_id, allocation_id, amount) values (%L, %L, %L, 1)', pt, v_r1, v_al1), null, 'items cannot be added to a confirmed refund');

  -- ---- reversing a refund makes the amount refundable again
  perform test_helpers.login(v_owner);
  select movement_balance into v_bal from test_helpers.mc(pt) where financial_account_id = v_bca;
  perform test_helpers.expect_msg(format('select public.reverse_refund(%L, ''key-p5-rr-01'', %L, ''no'')', v_r2, v_today), 'INVALID', 'a reason of at least 5 characters');
  perform test_helpers.expect_msg(format('select public.reverse_refund(%L, ''key-p5-rr-02'', %L, ''Bank returned the payout'')', v_r3, v_today), 'CONFLICT', 'a draft/rejected refund cannot be reversed');
  v_rev := public.reverse_refund(v_r2, 'key-p5-rr-03', v_today, 'Bank returned the payout');
  perform test_helpers.assert(public.reverse_refund(v_r2, 'key-p5-rr-03', v_today, 'Bank returned the payout') = v_rev, 'reversing a refund replays on the same key');
  perform test_helpers.expect_msg(format('select public.reverse_refund(%L, ''key-p5-rr-04'', %L, ''Bank returned the payout'')', v_r2, v_today), 'CONFLICT', 'reversed once');
  perform test_helpers.assert((select status = 'reversed' and reversal_journal_id = v_rev from public.refunds where id = v_r2)
    and (select movement_balance from test_helpers.mc(pt) where financial_account_id = v_bca) - v_bal = 400000
    and (select refundable::numeric = 400000 and refund_status = 'partial' from public.list_payments(pt) where payment_id = v_p1), 'the money is back in the bank and 400,000 is refundable again');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after reversing a refund');

  -- ---- the customer advance: refunded alone, or together with an allocation in one refund
  perform test_helpers.login(v_owner);
  perform test_helpers.assert((select count(*) from public.payment_refund_options(v_p4)) = 3
    and (select refundable::numeric from public.payment_refund_options(v_p4) where source = 'advance') = 100000, 'the options of the advance payment: an allocation, a credit application and 100,000 of advance');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-ad-01'', %L, %L, %L::jsonb, null, ''Too much advance'')', v_p4, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('source', 'advance', 'amount', 100001))::text), 'INVALID', 'more than the advance that is left');
  v_r4 := public.create_refund(v_p4, 'key-p5-ad-02', v_bca, v_today, jsonb_build_array(jsonb_build_object('source', 'advance', 'amount', 100000), jsonb_build_object('allocation_id', v_alc, 'amount', 50000)),
    null, 'Advance and part of C returned', null, null, true);
  select * into r from public.refunds where id = v_r4;
  perform test_helpers.assert(r.amount = 150000 and (select count(*) from public.refund_items where refund_id = v_r4) = 2 and (select base_amount from public.refund_items where refund_id = v_r4 and allocation_id is null) = 100000, 'one refund with two items');
  perform test_helpers.assert((select debit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = r.journal_id and a.system_key = 'CUSTOMER_ADVANCE') = 100000
    and (select debit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = r.journal_id and a.system_key = 'SALES_CONTRA') = 50000
    , 'a combined refund debits the advance and the contra account in one journal');
  perform test_helpers.assert(test_helpers.adv(v_p4) = 0, 'the advance is used up (applied 300,000, refunded 100,000)');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after refunding an advance');
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-ad-03'', %L, %L, %L::jsonb, null, ''Advance again'')', v_p4, v_bca, v_today,
    jsonb_build_array(jsonb_build_object('source', 'advance', 'amount', 1))::text), 'INVALID', 'the advance cannot be refunded twice');

  -- ---- a refund made from a credit application blocks reversing the application (and the payment)
  perform public.create_refund(v_p4, 'key-p5-ad-04', v_bca, v_today, jsonb_build_array(jsonb_build_object('allocation_id', v_alcred, 'amount', 50000)), null, 'Part of D returned', null, null, true);
  perform test_helpers.expect_msg(format('select public.reverse_credit_application(%L, ''key-p5-ad-05'', %L, ''Would orphan the refund'')', v_alcred, v_today), 'CONFLICT', 'the application has a refund');
  perform test_helpers.expect_msg(format('select public.reverse_payment(%L, ''key-p5-ad-06'', %L, ''Would orphan the refund'')', v_p4, v_today), 'CONFLICT', 'the payment has refunds');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after refunding a credit application');

  -- ---- foreign currency: the refund is paid at today's rate; the difference to the booked receivable is an exchange result
  perform test_helpers.login(v_owner);
  select movement_balance into v_usd_bal from test_helpers.mc(pt) where financial_account_id = v_usd;
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-fx-10'', %L, %L, %L::jsonb, null, ''No rate given'')', v_pu1, v_usd, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_alu, 'amount', 100))::text), 'INVALID', 'a USD refund needs a rate');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-fx-11'', %L, %L, %L::jsonb, 30000, ''Absurd rate'', null, null, true)', v_pu1, v_usd, v_today,
    jsonb_build_array(jsonb_build_object('allocation_id', v_alu, 'amount', 100))::text), 'INVALID', 'an exchange difference above 20% is a typing mistake');
  v_r4 := public.create_refund(v_pu1, 'key-p5-fx-12', v_usd, v_today, jsonb_build_array(jsonb_build_object('allocation_id', v_alu, 'amount', 100)), 15500, 'Partial USD return', null, null, true);
  select * into r from public.refunds where id = v_r4;
  perform test_helpers.assert(r.base_amount = 1550000 and (select base_amount from public.refund_items where refund_id = v_r4) = 1500000, 'USD 100 paid out at 15,500 = 1,550,000 against 1,500,000 of the original receivable');
  perform test_helpers.assert((select debit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = r.journal_id and a.system_key = 'FX_GAIN_LOSS') = 50000
    and (select debit from public.journal_lines l join public.ledger_accounts a on a.id = l.ledger_account_id where l.journal_id = r.journal_id and a.system_key = 'SALES_CONTRA') = 1500000, 'the 50,000 rate difference is an FX loss; the sale is reduced by the original 1,500,000');
  perform test_helpers.assert(v_usd_bal - (select movement_balance from test_helpers.mc(pt) where financial_account_id = v_usd) = 100, 'the USD account pays out 100 USD');
  perform test_helpers.assert((select refundable::numeric = 300 from public.payment_refund_options(v_pu1) where allocation_id = v_alu), 'USD 300 remain refundable (and 4,500,000 of receivable value)');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after a USD refund');

  -- ---- receipts (frozen facts, no account numbers)
  perform test_helpers.login(v_admin);
  v_doc := public.refund_receipt_document(v_r4);
  perform test_helpers.assert(v_doc ->> 'document' = 'refund_receipt' and v_doc ->> 'refund_number' like 'RFD%' and (v_doc ->> 'amount')::numeric = 100 and v_doc ->> 'currency' = 'USD'
    and (v_doc ->> 'cumulative_refunded')::numeric = 100 and (v_doc ->> 'remaining_refundable')::numeric = 300, 'the refund receipt carries the cumulative and remaining amounts');
  perform test_helpers.assert(v_doc::text !~* '(ACC-SECRET|internal|journal|entity_id)', 'and no account number, internal note or ledger fact');
  v_doc := public.payment_receipt_document(v_p1);
  perform test_helpers.assert(v_doc ->> 'document' = 'payment_receipt' and (v_doc ->> 'refunded')::numeric = 400000 and v_doc::text !~* 'ACC-SECRET', 'the payment receipt shows what was refunded and masks the account');
  perform test_helpers.expect_msg(format('select public.refund_receipt_document(%L)', (select id from public.refunds where status = 'rejected' limit 1)), 'CONFLICT', 'a rejected refund has no receipt');
  perform test_helpers.logout();

  -- ---- Personal Entity refund goes to the personal income account
  perform test_helpers.login(v_owner);
  perform public.create_refund(test_helpers.g('pay_pe'), 'key-p5-pe-01', test_helpers.g('pe_bank'), v_today, jsonb_build_array(jsonb_build_object('allocation_id', (select id from public.payment_allocations where payment_id = test_helpers.g('pay_pe')), 'amount', 30000)), null, 'Personal refund', null, null, true);
  perform test_helpers.assert(test_helpers.bal(pe, 'OTHER_PERSONAL_INCOME') = -150000, 'personal income is reduced by the refund');
  perform test_helpers.logout();
  perform test_helpers.controls(pe, 'personal after refund');
end
$$;

-- ================================================================ 10. positions, aging, controls over time, numbering
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_today date := test_helpers.today(pt);
  v_alfa uuid := test_helpers.g('alfa');
  v_beta uuid := test_helpers.g('beta');
  v_b uuid := test_helpers.g('inv_b');
  d date;
  v_n integer;
  v_min integer;
  v_max integer;
begin
  perform test_helpers.login(v_admin);
  -- filters
  perform test_helpers.assert((select count(*) from public.list_invoice_positions(pt, 'overdue')) = 1 and (select invoice_id from public.list_invoice_positions(pt, 'overdue')) = v_b
    and (select days_overdue from public.list_invoice_positions(pt, 'overdue')) = 40, 'one overdue invoice: B, 40 days');
  perform test_helpers.assert((select count(*) from public.list_invoice_positions(pt, 'open')) = 5, 'five open invoices (B, S, V1, V2 and the corrected X3)');
  perform test_helpers.assert((select count(*) from public.list_invoice_positions(pt, 'closed')) = 3, 'three closed invoices (cancelled X1, void X2 and X3)');
  perform test_helpers.assert((select count(*) from public.list_invoice_positions(pt, 'partial')) = 1 and (select count(*) from public.list_invoice_positions(pt, 'unpaid')) = 4, 'one partly paid, four unpaid');
  perform test_helpers.assert((select bool_and(settlement_status = 'paid') from public.list_invoice_positions(pt, 'paid')) and (select count(*) from public.list_invoice_positions(pt, 'paid')) = 4, 'four paid invoices (A, C, D, U)');
  perform test_helpers.assert((select count(*) from public.list_invoice_positions(pt, null, v_beta)) = 2 and (select count(*) from public.list_invoice_positions(pt, null, v_alfa)) >= 8, 'filtering by customer');
  perform test_helpers.expect_msg(format('select * from public.list_invoice_positions(%L, ''everything'')', pt), 'INVALID', 'an unknown filter');
  -- aging (base currency, by customer)
  perform test_helpers.assert((select not_due::numeric = 545000 and days_31_60::numeric = 500000 and total::numeric = 1045000 and invoice_count = 2 from public.ar_aging(pt) where customer_id = v_beta), 'Beta: S is not due, B is 40 days late (31-60)');
  perform test_helpers.assert((select not_due::numeric = 665000 and total::numeric = 665000 and invoice_count = 3 from public.ar_aging(pt) where customer_id = v_alfa), 'Alfa: three invoices not yet due');
  perform test_helpers.assert((select days_61_90::numeric = 500000 and days_31_60::numeric = 545000 from public.ar_aging(pt, v_today + 50) where customer_id = v_beta), 'as of 50 days ahead the same invoices age into the next buckets');
  perform test_helpers.assert((select sum(total::numeric) from public.ar_aging(pt)) = (select sub_ledger::numeric from public.ar_control_report(pt)), 'the aging total equals the receivable on the books');
  perform test_helpers.assert((select difference::numeric = 0 and advance_difference::numeric = 0 and ledger_total::numeric = ledger_sales::numeric and other_ledger::numeric = 0 from public.ar_control_report(pt)), 'AR and advance control: no difference');
  perform test_helpers.logout();

  -- the control holds at every date of the last 70 days, not only today (reversals count from their own date)
  for d in select generate_series(v_today - 70, v_today, interval '1 day')::date loop
    perform 1 from test_helpers.arc(pt, d) c where c.sub_ledger <> c.ledger_sales or c.advance_sub_ledger <> c.advance_ledger_sales;
    if found then
      raise exception 'TEST FAIL [time-travel control]: the sales sub-ledger differs from the ledger as of %', d;
    end if;
  end loop;

  -- numbering is gapless and a cancelled or void invoice keeps its number
  select count(*), min(regexp_replace(invoice_number, '^.*?(\d+)$', '\1')::integer), max(regexp_replace(invoice_number, '^.*?(\d+)$', '\1')::integer)
    into v_n, v_min, v_max from public.invoices where entity_id = pt and invoice_number is not null;
  perform test_helpers.assert(v_n = v_max - v_min + 1 and v_min = 1, 'invoice numbers run 1..n without gaps (cancelled and void ones included)');
  select count(*), min(regexp_replace(payment_number, '^.*?(\d+)$', '\1')::integer), max(regexp_replace(payment_number, '^.*?(\d+)$', '\1')::integer)
    into v_n, v_min, v_max from public.payments where entity_id = pt;
  perform test_helpers.assert(v_n = v_max - v_min + 1 and v_min = 1, 'receipt numbers run without gaps (reversed ones included)');
  select count(*), min(regexp_replace(refund_number, '^.*?(\d+)$', '\1')::integer), max(regexp_replace(refund_number, '^.*?(\d+)$', '\1')::integer)
    into v_n, v_min, v_max from public.refunds where entity_id = pt and refund_number is not null;
  perform test_helpers.assert(v_n = v_max - v_min + 1 and v_min = 1, 'refund numbers run without gaps; drafts have none');
  perform test_helpers.assert((select count(distinct payment_number) from public.payments where entity_id = pt) = (select count(*) from public.payments where entity_id = pt), 'no receipt number is used twice');

  -- outbox and audit trail
  perform test_helpers.assert((select count(distinct event_type) from public.outbox_events where entity_id = pt
      and event_type in ('InvoiceIssued', 'PaymentConfirmed', 'RefundConfirmed', 'PaymentSubmitted', 'InvoiceCancelled', 'InvoiceVoided')) = 6, 'every business event has an outbox record');
  perform test_helpers.assert(exists (select 1 from public.audit_events where target_table = 'payments' and reason = 'Wrong customer paid' and action = 'payments.update')
    and exists (select 1 from public.audit_events where target_table = 'refunds' and reason = 'Bank returned the payout')
    and exists (select 1 from public.audit_events where target_table = 'invoices' and reason = 'Issued by mistake'), 'reversals and closings are audited with their reasons');
end
$$;

-- ================================================================ 11. periods: closing, closed periods, close checks
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_acct uuid := 'c0000000-0000-0000-0000-000000000006';
  v_today date := test_helpers.today(pt);
  v_alfa uuid := test_helpers.g('alfa');
  v_bca uuid := test_helpers.g('bca');
  v_old date := (date_trunc('month', test_helpers.today(pt)) - interval '2 months')::date + 4;
  v_oi uuid;
  v_oi2 uuid;
  v_oi3 uuid;
  v_pay uuid;
  v_period uuid;
  v_cur uuid;
  v_prev uuid;
begin
  -- close checks of the current month: drafts and pending claims are warnings, never blockers
  select id into v_cur from public.accounting_periods where entity_id = pt and v_today between period_start and period_end;
  select id into v_prev from public.accounting_periods where entity_id = pt and (v_today - 1) between period_start and period_end;
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_cur) where code = 'draft_invoices' and severity = 'warning' and item_count >= 2), 'draft invoices in the period are a warning');
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_prev) where code = 'pending_payment_claims' and severity = 'warning' and item_count >= 2), 'payment claims waiting for verification are a warning');
  perform test_helpers.assert(not exists (select 1 from public.period_close_checks(v_cur) where code in ('ar_ledger_mismatch', 'advance_ledger_mismatch', 'money_ledger_mismatch') or severity = 'blocker'), 'no blocker: the sales layer reconciles with the ledger');
  perform test_helpers.logout();

  -- invoices and a payment in an old period, then close it
  perform test_helpers.login(v_admin);
  v_oi := public.create_invoice_draft(pt, 'key-p5-pc-01', v_alfa, v_old, v_old + 30, '[{"description":"Old period sale","unit_price":100000}]');
  v_oi2 := public.create_invoice_draft(pt, 'key-p5-pc-02', v_alfa, v_old, v_old + 30, '[{"description":"Old period sale, unpaid","unit_price":70000}]');
  v_oi3 := public.create_invoice_draft(pt, 'key-p5-pc-03', v_alfa, v_old, v_old + 30, '[{"description":"Old period draft","unit_price":10}]');
  perform public.issue_invoice(v_oi, 'key-p5-pc-04');
  perform public.issue_invoice(v_oi2, 'key-p5-pc-05');
  v_pay := public.record_payment(pt, 'key-p5-pc-06', v_alfa, v_bca, v_old + 1, 100000, jsonb_build_array(jsonb_build_object('invoice_id', v_oi, 'amount', 100000)));
  perform test_helpers.logout();
  select id into v_period from public.accounting_periods where entity_id = pt and v_old between period_start and period_end;
  perform test_helpers.login(v_acct);
  perform test_helpers.assert(exists (select 1 from public.period_close_checks(v_period) where code = 'draft_invoices'), 'the old period warns about the draft');
  perform public.begin_period_close(v_period);
  perform test_helpers.assert(public.close_period(v_period) = 'closed', 'the period closes: warnings do not block');
  perform test_helpers.logout();

  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-pc-10'')', v_oi3), 'CONFLICT', 'a draft dated in a closed period cannot be issued');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-pc-11'', %L, %L, %L, 10, %L::jsonb)', pt, v_alfa, v_bca, v_old + 2,
    jsonb_build_array(jsonb_build_object('invoice_id', v_oi2, 'amount', 10))::text), 'CONFLICT', 'a payment cannot be dated in a closed period');
  perform test_helpers.expect_msg(format('select public.reverse_payment(%L, ''key-p5-pc-12'', %L, ''Wrong customer, closed month'')', v_pay, v_old + 3), 'CONFLICT', 'a payment cannot be reversed with a date in a closed period');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-pc-13'', ''Voiding inside a closed month'', %L)', v_oi2, v_old + 5), 'CONFLICT', 'a void cannot be dated in a closed period');
  perform public.void_invoice(v_oi2, 'key-p5-pc-14', 'Voided with a current date', v_today);
  perform test_helpers.assert((select status = 'void' and closed_date = v_today from public.invoices where id = v_oi2)
    and (select entry_date = v_today from public.journal_entries where id = (select reversal_journal_id from public.invoices where id = v_oi2)), 'a later void reverses on the current date; the closed month is untouched');
  perform public.reverse_payment(v_pay, 'key-p5-pc-15', v_today, 'Wrong customer, found next month');
  perform test_helpers.assert((select status = 'reversed' and reversed_date = v_today from public.payments where id = v_pay), 'a payment of a closed month is reversed with a current date');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after closing a period');
  -- as of the end of the closed period the books still show what they showed when it closed
  perform test_helpers.assert((select sub_ledger = ledger_sales from test_helpers.arc(pt, (select period_end from public.accounting_periods where id = v_period))), 'the closed period still reconciles as of its end date');
end
$$;

-- ================================================================ 12. authorization, Entity isolation and privileges
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  pe uuid := test_helpers.entity('p5_pe');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_viewer uuid := 'c0000000-0000-0000-0000-000000000004';
  v_nobody uuid := 'c0000000-0000-0000-0000-000000000007';
  v_pe_admin uuid := 'c0000000-0000-0000-0000-000000000009';
  v_acct uuid := 'c0000000-0000-0000-0000-000000000006';
  v_today date := test_helpers.today(pt);
  v_alfa uuid := test_helpers.g('alfa');
  v_a uuid := test_helpers.g('inv_a');
  v_s uuid := test_helpers.g('inv_s');
  v_p1 uuid := test_helpers.g('pay_1');
  v_pe1 uuid := test_helpers.g('inv_pe1');
  v_pe_cust uuid := test_helpers.g('pe_cust');
  v_pe_bank uuid := test_helpers.g('pe_bank');
  v_n_all bigint;
  t text;
begin
  -- ---- a viewer / auditor reads sales data but not refunds, tokens or requester hashes
  perform test_helpers.login(v_viewer);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.invoices') > 10 and test_helpers.rows('select 1 from public.invoice_lines') > 10
    and test_helpers.rows('select 1 from public.payments') > 5 and test_helpers.rows('select 1 from public.payment_allocations') > 5
    and test_helpers.rows('select 1 from public.payment_submissions') > 3, 'a viewer sees invoices, payments, allocations and claims');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.refunds') = 0 and test_helpers.rows('select 1 from public.refund_items') = 0, 'but no refunds (refunds.view is separate)');
  perform test_helpers.expect_error('select token from public.invoice_public_links', '42501', 'the token column is not selectable');
  perform test_helpers.expect_error('select client_hash from public.payment_submissions', '42501', 'the requester hash is not selectable');
  perform test_helpers.assert(test_helpers.rows('select id, status, expires_at from public.invoice_public_links') > 0, 'the link status is visible without its token');
  perform test_helpers.assert((select count(*) from public.list_invoice_positions(pt)) > 10 and (select count(*) from public.ar_aging(pt)) = 2, 'a viewer reads positions and aging');
  perform test_helpers.expect_msg(format('select * from public.invoice_public_link(%L)', v_s), 'FORBIDDEN', 'a viewer cannot read the link: a token is a bearer secret, readable only with invoices.regenerate_link');
  perform test_helpers.expect_msg(format('select * from public.payment_refund_options(%L)', v_p1), 'FORBIDDEN', 'but not refund options');
  perform test_helpers.expect_msg(format('select public.create_payment_claim(%L, ''key-p5-au-01'', 100, %L)', v_s, v_today), 'FORBIDDEN', 'nor create claims');
  perform test_helpers.expect_msg(format('select public.regenerate_invoice_link(%L, ''key-p5-au-02'')', v_s), 'FORBIDDEN', 'nor regenerate links');
  perform test_helpers.logout();

  -- ---- an accountant sees the sales layer for closing but changes nothing in it
  perform test_helpers.login(v_acct);
  perform test_helpers.assert((select count(*) from public.list_invoice_positions(pt)) > 10 and (select difference::numeric from public.ar_control_report(pt)) = 0, 'an accountant reads the AR control');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-au-03'', %L, %L, %L, 1, ''[]'', null, null, null, null, true)', pt, v_alfa, test_helpers.g('bca'), v_today), 'FORBIDDEN', 'an accountant cannot record a payment');
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-au-04'')', v_s), 'FORBIDDEN', 'nor issue an invoice');
  perform test_helpers.logout();

  -- ---- a stranger sees and does nothing, and learns nothing about what exists
  perform test_helpers.login(v_nobody);
  foreach t in array array['invoices', 'invoice_lines', 'invoice_public_links', 'payments', 'payment_allocations', 'payment_submissions', 'refunds', 'refund_items'] loop
    perform test_helpers.assert(test_helpers.rows(format('select 1 from public.%I', t)) = 0, format('a stranger sees no rows of %s', t));
  end loop;
  perform test_helpers.expect_msg(format('select * from public.list_invoice_positions(%L)', pt), 'FORBIDDEN', 'positions');
  perform test_helpers.expect_msg(format('select * from public.ar_aging(%L)', pt), 'FORBIDDEN', 'aging');
  perform test_helpers.expect_msg(format('select * from public.ar_control_report(%L)', pt), 'FORBIDDEN', 'AR control');
  perform test_helpers.expect_msg(format('select * from public.list_payments(%L)', pt), 'FORBIDDEN', 'payments');
  perform test_helpers.expect_msg(format('select public.invoice_document(%L)', v_a), 'FORBIDDEN', 'the invoice document');
  perform test_helpers.expect_msg(format('select public.payment_receipt_document(%L)', v_p1), 'FORBIDDEN', 'the receipt document');
  perform test_helpers.expect_msg(format('select * from public.invoice_public_link(%L)', v_a), 'FORBIDDEN', 'the public link');
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-au-05'', ''Not allowed at all'')', v_s), 'FORBIDDEN', 'void');
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-au-06'', ''Not allowed at all'')', gen_random_uuid()), 'FORBIDDEN', 'the same answer for an id that does not exist');
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-au-11'')', gen_random_uuid()), 'FORBIDDEN', 'issuing an id that does not exist answers like an id that exists (no existence leak)');
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-au-12'')', v_s), 'FORBIDDEN', 'issuing an existing invoice gives the same answer');
  perform test_helpers.expect_msg(format('select public.reverse_payment(%L, ''key-p5-au-07'', %L, ''Not allowed at all'')', v_p1, v_today), 'FORBIDDEN', 'reverse a payment');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-au-08'', %L, %L, ''[]'', null, ''nope nope'')', v_p1, test_helpers.g('bca'), v_today), 'FORBIDDEN', 'refund');
  perform test_helpers.expect_msg(format('select public.confirm_payment_submission(%L, ''key-p5-au-09'')', (select id from public.payment_submissions limit 1)), 'FORBIDDEN', 'confirm a claim');
  perform test_helpers.logout();
  perform test_helpers.expect_msg('select public.issue_invoice(gen_random_uuid(), ''key-p5-au-10'')', 'UNAUTHENTICATED', 'no session at all');

  -- ---- the other Entity: a user of the Personal Entity cannot reach the company's sales data
  perform test_helpers.login(v_pe_admin);
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.invoices where entity_id = %L', pt)) = 0 and test_helpers.rows(format('select 1 from public.invoices where entity_id = %L', pe)) = 1, 'sees only the Personal invoices');
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.payments where entity_id = %L', pt)) = 0 and test_helpers.rows(format('select 1 from public.refunds where entity_id = %L', pt)) = 0, 'and no company payments or refunds');
  perform test_helpers.expect_msg(format('select * from public.list_invoice_positions(%L)', pt), 'FORBIDDEN', 'positions of the company');
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-xe-01'')', v_a), 'FORBIDDEN', 'issuing a company invoice');
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-xe-02'', %L, %L, %L, ''[{"description":"x","unit_price":1}]'')', pe, v_alfa, v_today, v_today), 'INVALID', 'a company customer cannot be invoiced from the Personal Entity');
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-xe-03'', %L, %L, %L, 100, %L::jsonb)', pe, v_pe_cust, v_pe_bank, v_today,
    jsonb_build_array(jsonb_build_object('invoice_id', v_a, 'amount', 100))::text), 'INVALID', 'a company invoice cannot be paid through the Personal Entity');
  perform test_helpers.expect_msg(format('select public.apply_payment_credit(%L, %L, 1, ''key-p5-xe-04'')', test_helpers.g('pay_4'), v_pe1), 'FORBIDDEN', 'a company payment cannot be applied');
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-xe-05'', %L, %L, ''[]'', null, ''cross entity'')', v_p1, v_pe_bank, v_today), 'FORBIDDEN', 'a company payment cannot be refunded');
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-xe-06'', ''Cross entity void'')', v_a), 'FORBIDDEN', 'a company invoice cannot be voided');
  perform test_helpers.expect_msg(format('select public.regenerate_invoice_link(%L, ''key-p5-xe-07'')', v_s), 'FORBIDDEN', 'a company link cannot be regenerated');
  perform test_helpers.expect_msg(format('select public.create_contact(%L, ''key-p5-xe-08'', ''customer'', ''X'')', pt), 'FORBIDDEN', 'a company contact cannot be created');
  perform test_helpers.logout();

  -- ---- browser roles have no direct write access to any P5 table
  perform test_helpers.login(v_owner);
  foreach t in array array['invoices', 'invoice_lines', 'invoice_public_links', 'payments', 'payment_allocations', 'payment_submissions', 'refunds', 'refund_items'] loop
    perform test_helpers.expect_error(format('insert into public.%I select * from public.%I limit 1', t, t), '42501', format('the OWNER cannot insert into %s directly', t));
    perform test_helpers.expect_error(format('update public.%I set version = version', t), '42501', format('nor update %s', t));
    perform test_helpers.expect_error(format('delete from public.%I', t), '42501', format('nor delete from %s', t));
    perform test_helpers.expect_error(format('truncate public.%I', t), '42501', format('nor truncate %s', t));
  end loop;
  perform test_helpers.logout();
  foreach t in array array['invoices', 'invoice_lines', 'invoice_public_links', 'payments', 'payment_allocations', 'payment_submissions', 'refunds', 'refund_items'] loop
    perform test_helpers.expect_error(format('truncate public.%I', t), null, format('nobody truncates %s, not even a superuser', t));
  end loop;
end
$$;

-- ================================================================ 13. the sales control catches a broken book
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  v_acct uuid := 'c0000000-0000-0000-0000-000000000006';
  v_today date := test_helpers.today(pt);
  v_j uuid;
  v_cur uuid;
  v_seen boolean := false;
begin
  select id into v_cur from public.accounting_periods where entity_id = pt and v_today between period_start and period_end;
  begin
    -- a journal that claims to come from an invoice but moves the receivable without any invoice behind it
    v_j := test_helpers.draft_journal(pt, v_today, 'system');
    perform test_helpers.add_line(v_j, test_helpers.acct(pt, 'ACCOUNTS_RECEIVABLE'), 777, 0);
    perform test_helpers.add_line(v_j, test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE'), 0, 777);
    update public.journal_entries set source_type = 'invoice' where id = v_j;
    perform test_helpers.post(v_j);
    perform test_helpers.login(v_acct);
    v_seen := exists (select 1 from public.period_close_checks(v_cur) where code = 'ar_ledger_mismatch' and severity = 'blocker');
    perform test_helpers.assert(v_seen, 'an AR movement the invoices do not explain is a close blocker');
    perform test_helpers.assert((select difference::numeric from public.ar_control_report(pt)) = 777, 'the AR control report shows the 777 difference');
    perform public.begin_period_close(v_cur);
    perform test_helpers.expect_msg(format('select public.close_period(%L)', v_cur), 'CONFLICT', 'the period cannot close while receivables do not reconcile');
    perform test_helpers.logout();
    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then
      raise;
    end if;
    perform test_helpers.logout();
  end;
  perform test_helpers.controls(pt, 'the probe was rolled back');

  -- a journal from another source moves the ledger but not the sales control: shown separately, never a blocker
  begin
    v_j := test_helpers.simple_journal(pt, v_today, test_helpers.acct(pt, 'ACCOUNTS_RECEIVABLE'), test_helpers.acct(pt, 'OTHER_OPERATING_REVENUE'), 555, 'system');
    perform test_helpers.login(v_acct);
    perform test_helpers.assert((select difference::numeric = 0 and other_ledger::numeric = 555 from public.ar_control_report(pt)), 'foreign postings on the receivable account appear as "other", not as a difference');
    perform test_helpers.assert(not exists (select 1 from public.period_close_checks(v_cur) where code = 'ar_ledger_mismatch'), 'and do not block the close');
    perform test_helpers.logout();
    raise exception 'ROLLBACK_PROBE';
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then
      raise;
    end if;
    perform test_helpers.logout();
  end;
end
$$;

-- ================================================================ 14. hardening found by the independent review
do $$
declare
  pt uuid := test_helpers.entity('p5_pt');
  v_owner uuid := 'c0000000-0000-0000-0000-000000000001';
  v_admin uuid := 'c0000000-0000-0000-0000-000000000002';
  v_staff uuid := 'c0000000-0000-0000-0000-000000000008';
  v_today date := test_helpers.today(pt);
  v_alfa uuid := test_helpers.g('alfa');
  v_bca uuid := test_helpers.g('bca');
  v_usd uuid := test_helpers.g('usd');
  v_big uuid;
  v_small uuid;
  v_pay uuid;
  v_i1 uuid;
  v_i2 uuid;
  v_i3 uuid;
  v_prod uuid;
  v_new uuid;
  v_adv_pay uuid;
  v_alloc uuid;
  v_tok text;
  v_num1 text;
  v_num2 text;
  v_pn text;
  v_receipt jsonb;
  v_rev uuid;
begin
  -- ---- an approval threshold is a threshold in the BASE currency: 1,000 USD at 15,000 is 15,000,000 rupiah
  insert into public.approval_rules (entity_id, module, action, min_amount, requires_approval, allow_self_approval, effective_from)
  values (pt, 'invoices', 'issue', 10000000, true, false, v_today - 30),
         (pt, 'payments', 'confirm', 10000000, true, false, v_today - 30);
  perform test_helpers.login(v_admin);
  v_big := public.create_invoice_draft(pt, 'key-p5-hd-01', v_alfa, v_today - 1, v_today + 20, '[{"description":"USD big","unit_price":1000}]', 'USD', 15000, null, null, null, null, v_usd);
  v_small := public.create_invoice_draft(pt, 'key-p5-hd-02', v_alfa, v_today - 1, v_today + 20, '[{"description":"USD small","unit_price":500}]', 'USD', 15000, null, null, null, null, v_usd);
  perform test_helpers.expect_msg(format('select public.issue_invoice(%L, ''key-p5-hd-03'')', v_big), 'FORBIDDEN', 'a 1,000 USD invoice is over the 10,000,000 threshold, so the creator cannot issue it');
  perform public.issue_invoice(v_small, 'key-p5-hd-04');
  perform test_helpers.assert((select status = 'issued' from public.invoices where id = v_small), '500 USD (7,500,000) is under the threshold and issues');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform public.issue_invoice(v_big, 'key-p5-hd-05');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.record_payment(%L, ''key-p5-hd-06'', %L, %L, %L, 1000, %L::jsonb, 15000)', pt, v_alfa, v_usd, v_today,
    jsonb_build_array(jsonb_build_object('invoice_id', v_big, 'amount', 1000))::text), 'FORBIDDEN', 'the same threshold applies to a USD payment');
  perform test_helpers.logout();
  delete from public.approval_rules where entity_id = pt;

  -- ---- a due date must be a real business date
  perform test_helpers.login(v_admin);
  perform test_helpers.expect_msg(format('select public.create_invoice_draft(%L, ''key-p5-hd-07'', %L, %L, date ''9999-12-31'', ''[{"description":"x","unit_price":1}]'')', pt, v_alfa, v_today),
    'INVALID', 'a due date in the year 9999 is refused');
  -- a very small percentage discount on a very large price is computed exactly
  v_i1 := public.create_invoice_draft(pt, 'key-p5-hd-08', v_alfa, v_today - 6, v_today + 20,
    '[{"description":"Large","unit_price":"1000000000","discount_type":"percent","discount_value":"0.01"}]');
  perform test_helpers.assert((select total = 999900000 from public.invoices where id = v_i1), '0.01% of 1,000,000,000 is exactly 100,000');
  perform test_helpers.logout();

  -- ---- a link token is a bearer secret: only who may regenerate links can read it
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_msg(format('select * from public.invoice_public_link(%L)', v_small), 'FORBIDDEN', 'finance staff cannot read a token');
  perform test_helpers.logout();
  perform test_helpers.login(v_admin);
  perform test_helpers.assert((select token from public.invoice_public_link(v_small)) is not null, 'a finance admin can');
  perform test_helpers.logout();

  -- ---- a public receipt shows only the allocation to the invoice behind the token
  perform test_helpers.login(v_admin);
  v_i2 := public.create_invoice_draft(pt, 'key-p5-hd-10', v_alfa, v_today - 5, v_today + 20, '[{"description":"Receipt A","unit_price":100000}]');
  v_i3 := public.create_invoice_draft(pt, 'key-p5-hd-11', v_alfa, v_today - 5, v_today + 20, '[{"description":"Receipt B (another job)","unit_price":250000}]');
  perform public.issue_invoice(v_i2, 'key-p5-hd-12');
  perform public.issue_invoice(v_i3, 'key-p5-hd-13');
  v_pay := public.record_payment(pt, 'key-p5-hd-14', v_alfa, v_bca, v_today - 4, 350000,
    jsonb_build_array(jsonb_build_object('invoice_id', v_i2, 'amount', 100000), jsonb_build_object('invoice_id', v_i3, 'amount', 250000)));
  perform test_helpers.logout();
  select invoice_number into v_num1 from public.invoices where id = v_i2;
  select invoice_number into v_num2 from public.invoices where id = v_i3;
  select token into v_tok from public.invoice_public_links where invoice_id = v_i2 and status = 'active';
  select payment_number into v_pn from public.payments where id = v_pay;
  perform test_helpers.as_anon();
  v_receipt := public.public_receipt_view(v_tok, v_pn);
  perform test_helpers.logout();
  perform test_helpers.assert(v_receipt ->> 'state' = 'ok' and jsonb_array_length(v_receipt -> 'receipt' -> 'allocations') = 1
    and v_receipt -> 'receipt' -> 'allocations' -> 0 ->> 'invoice_number' = v_num1 and position(v_num2 in v_receipt::text) = 0,
    'the receipt behind invoice A lists only invoice A, never the other invoice the customer paid');

  -- ---- a refund cannot be dated before the allocation it refunds
  perform test_helpers.login(v_admin);
  v_adv_pay := public.record_payment(pt, 'key-p5-hd-20', v_alfa, v_bca, v_today - 6, 300000, '[]', null, 'HD-ADV', null, null, true);
  v_i1 := public.create_invoice_draft(pt, 'key-p5-hd-21', v_alfa, v_today - 5, v_today + 20, '[{"description":"Credit target","unit_price":100000}]');
  perform public.issue_invoice(v_i1, 'key-p5-hd-22');
  perform public.apply_payment_credit(v_adv_pay, v_i1, 100000, 'key-p5-hd-23', v_today - 2);
  perform test_helpers.logout();
  select id into v_alloc from public.payment_allocations where payment_id = v_adv_pay and kind = 'credit' and status = 'active';
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.create_refund(%L, ''key-p5-hd-24'', %L, %L, %L::jsonb, null, ''Dated too early'')', v_adv_pay, v_bca, v_today - 4,
    jsonb_build_array(jsonb_build_object('allocation_id', v_alloc, 'amount', 100000))::text),
    'INVALID: the refund date cannot be before the allocation', 'the credit was applied 2 days ago; refunding it 4 days ago is refused');
  v_rev := public.create_refund(v_adv_pay, 'key-p5-hd-25', v_bca, v_today - 2,
    jsonb_build_array(jsonb_build_object('allocation_id', v_alloc, 'amount', 100000)), null, 'Dated on the allocation day');
  perform test_helpers.assert(v_rev is not null, 'on the allocation date it is accepted');
  perform test_helpers.logout();

  -- ---- a void cannot be dated before the last payment activity on the invoice
  perform test_helpers.login(v_admin);
  v_i2 := public.create_invoice_draft(pt, 'key-p5-hd-30', v_alfa, v_today - 8, v_today + 20, '[{"description":"Void bound","unit_price":40000}]');
  perform public.issue_invoice(v_i2, 'key-p5-hd-31');
  v_pay := public.record_payment(pt, 'key-p5-hd-32', v_alfa, v_bca, v_today - 7, 40000, jsonb_build_array(jsonb_build_object('invoice_id', v_i2, 'amount', 40000)));
  perform public.reverse_payment(v_pay, 'key-p5-hd-33', v_today - 2, 'Bounced transfer');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_msg(format('select public.void_invoice(%L, ''key-p5-hd-34'', ''Voiding before the bounce'', %L)', v_i2, v_today - 5), 'INVALID: the date cannot be before the last payment activity', 'a void dated between the payment and its reversal is refused');
  perform public.void_invoice(v_i2, 'key-p5-hd-35', 'Voiding after the bounce', v_today - 2);
  perform test_helpers.assert((select status = 'void' from public.invoices where id = v_i2), 'dated on the reversal day it voids');
  perform test_helpers.logout();

  -- ---- correcting an invoice whose product has since been retired still works
  insert into public.products (entity_id, kind, name, default_unit_price, default_currency, default_category_id)
  values (pt, 'service', 'Course Z', 90000, 'IDR', test_helpers.g('cat')) returning id into v_prod;
  perform test_helpers.login(v_admin);
  v_i3 := public.create_invoice_draft(pt, 'key-p5-hd-40', v_alfa, v_today - 3, v_today + 20,
    jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 1)));
  perform public.issue_invoice(v_i3, 'key-p5-hd-41');
  perform test_helpers.logout();
  update public.products set is_active = false where id = v_prod;
  perform test_helpers.login(v_owner);
  v_new := public.correct_invoice(v_i3, 'key-p5-hd-42', 'Product retired after the sale');
  perform test_helpers.assert(v_new is not null and (select count(*) from public.invoice_lines where invoice_id = v_new and product_id = v_prod) = 1, 'the corrected draft keeps the retired product line');
  perform test_helpers.logout();
  perform test_helpers.controls(pt, 'after the review hardening cases');
end
$$;

-- ================================================================ 15. proration is exact, also on near-ties
do $$
begin
  -- (remaining amount, remaining base, part, scale) -> expected, from exact rational arithmetic (half-up)
  perform test_helpers.assert(app_private.prorate_remaining(3, 5, 1, 0) = 2, '5/3 rounds to 2');
  perform test_helpers.assert(app_private.prorate_remaining(2, 5, 1, 0) = 3, '2.5 rounds up to 3');
  perform test_helpers.assert(app_private.prorate_remaining(7, 10, 3, 2) = 4.29, '30/7 = 4.2857... to 2 places is 4.29');
  perform test_helpers.assert(app_private.prorate_remaining(3, 10000, 1, 2) = 3333.33, 'a third of 10,000');
  perform test_helpers.assert(app_private.prorate_remaining(1000, 15000000, 0.0003, 0) = 5, 'a tiny part of a large base');
  perform test_helpers.assert(app_private.prorate_remaining(1000.0000, 15000000.0000, 0.0001, 0) = 2, '1.5 rounds up to 2');
  perform test_helpers.assert(app_private.prorate_remaining(999999999999999.9999, 1499999999999999.5000, 333333333333333.3333, 0) = 500000000000000, 'a very large near-tie');
  perform test_helpers.assert(app_private.prorate_remaining(200000000000000001, 300000000000000001, 1, 0) = 1, 'just below a tie by 1e-18 stays down (plain numeric division would round it up)');
  perform test_helpers.assert(app_private.prorate_remaining(200000000000000001, 300000000000000002, 1, 0) = 2, 'and just above rounds up');
  perform test_helpers.assert(app_private.prorate_remaining(123456789012.3457, 987654321098765.4321, 23456789012.3456, 2) = 187654313808764.7, 'a long mixed case');
  perform test_helpers.assert(app_private.prorate_remaining(4, 12345.67, 4, 2) = 12345.67, 'the last part takes exactly what is left');
  perform test_helpers.expect_msg('select app_private.prorate_remaining(3, 5, 4, 0)', 'INVALID', 'a part above the remainder is refused');
end
$$;

rollback;
