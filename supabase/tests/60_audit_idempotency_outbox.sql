-- Audit trail, idempotency and outbox foundations (Step 13 §9/§14/§19, Step 06 §13, Step 08 §3/§17).
begin;
set local client_min_messages = warning;

do $$
declare
  pt uuid := test_helpers.entity('demo_pt');
  v_cat uuid;
  v_contact uuid;
  v_user uuid := gen_random_uuid();
  v_ev public.audit_events%rowtype;
  v_n integer;
begin
  -- ---- audit records who/what/when with before/after snapshots
  perform set_config('app.audit_reason', 'unit test', true);
  perform set_config('app.correlation_id', 'corr-123', true);
  insert into public.categories (entity_id, name, kind) values (pt, 'Audited', 'expense') returning id into v_cat;
  select * into v_ev from public.audit_events where target_table = 'categories' and target_id = v_cat and action = 'categories.insert';
  perform test_helpers.assert(v_ev.entity_id = pt and v_ev.after_state ->> 'name' = 'Audited' and v_ev.before_state is null, 'insert audited');
  perform test_helpers.assert(v_ev.reason = 'unit test' and v_ev.correlation_id = 'corr-123', 'audit reason and correlation captured');

  update public.categories set name = 'Audited 2' where id = v_cat;
  select * into v_ev from public.audit_events where target_id = v_cat and action = 'categories.update';
  perform test_helpers.assert(v_ev.before_state ->> 'name' = 'Audited' and v_ev.after_state ->> 'name' = 'Audited 2', 'update audited with before/after');

  select count(*) into v_n from public.audit_events where target_id = v_cat;
  update public.categories set name = name where id = v_cat;
  perform test_helpers.assert((select count(*) from public.audit_events where target_id = v_cat) = v_n, 'no-op update is not audited');
  perform test_helpers.assert((select version from public.categories where id = v_cat) = 3, 'version increments on every update');

  delete from public.categories where id = v_cat;
  perform test_helpers.assert(exists (select 1 from public.audit_events where target_id = v_cat and action = 'categories.delete'), 'delete audited');

  -- ---- sensitive columns never reach the audit trail
  insert into public.contacts (entity_id, kind, display_name, tax_identifier)
  values (pt, 'vendor', 'Audit Vendor', 'TAX-SECRET-123') returning id into v_contact;
  insert into public.contact_bank_accounts (entity_id, contact_id, bank_name, account_number, account_holder)
  values (pt, v_contact, 'Test Bank', 'ACCT-SECRET-456', 'Holder');
  insert into public.financial_accounts (entity_id, kind, name, account_number, currency, ledger_account_id)
  values (pt, 'cash', 'Audit Cash', 'FIN-SECRET-789', 'IDR', test_helpers.acct(pt, 'CASH'));
  insert into auth.users (id, email) values (v_user, 'synthetic@example.invalid');
  insert into public.profiles (id, display_name) values (v_user, 'Synthetic User');
  insert into public.trusted_devices (user_id, fingerprint_hash) values (v_user, 'FP-SECRET-000');
  perform test_helpers.assert(
    not exists (select 1 from public.audit_events
                where coalesce(after_state::text, '') || coalesce(before_state::text, '') ~ '(TAX|ACCT|FIN|FP)-SECRET'),
    'sensitive identifiers are redacted from audit snapshots');
  perform test_helpers.assert(
    exists (select 1 from public.audit_events where action = 'contacts.insert' and target_id = v_contact),
    'redacted table still audited');

  -- ---- audit and security logs are append-only
  perform test_helpers.expect_error('update public.audit_events set action = ''x''', '23000', 'audit update');
  perform test_helpers.expect_error('delete from public.audit_events', '23000', 'audit delete');
  perform test_helpers.expect_error('truncate public.audit_events', '23000', 'audit truncate');
  insert into public.security_events (user_id, event_type) values (v_user, 'login_success');
  perform test_helpers.expect_error('update public.security_events set severity = ''info''', '23000', 'security event update');
  perform test_helpers.expect_error('delete from public.security_events', '23000', 'security event delete');
  perform test_helpers.expect_error(
    format('insert into public.audit_events (action, target_table, actor_type) values (%L,%L,%L)', 'x.y', 'x', 'robot'), '23514', 'actor type domain');

  -- ---- idempotency: one namespace per scope, retries collide instead of duplicating
  insert into public.idempotency_keys (scope, entity_id, key) values ('invoice.issue', pt, 'key-0000001');
  perform test_helpers.expect_error(
    format('insert into public.idempotency_keys (scope, entity_id, key) values (%L,%L,%L)', 'invoice.issue', pt, 'key-0000001'), '23505', 'same scope+entity+key');
  insert into public.idempotency_keys (scope, entity_id, key) values ('payment.record', pt, 'key-0000001');
  insert into public.idempotency_keys (scope, entity_id, key) values ('invoice.issue', null, 'key-0000001');
  perform test_helpers.expect_error(
    format('insert into public.idempotency_keys (scope, entity_id, key) values (%L,null,%L)', 'invoice.issue', 'key-0000001'), '23505', 'global-scope key collides too');
  perform test_helpers.expect_error(
    format('insert into public.idempotency_keys (scope, entity_id, key, status) values (%L,%L,%L,%L)', 'a.b.c', pt, 'key-0000002', 'succeeded'), '23514', 'succeeded needs a result');
  perform test_helpers.expect_error(
    format('insert into public.idempotency_keys (scope, entity_id, key) values (%L,%L,%L)', 'a.b.c', pt, 'short'), '23514', 'key too short');
  perform test_helpers.expect_error(
    format('update public.idempotency_keys set entity_id = null where scope = %L and entity_id = %L', 'payment.record', pt), '23000', 'idempotency entity locked');
  update public.idempotency_keys set status = 'succeeded', result_table = 'invoices', result_id = gen_random_uuid(), completed_at = now()
  where scope = 'invoice.issue' and entity_id = pt;

  -- ---- outbox
  insert into public.outbox_events (entity_id, event_type, payload) values (pt, 'invoice.issued', '{"n":1}');
  perform test_helpers.expect_error(
    format('insert into public.outbox_events (entity_id, event_type, status) values (%L,%L,%L)', pt, 'invoice.issued', 'processed'), '23514', 'processed needs processed_at');
  perform test_helpers.expect_error(
    format('insert into public.outbox_events (entity_id, event_type, attempts) values (%L,%L,-1)', pt, 'invoice.issued'), '23514', 'attempts non-negative');
end
$$;

rollback;
