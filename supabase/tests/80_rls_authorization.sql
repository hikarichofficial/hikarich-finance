-- P2 gate (Step 15 §6, Step 06 §14, Step 16 G2): authorization is enforced by the database itself.
-- Every check runs as `anon` / `authenticated` with verified-style JWT claims, exactly like PostgREST,
-- so manually crafted requests (guessed IDs, forged entity_id, self-elevation) are what is tested.
begin;
set local client_min_messages = warning;

-- ================================================================ fixtures (superuser)
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_cat uuid;
  v_contact uuid;
  v_fa uuid;
  v_m uuid;
begin
  perform test_helpers.mk_user('a0000000-0000-0000-0000-000000000001', 'owner');
  perform test_helpers.assert(app_private.bootstrap_owner('a0000000-0000-0000-0000-000000000001', 'owner') = 2,
    'bootstrap gives the OWNER both Entities');
  perform test_helpers.expect_error(
    format('select app_private.bootstrap_owner(%L, %L)', 'a0000000-0000-0000-0000-000000000001', 'again'), '23000',
    'bootstrap is one-time');

  perform test_helpers.mk_user('a0000000-0000-0000-0000-000000000002', 'staff');
  perform test_helpers.mk_member(pt, 'a0000000-0000-0000-0000-000000000002', 'finance_staff');
  perform test_helpers.mk_user('a0000000-0000-0000-0000-000000000003', 'admin');
  perform test_helpers.mk_member(pt, 'a0000000-0000-0000-0000-000000000003', 'finance_admin');
  perform test_helpers.mk_user('a0000000-0000-0000-0000-000000000004', 'viewer');
  perform test_helpers.mk_member(pt, 'a0000000-0000-0000-0000-000000000004', 'viewer_auditor');
  perform test_helpers.mk_user('a0000000-0000-0000-0000-000000000005', 'payroll');
  perform test_helpers.mk_member(pt, 'a0000000-0000-0000-0000-000000000005', 'payroll');
  perform test_helpers.mk_user('a0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_member(pt, 'a0000000-0000-0000-0000-000000000006', 'accountant');
  perform test_helpers.mk_user('a0000000-0000-0000-0000-000000000007', 'nobody');
  perform test_helpers.mk_user('a0000000-0000-0000-0000-000000000008', 'admin2');
  perform test_helpers.mk_member(pt, 'a0000000-0000-0000-0000-000000000008', 'finance_admin');
  perform test_helpers.mk_user('a0000000-0000-0000-0000-000000000009', 'target');
  perform test_helpers.mk_user('a0000000-0000-0000-0000-00000000000a', 'peonly');
  v_m := test_helpers.mk_member(pe, 'a0000000-0000-0000-0000-00000000000a', 'finance_staff');
  insert into public.trusted_devices (user_id, fingerprint_hash) values ('a0000000-0000-0000-0000-00000000000a', 'fp-peonly');
  insert into public.security_events (user_id, entity_id, event_type) values ('a0000000-0000-0000-0000-00000000000a', pe, 'login_success');

  -- PT records
  insert into public.contacts (entity_id, kind, display_name, tax_identifier) values (pt, 'customer', 'PT Contact', 'PT-TAX-1') returning id into v_contact;
  insert into public.contact_bank_accounts (entity_id, contact_id, bank_name, account_number, account_holder)
  values (pt, v_contact, 'Bank', 'PT-BANK-111', 'Holder');
  update public.financial_accounts set account_number = 'PT-FIN-222' where entity_id = pt;
  -- Personal records: the data a PT-only user must never see
  insert into public.categories (entity_id, name, kind) values (pe, 'PE Category', 'expense') returning id into v_cat;
  insert into public.contacts (entity_id, kind, display_name, tax_identifier) values (pe, 'vendor', 'PE Contact', 'PE-TAX-1') returning id into v_contact;
  insert into public.contact_bank_accounts (entity_id, contact_id, bank_name, account_number, account_holder)
  values (pe, v_contact, 'Bank', 'PE-BANK-333', 'Holder');
  insert into public.products (entity_id, kind, name) values (pe, 'service', 'PE Product');
  insert into public.financial_accounts (entity_id, kind, name, account_number, currency, ledger_account_id)
  values (pe, 'bank', 'PE Bank', 'PE-FIN-444', 'IDR', test_helpers.acct(pe, 'PERSONAL_BANK')) returning id into v_fa;
  perform test_helpers.simple_journal(pe, date '2026-09-10', test_helpers.acct(pe, 'PERSONAL_BANK'), test_helpers.acct(pe, 'SALARY_INCOME'), 100, 'system', true);
  insert into public.entity_settings (entity_id, setting_key, setting_value) values (pe, 'invoice.footer', '"personal"');
  insert into public.numbering_sequences (entity_id, scope, prefix) values (pe, 'invoice', 'PRS');
  perform app_private.allocate_document_number(pe, 'invoice', date '2026-09-10');
  insert into public.approval_rules (entity_id, module, action, effective_from) values (pe, 'bill', 'pay', date '2026-01-01');
  insert into public.category_account_mappings (entity_id, category_id, debit_ledger_account_id, effective_from)
  values (pe, v_cat, test_helpers.acct(pe, 'PERSONAL_FOOD'), date '2026-01-01');
  insert into public.posting_batches (entity_id, batch_type) values (pe, 'manual');
  insert into public.payment_channels (entity_id, method_kind, name, settlement_financial_account_id) values (pe, 'cash', 'PE Cash', v_fa);
end
$$;

-- ================================================================ 1. anonymous access
reset role;
do $$
declare
  r record;
begin
  perform test_helpers.as_anon();
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r' loop
    perform test_helpers.expect_error(format('select 1 from public.%I limit 1', r.relname), '42501', 'anon reads ' || r.relname);
  end loop;
  perform test_helpers.expect_error('select public.my_access()', '42501', 'anon cannot call my_access');
  perform test_helpers.expect_error('select app_authz.is_member(gen_random_uuid())', '42501', 'anon cannot use app_authz');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 2. PT-only users cannot see Personal data
reset role;
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_pe_contact uuid;
  v_pe_journal uuid;
  u uuid;
  r record;
  v_n bigint;
begin
  select id into v_pe_contact from public.contacts where entity_id = pe;
  select id into v_pe_journal from public.journal_entries where entity_id = pe;

  foreach u in array array[
    'a0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000003',
    'a0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000005',
    'a0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000007']::uuid[] loop
    perform test_helpers.login(u);
    -- Every Entity-scoped table: nothing of Personal is visible, whatever the query.
    for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'public' and c.relkind = 'r'
               and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'entity_id' and not a.attisdropped) loop
      begin
        execute format('select count(*) from public.%I where entity_id = %L', r.relname, pe) into v_n;
      exception when insufficient_privilege then
        v_n := 0;   -- closed at the privilege level: also fine
      end;
      perform test_helpers.assert(v_n = 0, format('user %s sees Personal rows in %s', right(u::text, 2), r.relname));
    end loop;
    -- Guessed / direct IDs return nothing.
    perform test_helpers.assert(test_helpers.rows(format('select id from public.contacts where id = %L', v_pe_contact)) = 0, 'guessed Personal contact id');
    perform test_helpers.assert(test_helpers.rows(format('select id from public.journal_entries where id = %L', v_pe_journal)) = 0, 'guessed Personal journal id');
    perform test_helpers.assert(test_helpers.rows(format('select id from public.entities where id = %L', pe)) = 0, 'Personal Entity itself is invisible');
    perform test_helpers.assert(test_helpers.rows(format('select 1 from public.entity_memberships where entity_id = %L', pe)) = 0, 'Personal memberships invisible');
    perform test_helpers.assert(test_helpers.rows(format('select 1 from public.profiles where id = %L', 'a0000000-0000-0000-0000-00000000000a')) = 0, 'Personal-only user profile invisible');
    perform test_helpers.assert(test_helpers.rows(format('select 1 from public.trusted_devices where user_id = %L', 'a0000000-0000-0000-0000-00000000000a')) = 0, 'Personal-only user devices invisible');
    perform test_helpers.assert(test_helpers.rows(format('select 1 from public.security_events where user_id = %L', 'a0000000-0000-0000-0000-00000000000a')) = 0, 'Personal-only security events invisible');
    perform test_helpers.assert(test_helpers.rows(format('select 1 from public.audit_events where entity_id = %L', pe)) = 0, 'Personal audit invisible');
    -- Sensitive reveal on Personal data is refused with the same answer as "does not exist".
    perform test_helpers.expect_error(format('select public.reveal_sensitive(%L, %L)', 'contact_tax_identifier', v_pe_contact), '42501', 'reveal Personal tax id');
    perform test_helpers.expect_error(format('select public.reveal_sensitive(%L, gen_random_uuid())', 'contact_tax_identifier'), '42501', 'reveal unknown id');
    perform test_helpers.logout();
  end loop;

  -- Canary: the OWNER (aal2) does see Personal data, so the zeros above are real isolation, not empty tables.
  perform test_helpers.login('a0000000-0000-0000-0000-000000000001');
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.contacts where entity_id = %L', pe)) = 1, 'OWNER sees Personal contact');
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.journal_entries where entity_id = %L', pe)) = 1, 'OWNER sees Personal journal');
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.entities where id in (%L, %L)', pt, pe)) = 2, 'OWNER sees both Entities');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 3. crafted writes
reset role;
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_pe_contact uuid;
  v_pt_contact uuid;
  v_new uuid;
  v_n bigint;
  v_staff uuid := 'a0000000-0000-0000-0000-000000000002';
  v_admin uuid := 'a0000000-0000-0000-0000-000000000003';
