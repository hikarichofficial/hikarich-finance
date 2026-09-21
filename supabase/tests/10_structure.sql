-- Structural invariants that every current and future table must keep (Step 02 §1/§6, Step 08 §3-§5).
begin;

do $$
declare
  v_bad text;
begin
  -- Money and rates are exact decimals: no floating point anywhere in the public schema.
  select string_agg(table_name || '.' || column_name, ', ') into v_bad
  from information_schema.columns
  where table_schema = 'public' and data_type in ('real', 'double precision');
  perform test_helpers.assert(v_bad is null, 'no floating-point columns: ' || coalesce(v_bad, ''));

  -- Every Entity-scoped table protects entity_id from change (or is append-only / has its own guard).
  select string_agg(c.relname, ', ') into v_bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and exists (select 1 from pg_attribute a
                where a.attrelid = c.oid and a.attname = 'entity_id' and not a.attisdropped)
    and not exists (select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid
                    where t.tgrelid = c.oid and not t.tgisinternal
                      and p.proname in ('tg_lock_entity', 'tg_forbid_update', 'tg_journal_lines_guard',
                                        'tg_issued_numbers_guard'));
  perform test_helpers.assert(v_bad is null, 'entity_id immutability trigger missing on: ' || coalesce(v_bad, ''));

  -- Every Entity-scoped table with a mandatory entity_id exposes UNIQUE (entity_id, id) so other
  -- tables can reference it with a composite key.
  select string_agg(c.relname, ', ') into v_bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute ae on ae.attrelid = c.oid and ae.attname = 'entity_id' and ae.attnotnull and not ae.attisdropped
  join pg_attribute ai on ai.attrelid = c.oid and ai.attname = 'id' and not ai.attisdropped
  where n.nspname = 'public' and c.relkind = 'r'
    and not exists (select 1 from pg_index i
                    where i.indrelid = c.oid and i.indisunique and i.indpred is null
                      and i.indnkeyatts = 2 and i.indkey[0] = ae.attnum and i.indkey[1] = ai.attnum);
  perform test_helpers.assert(v_bad is null, 'UNIQUE (entity_id, id) missing on: ' || coalesce(v_bad, ''));

  -- Every foreign key between two Entity-scoped tables includes entity_id on both sides.
  select string_agg(con.conrelid::regclass || '.' || con.conname, ', ') into v_bad
  from pg_constraint con
  join pg_attribute sa on sa.attrelid = con.conrelid and sa.attname = 'entity_id' and not sa.attisdropped
  join pg_attribute da on da.attrelid = con.confrelid and da.attname = 'entity_id' and not da.attisdropped
  where con.contype = 'f'
    and not (sa.attnum = any (con.conkey) and da.attnum = any (con.confkey));
  perform test_helpers.assert(v_bad is null, 'FK without entity_id: ' || coalesce(v_bad, ''));

  -- Every mutable table (has `version`) maintains updated_at/updated_by/version through tg_touch.
  select string_agg(c.relname, ', ') into v_bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'version' and not a.attisdropped)
    and not exists (select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid
                    where t.tgrelid = c.oid and not t.tgisinternal and p.proname = 'tg_touch');
  perform test_helpers.assert(v_bad is null, 'tg_touch missing on: ' || coalesce(v_bad, ''));

  -- Business tables that change important state are audited.
  select string_agg(t.name, ', ') into v_bad
  from unnest(array['entities', 'entity_profiles', 'entity_settings', 'profiles', 'roles', 'role_permissions',
                    'entity_memberships', 'membership_permission_overrides', 'approval_rules', 'trusted_devices',
                    'numbering_sequences', 'categories', 'contacts', 'contact_bank_accounts', 'products',
                    'ledger_accounts', 'accounting_periods', 'journal_entries', 'financial_accounts',
                    'payment_channels', 'category_account_mappings', 'transfers', 'reconciliation_sessions',
                    'statement_lines', 'reconciliation_matches',
                    -- P5 sales
                    'invoices', 'invoice_lines', 'invoice_public_links', 'payments', 'payment_allocations',
                    'payment_submissions', 'refunds', 'refund_items',
                    -- P6 purchases
                    'bills', 'bill_lines', 'vendor_payments', 'vendor_payment_allocations', 'expenses',
                    'expense_lines', 'documents', 'document_links']) as t(name)
  where not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                    where tg.tgrelid = ('public.' || t.name)::regclass and not tg.tgisinternal
                      and p.proname = 'tg_audit');
  perform test_helpers.assert(v_bad is null, 'tg_audit missing on: ' || coalesce(v_bad, ''));

  -- Append-only tables refuse UPDATE, DELETE and TRUNCATE.
  select string_agg(t.name, ', ') into v_bad
  from unnest(array['audit_events', 'security_events', 'exchange_rates', 'posting_batches', 'money_movements']) as t(name)
  where (select count(*) from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
         where tg.tgrelid = ('public.' || t.name)::regclass and not tg.tgisinternal
           and p.proname in ('tg_forbid_update', 'tg_forbid_delete')) < 2;
  perform test_helpers.assert(v_bad is null, 'append-only guards missing on: ' || coalesce(v_bad, ''));

  -- Sales documents are never deleted or truncated (drafts' lines are replaced by the draft commands only).
  select string_agg(t.name, ', ') into v_bad
  from unnest(array['invoices', 'invoice_public_links', 'payments', 'payment_allocations', 'payment_submissions',
                    'refunds', 'refund_items', 'invoice_lines']) as t(name)
  where not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                    where tg.tgrelid = ('public.' || t.name)::regclass and not tg.tgisinternal
                      and p.proname = 'tg_forbid_truncate')
     or (t.name <> 'invoice_lines' and not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                    where tg.tgrelid = ('public.' || t.name)::regclass and not tg.tgisinternal
                      and p.proname = 'tg_forbid_delete'));
  perform test_helpers.assert(v_bad is null, 'delete/truncate guards missing on: ' || coalesce(v_bad, ''));

  -- Purchase documents are never deleted or truncated (drafts' lines are replaced by the draft commands only).
  select string_agg(t.name, ', ') into v_bad
  from unnest(array['bills', 'bill_lines', 'vendor_payments', 'vendor_payment_allocations', 'expenses',
                    'expense_lines', 'documents', 'document_links']) as t(name)
  where not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                    where tg.tgrelid = ('public.' || t.name)::regclass and not tg.tgisinternal
                      and p.proname = 'tg_forbid_truncate')
     or (t.name not in ('bill_lines', 'expense_lines') and not exists (select 1 from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
                    where tg.tgrelid = ('public.' || t.name)::regclass and not tg.tgisinternal
                      and p.proname = 'tg_forbid_delete'));
  perform test_helpers.assert(v_bad is null, 'purchase delete/truncate guards missing on: ' || coalesce(v_bad, ''));

  -- Internal schema is invisible to browser roles.
  perform test_helpers.assert(not has_schema_privilege('anon', 'app_private', 'USAGE'), 'anon has no app_private usage');
  perform test_helpers.assert(not has_schema_privilege('authenticated', 'app_private', 'USAGE'),
    'authenticated has no app_private usage');
end
$$;

rollback;