begin
  select id into v_pe_contact from public.contacts where entity_id = pe;
  select id into v_pt_contact from public.contacts where entity_id = pt and display_name = 'PT Contact';

  perform test_helpers.login(v_staff);
  -- Allowed: what the role grants, in its own Entity.
  insert into public.contacts (entity_id, kind, display_name) values (pt, 'customer', 'Created by staff') returning id into v_new;
  perform test_helpers.assert((select created_by from public.contacts where id = v_new) = v_staff, 'created_by is stamped from the JWT');
  perform test_helpers.expect_error(
    format('insert into public.contacts (entity_id, kind, display_name, created_by) values (%L,%L,%L,%L)', pt, 'customer', 'x', v_staff),
    '42501', 'created_by is not writable by browser roles');
  perform test_helpers.assert(test_helpers.affected(format('update public.contacts set notes = %L where id = %L', 'ok', v_new)) = 1, 'staff edits PT contact');
  -- Denied: forged Entity on insert, update, delete, and moving a record.
  perform test_helpers.expect_error(
    format('insert into public.contacts (entity_id, kind, display_name) values (%L,%L,%L)', pe, 'customer', 'Forged entity'), '42501', 'insert into Personal');
  perform test_helpers.expect_error(
    format('insert into public.products (entity_id, kind, name) values (%L,%L,%L)', pe, 'product', 'Forged'), '42501', 'insert product into Personal');
  perform test_helpers.assert(test_helpers.affected(format('update public.contacts set notes = %L where id = %L', 'hacked', v_pe_contact)) = 0, 'update Personal contact by id');
  perform test_helpers.assert(test_helpers.affected(format('delete from public.contacts where id = %L', v_pe_contact)) = 0, 'delete Personal contact by id');
  perform test_helpers.expect_error(
    format('update public.contacts set entity_id = %L where id = %L', pe, v_new), '42501', 'move a contact to Personal');
  perform test_helpers.assert(test_helpers.affected(format('delete from public.contacts where id = %L', v_new)) = 0, 'staff lacks contacts.archive');
  -- Capability, not just Entity: staff cannot manage categories or delete products.
  perform test_helpers.expect_error(
    format('insert into public.categories (entity_id, name, kind) values (%L,%L,%L)', pt, 'Staff category', 'expense'), '42501', 'staff lacks categories.manage');
  -- No browser write path exists for financial tables, even inside the user's own Entity.
  perform test_helpers.expect_error(
    format('insert into public.journal_entries (entity_id, entry_date, period_id, entry_type, description) values (%L,%L,%L,%L,%L)',
           pt, date '2026-09-10', (select id from public.accounting_periods limit 1), 'manual', 'x'), '42501', 'journal insert');
  perform test_helpers.expect_error(format('update public.entity_memberships set status = %L', 'disabled'), '42501', 'membership update');
  perform test_helpers.expect_error(format('insert into public.audit_events (action, target_table) values (%L,%L)', 'x.y', 'x'), '42501', 'audit insert');
  perform test_helpers.expect_error('delete from public.audit_events', '42501', 'audit delete');
  perform test_helpers.expect_error(format('insert into public.role_permissions (role_id, permission_key) select id, %L from public.roles limit 1', 'users.assign_role'), '42501', 'role_permissions insert');
  perform test_helpers.expect_error(format('insert into public.idempotency_keys (scope, key) values (%L,%L)', 'a.b.c', 'key-12345678'), '42501', 'idempotency insert');
  perform test_helpers.expect_error('select 1 from public.outbox_events', '42501', 'outbox is closed');
  perform test_helpers.expect_error('select 1 from public.idempotency_keys', '42501', 'idempotency is closed');
  perform test_helpers.expect_error('select 1 from public.numbering_counters', '42501', 'counters are closed');
  perform test_helpers.logout();

  -- Finance admin may manage categories in PT, but only in PT.
  perform test_helpers.login(v_admin);
  insert into public.categories (entity_id, name, kind) values (pt, 'Admin category', 'expense');
  perform test_helpers.expect_error(
    format('insert into public.categories (entity_id, name, kind) values (%L,%L,%L)', pe, 'Forged category', 'expense'), '42501', 'admin category in Personal');
  perform test_helpers.logout();

  -- Consolidated-analytics capability never confers mutation rights (Step 06 §5, §14).
  insert into public.membership_permission_overrides (membership_id, permission_key, effect)
  select m.id, 'reports.cross_entity', 'grant' from public.entity_memberships m where m.user_id = 'a0000000-0000-0000-0000-000000000004';
  perform test_helpers.login('a0000000-0000-0000-0000-000000000004');
  perform test_helpers.expect_error(
    format('insert into public.contacts (entity_id, kind, display_name) values (%L,%L,%L)', pt, 'customer', 'viewer write'), '42501', 'cross-entity capability is read-only (insert)');
  perform test_helpers.assert(test_helpers.affected(format('update public.contacts set notes = %L where id = %L', 'x', v_pt_contact)) = 0, 'cross-entity capability is read-only (update)');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 4. sensitive fields
reset role;
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  v_contact uuid;
  v_bank uuid;
  v_fa uuid;
  v_staff uuid := 'a0000000-0000-0000-0000-000000000002';
  v_owner uuid := 'a0000000-0000-0000-0000-000000000001';
  v_staff_m uuid;
  v_perms jsonb;
begin
  select id into v_contact from public.contacts where entity_id = pt and display_name = 'PT Contact';
  select id into v_bank from public.contact_bank_accounts where entity_id = pt;
  select id into v_fa from public.financial_accounts where entity_id = pt;
  select id into v_staff_m from public.entity_memberships where user_id = v_staff;

  perform test_helpers.login('a0000000-0000-0000-0000-000000000003');   -- finance admin: broad rights, still no sensitive access
  perform test_helpers.expect_error('select tax_identifier from public.contacts', '42501', 'tax identifier column is hidden');
  perform test_helpers.expect_error('select * from public.contacts', '42501', 'select * cannot expand hidden columns');
  perform test_helpers.expect_error('select account_number from public.contact_bank_accounts', '42501', 'bank account number is hidden');
  perform test_helpers.expect_error('select account_number from public.financial_accounts', '42501', 'financial account number is hidden');
  perform test_helpers.expect_error('select fingerprint_hash from public.trusted_devices', '42501', 'device fingerprint hash is hidden');
  perform test_helpers.expect_error(
    format('update public.contacts set tax_identifier = %L where id = %L', 'X', v_contact), '42501', 'tax identifier is not writable');
  perform test_helpers.assert(test_helpers.rows('select id, display_name, status from public.contacts') >= 1, 'non-sensitive columns remain readable');
  perform test_helpers.expect_error(format('select public.reveal_sensitive(%L, %L)', 'contact_tax_identifier', v_contact), '42501', 'reveal needs contacts.view_sensitive');
  perform test_helpers.expect_error(format('select public.reveal_sensitive(%L, %L)', 'financial_account_number', v_fa), '42501', 'reveal needs money.view_sensitive');
  perform test_helpers.logout();

  -- OWNER reveals, and the reveal is recorded without the value.
  perform test_helpers.login(v_owner);
  perform test_helpers.assert(public.reveal_sensitive('contact_tax_identifier', v_contact) = 'PT-TAX-1', 'OWNER reveals tax id');
  perform test_helpers.assert(public.reveal_sensitive('contact_bank_account_number', v_bank) = 'PT-BANK-111', 'OWNER reveals contact bank number');
  perform test_helpers.assert(public.reveal_sensitive('financial_account_number', v_fa) = 'PT-FIN-222', 'OWNER reveals account number');
  perform test_helpers.logout();
  perform test_helpers.assert((select count(*) from public.security_events where event_type = 'sensitive_reveal' and user_id = v_owner) = 3, 'reveals are logged');
  perform test_helpers.assert(not exists (select 1 from public.security_events where metadata::text ~ '(TAX|BANK|FIN)-'), 'logged reveals never contain the value');

  -- MFA: the same OWNER on an aal1 session gets nothing (Step 01 #38).
  perform test_helpers.login(v_owner, 'aal1');
  perform test_helpers.expect_error(format('select public.reveal_sensitive(%L, %L)', 'contact_tax_identifier', v_contact), '42501', 'OWNER without MFA cannot reveal');
  perform test_helpers.logout();

  -- An explicit, audited grant unlocks exactly one capability for one membership.
  insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (v_staff_m, 'contacts.view_sensitive', 'grant');
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(public.reveal_sensitive('contact_tax_identifier', v_contact) = 'PT-TAX-1', 'granted capability works');
  perform test_helpers.expect_error(format('select public.reveal_sensitive(%L, %L)', 'financial_account_number', v_fa), '42501', 'other sensitive capability still denied');
  perform test_helpers.logout();

  -- Payroll/tax segmentation: no operational role holds payroll rights; the payroll role holds no finance rights.
  perform test_helpers.login('a0000000-0000-0000-0000-000000000002');
  v_perms := public.my_access() -> 'memberships' -> 0 -> 'permissions';
  perform test_helpers.assert(not exists (select 1 from jsonb_array_elements_text(v_perms) k where k like 'payroll.%'), 'finance staff has no payroll rights');
  perform test_helpers.logout();
  perform test_helpers.login('a0000000-0000-0000-0000-000000000003');
  v_perms := public.my_access() -> 'memberships' -> 0 -> 'permissions';
  perform test_helpers.assert(not exists (select 1 from jsonb_array_elements_text(v_perms) k where k like 'payroll.%' or k like 'users.%' or k like 'security.%' or k like 'backup.%'),
    'finance admin has no payroll, users, security or backup rights');
  perform test_helpers.assert(not v_perms ? 'periods.reopen' and not v_perms ? 'periods.close', 'finance admin cannot close or reopen periods by default');
  perform test_helpers.logout();
  perform test_helpers.login('a0000000-0000-0000-0000-000000000005');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') = 0, 'payroll role reads no contacts');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.journal_entries') = 0, 'payroll role reads no journals');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.financial_accounts') = 0, 'payroll role reads no financial accounts');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 5. immediate effect of revocation
reset role;
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  v_staff uuid := 'a0000000-0000-0000-0000-000000000002';
  v_m uuid;
  v_role uuid;
begin
  select id, role_id into v_m, v_role from public.entity_memberships where user_id = v_staff;
  insert into auth.sessions (user_id) values (v_staff);

  perform test_helpers.login(v_staff);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') >= 1, 'staff reads contacts before revocation');
  perform test_helpers.logout();

  -- Permission removed from the role: the very next statement is denied.
  delete from public.role_permissions where role_id = v_role and permission_key = 'contacts.view';
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') = 0, 'permission removal applies immediately');
  perform test_helpers.logout();
  insert into public.role_permissions (role_id, permission_key) values (v_role, 'contacts.view');

  -- Explicit deny beats the role.
  insert into public.membership_permission_overrides (membership_id, permission_key, effect) values (v_m, 'contacts.view', 'deny');
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') = 0, 'explicit deny wins');
  perform test_helpers.logout();
  delete from public.membership_permission_overrides where membership_id = v_m and permission_key = 'contacts.view';

  -- Disabled membership.
  update public.entity_memberships set status = 'disabled', disabled_at = now() where id = v_m;
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') = 0, 'disabled membership loses access immediately');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.entities') = 0, 'disabled membership cannot see the Entity');
  perform test_helpers.assert(jsonb_array_length(public.my_access() -> 'memberships') = 0, 'my_access lists no disabled membership');
  perform test_helpers.logout();
  update public.entity_memberships set status = 'active', disabled_at = null where id = v_m;

  -- Disabled Entity.
  update public.entities set status = 'disabled', disabled_at = now() where id = pt;
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') = 0, 'disabled Entity denies everything');
  perform test_helpers.logout();
  update public.entities set status = 'active', disabled_at = null where id = pt;

  -- Disabled user: access stops at once, sessions are removed, a security event is written.
  update public.profiles set is_active = false where id = v_staff;
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') = 0, 'disabled user loses access immediately');
  perform test_helpers.assert((public.my_access() ->> 'active')::boolean = false, 'my_access reports the user as inactive');
  perform test_helpers.logout();
  perform test_helpers.assert(not exists (select 1 from auth.sessions where user_id = v_staff), 'disabling a user revokes sessions');
  perform test_helpers.assert(exists (select 1 from public.security_events where user_id = v_staff and event_type = 'user_disabled'), 'disable is a security event');
  update public.profiles set is_active = true where id = v_staff;
  perform test_helpers.login(v_staff);
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') >= 1, 're-enabled user regains exactly the granted access');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 6. no self-elevation, no escalation, lock-out protection
reset role;
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
  v_owner uuid := 'a0000000-0000-0000-0000-000000000001';
  v_staff uuid := 'a0000000-0000-0000-0000-000000000002';
  v_admin uuid := 'a0000000-0000-0000-0000-000000000003';
  v_viewer uuid := 'a0000000-0000-0000-0000-000000000004';
  v_admin2 uuid := 'a0000000-0000-0000-0000-000000000008';
  v_target uuid := 'a0000000-0000-0000-0000-000000000009';
  v_staff_m uuid;
  v_admin2_m uuid;
  v_owner_m uuid;
  v_new uuid;
begin
  select id into v_staff_m from public.entity_memberships where user_id = v_staff;
  select id into v_admin2_m from public.entity_memberships where user_id = v_admin2;
  select id into v_owner_m from public.entity_memberships where user_id = v_owner and entity_id = pt;

  -- Staff: no path to more rights.
  perform test_helpers.login(v_staff);
  perform test_helpers.expect_error(format('select public.assign_membership(%L,%L,%L)', pt, v_staff, 'owner'), '42501', 'staff grants self OWNER');
  perform test_helpers.expect_error(format('select public.assign_membership(%L,%L,%L)', pe, v_staff, 'finance_staff'), '42501', 'staff grants self Personal access');
  perform test_helpers.expect_error(format('select public.assign_membership(%L,%L,%L)', pt, v_target, 'viewer_auditor'), '42501', 'staff grants others');
  perform test_helpers.expect_error(format('select public.set_permission_override(%L,%L,%L)', v_staff_m, 'users.assign_role', 'grant'), '42501', 'staff overrides own permissions');
  perform test_helpers.expect_error(format('select public.set_membership_status(%L,false)', v_staff_m), '42501', 'staff disables own membership');
  perform test_helpers.expect_error(format('select public.set_user_active(%L,false)', v_staff), '42501', 'staff disables self');
  perform test_helpers.logout();

  -- OWNER: cannot change own access either, and sensitive actions need recent step-up.
  perform test_helpers.login(v_owner);
  perform test_helpers.expect_error(format('select public.assign_membership(%L,%L,%L)', pt, v_owner, 'viewer_auditor'), '42501', 'OWNER changes own membership');
  perform test_helpers.expect_error(format('select public.set_user_active(%L,false)', v_owner), '42501', 'OWNER disables self');
  perform test_helpers.logout();
  perform test_helpers.login(v_owner, 'aal2', interval '11 minutes');
  perform test_helpers.expect_error(format('select public.assign_membership(%L,%L,%L)', pt, v_target, 'finance_staff'), '42501', 'stale authentication is refused');
  perform test_helpers.assert(test_helpers.sqlerrm_of(format('select public.assign_membership(%L,%L,%L)', pt, v_target, 'finance_staff')) like 'STEP_UP_REQUIRED%', 'error says step-up required');
  perform test_helpers.assert((public.my_access() ->> 'recent_step_up')::boolean = false, 'my_access reports stale step-up');
  perform test_helpers.logout();

  -- OWNER with fresh authentication grants access (audited).
  perform test_helpers.login(v_owner, 'aal2', interval '2 minutes');
  perform test_helpers.assert((public.my_access() ->> 'recent_step_up')::boolean, 'my_access reports fresh step-up');
  v_new := public.assign_membership(pt, v_target, 'finance_staff', 'test grant');
  perform test_helpers.logout();
  perform test_helpers.assert(exists (select 1 from public.audit_events where target_table = 'entity_memberships' and target_id = v_new and reason = 'test grant'),
    'membership change is audited with actor and reason');
  perform test_helpers.assert(exists (select 1 from public.audit_events where target_id = v_new and actor_id = v_owner), 'audit records the actor');

  -- Escalation: an administrator handed users.* by the OWNER can only give away what they hold.
  insert into public.membership_permission_overrides (membership_id, permission_key, effect)
  values (v_admin2_m, 'users.assign_role', 'grant'), (v_admin2_m, 'users.assign_entity', 'grant'), (v_admin2_m, 'users.disable', 'grant'),
         (v_admin2_m, 'users.change_permissions', 'grant');
  perform test_helpers.login(v_admin2);
  perform test_helpers.expect_error(format('select public.assign_membership(%L,%L,%L)', pt, v_target, 'accountant'), '42501', 'cannot grant permissions you do not hold (periods.close ...)');
  perform test_helpers.expect_error(format('select public.assign_membership(%L,%L,%L)', pt, v_target, 'owner'), '42501', 'only an OWNER grants OWNER');
  perform test_helpers.expect_error(format('select public.assign_membership(%L,%L,%L)', pe, v_target, 'finance_staff'), '42501', 'no authority in Personal');
  perform test_helpers.expect_error(format('select public.set_permission_override(%L,%L,%L)', v_staff_m, 'periods.reopen', 'grant'), '42501', 'cannot grant a permission you lack');
  perform test_helpers.expect_error(format('select public.set_membership_status(%L,false)', v_owner_m), '42501', 'cannot disable an OWNER');
  perform test_helpers.expect_error(format('select public.set_user_active(%L,false)', v_owner), '42501', 'cannot disable OWNER user');
  perform test_helpers.assert(public.assign_membership(pt, v_target, 'finance_staff') is not null, 'can grant a role within own permission set');
  perform test_helpers.logout();

  -- Direct table writes stay impossible for everybody, including administrators.
  perform test_helpers.login(v_admin2);
  perform test_helpers.expect_error(format('insert into public.entity_memberships (entity_id, user_id, role_id) select %L, %L, id from public.roles where role_key = %L', pt, v_target, 'owner'), '42501', 'direct membership insert');
  perform test_helpers.logout();

  -- Lock-out protection.
  perform test_helpers.expect_error(format('update public.entity_memberships set status = %L, disabled_at = now() where id = %L', 'disabled', v_owner_m), '23000', 'last OWNER of an Entity cannot be disabled');
  perform test_helpers.expect_error(format('delete from public.entity_memberships where id = %L', v_owner_m), '23000', 'last OWNER membership cannot be deleted');
  perform test_helpers.expect_error(format('update public.entity_memberships set role_id = (select id from public.roles where role_key = %L) where id = %L', 'finance_staff', v_owner_m), '23000', 'last OWNER cannot be downgraded');
  perform test_helpers.expect_error(format('update public.profiles set is_active = false where id = %L', v_owner), '23000', 'last OWNER user cannot be disabled');
  perform test_helpers.expect_error(format('delete from public.roles where role_key = %L', 'owner'), '23000', 'system roles cannot be deleted');
  perform test_helpers.expect_error(format('update public.roles set role_key = %L where role_key = %L', 'boss', 'owner'), '23000', 'system role keys are fixed');
  -- ... but with a second OWNER the first can be changed.
  perform test_helpers.mk_user('a0000000-0000-0000-0000-00000000000b', 'owner2');
  perform test_helpers.mk_member(pt, 'a0000000-0000-0000-0000-00000000000b', 'owner');
  update public.entity_memberships set status = 'disabled', disabled_at = now() where id = v_owner_m;
  perform test_helpers.assert(true, 'OWNER can be disabled once another OWNER exists');
end
$$;

-- ================================================================ 7. MFA assurance level
reset role;
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  v_owner uuid := 'a0000000-0000-0000-0000-000000000001';
  v_staff uuid := 'a0000000-0000-0000-0000-000000000002';
  v_access jsonb;
begin
  -- OWNER on a password-only session: identity visible, business data closed.
  perform test_helpers.login(v_owner, 'aal1');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') = 0, 'OWNER aal1 reads no contacts');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.entities') = 0, 'OWNER aal1 reads no Entities');
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.profiles where id = %L', v_owner)) = 1, 'OWNER aal1 still reads own profile');
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.entity_memberships where user_id = %L', v_owner)) = 2, 'OWNER aal1 still sees own memberships');
  v_access := public.my_access();
  perform test_helpers.assert((v_access -> 'memberships' -> 0 ->> 'mfa_required')::boolean and not (v_access -> 'memberships' -> 0 ->> 'mfa_satisfied')::boolean, 'my_access flags MFA as required and not satisfied');
  perform test_helpers.assert(v_access -> 'memberships' -> 0 -> 'permissions' = '[]'::jsonb, 'no capabilities without MFA');
  perform test_helpers.logout();

  -- Staff MFA is configurable per Entity.
  perform test_helpers.login(v_staff, 'aal1');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') >= 1, 'staff without an MFA policy works at aal1');
  perform test_helpers.logout();
  insert into public.entity_settings (entity_id, setting_key, setting_value) values (pt, 'security.require_mfa', 'true');
  perform test_helpers.login(v_staff, 'aal1');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') = 0, 'MFA policy blocks aal1 staff');
  perform test_helpers.logout();
  perform test_helpers.login(v_staff, 'aal2');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.contacts') >= 1, 'MFA policy passes at aal2');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 8. internal functions are unreachable
reset role;
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
begin
  perform test_helpers.login('a0000000-0000-0000-0000-000000000001');
  perform test_helpers.expect_error(format('select app_private.allocate_document_number(%L,%L,%L)', pt, 'invoice', date '2026-09-01'), '42501', 'numbering allocation is not callable by users');
  perform test_helpers.expect_error(format('select app_private.ensure_accounting_period(%L,%L)', pt, date '2026-10-01'), '42501', 'period creation is not callable by users');
  perform test_helpers.expect_error(format('select app_private.provision_default_coa(%L)', pt), '42501', 'COA provisioning is not callable by users');
  perform test_helpers.expect_error(format('select app_private.bootstrap_owner(%L,%L)', 'a0000000-0000-0000-0000-000000000009', 'x'), '42501', 'bootstrap is not callable by users');
  -- Forged arguments to the authorization helpers leak nothing: they evaluate the CALLER, never the argument.
  perform test_helpers.assert(app_authz.has_permission(gen_random_uuid(), 'contacts.view') = false, 'unknown Entity grants nothing');
  perform test_helpers.logout();
  perform test_helpers.login('a0000000-0000-0000-0000-000000000007');
  perform test_helpers.assert(app_authz.has_permission(pt, 'contacts.view') = false, 'a user without membership holds no permission');
  perform test_helpers.assert(app_authz.is_member(pt) = false, 'a user without membership is not a member');
  perform test_helpers.logout();
end
$$;

-- ================================================================ 9. audit visibility
reset role;
do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  pe uuid := test_helpers.entity('demo_personal');
begin
  perform test_helpers.login('a0000000-0000-0000-0000-000000000004');   -- viewer/auditor: audit.view in PT only
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.audit_events where entity_id = %L', pt)) >= 1, 'auditor reads PT audit trail');
  perform test_helpers.assert(test_helpers.rows(format('select 1 from public.audit_events where entity_id = %L', pe)) = 0, 'auditor cannot read Personal audit trail');
  perform test_helpers.assert(test_helpers.rows('select 1 from public.audit_events where entity_id is null') = 0, 'global audit rows are OWNER-level only');
  perform test_helpers.expect_error('update public.audit_events set action = ''x''', '42501', 'auditor cannot edit audit history');
  perform test_helpers.logout();
  perform test_helpers.login('a0000000-0000-0000-0000-000000000002');   -- staff: no audit rights
  perform test_helpers.assert(test_helpers.rows('select 1 from public.audit_events') = 0, 'staff without audit.view reads no audit');
  perform test_helpers.logout();
end
$$;

rollback;
