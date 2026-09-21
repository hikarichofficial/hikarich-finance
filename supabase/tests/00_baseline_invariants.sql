-- Database invariants that must hold after EVERY migration (Step 14 §6-7, Step 15 P1 gate).
-- Each block raises an exception on failure; psql runs with ON_ERROR_STOP.

-- 1. The baseline extension exists.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pgcrypto') then
    raise exception 'INVARIANT FAILED: pgcrypto extension missing';
  end if;
end
$$;

-- 2. RLS is enabled on every application table in `public` (Step 14 (Supabase security) / Step 06).
--    Vacuously true in P0 (no tables yet); enforced automatically from P1 on.
do $$
declare
  offenders text;
begin
  select string_agg(format('%I.%I', n.nspname, c.relname), ', ')
    into offenders
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and not c.relrowsecurity;
  if offenders is not null then
    raise exception 'INVARIANT FAILED: RLS disabled on: %', offenders;
  end if;
end
$$;

-- 3. Browser-facing roles hold no direct write privilege on any `public` table unless it is on the
--    reviewed allowlist below (Step 13 (command boundary): financial commands are never direct browser
--    writes). The allowlist is the master-data set of Step 06 §5, whose writes RLS constrains per Entity
--    and capability (P2). `anon` never holds any privilege at all.
do $$
declare
  offenders text;
  allowlist constant text[] := array['categories', 'contacts', 'products', 'product_aliases'];
begin
  select string_agg(format('%s on %s', p.priv, c.relname), ', ')
    into offenders
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  cross join lateral (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) as p(priv)
  where c.relkind in ('r', 'p')
    and c.relname <> all (allowlist)
    and (
      (p.priv in ('INSERT', 'UPDATE') and has_any_column_privilege('authenticated', c.oid, p.priv))
      or (p.priv not in ('INSERT', 'UPDATE') and has_table_privilege('authenticated', c.oid, p.priv))
    );
  if offenders is not null then
    raise exception 'INVARIANT FAILED: browser roles have write grants: %', offenders;
  end if;

  select string_agg(format('%s on %s', p.priv, c.relname), ', ')
    into offenders
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  cross join lateral (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) as p(priv)
  where c.relkind in ('r', 'p', 'v', 'm')
    and (
      (p.priv in ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES') and has_any_column_privilege('anon', c.oid, p.priv))
      or has_table_privilege('anon', c.oid, p.priv)
    );
  if offenders is not null then
    raise exception 'INVARIANT FAILED: anon has table privileges: %', offenders;
  end if;
end
$$;

-- 4. Function exposure (Step 06 §12, Step 14): browser roles execute only the reviewed RPCs; `anon`
--    executes nothing; nothing in the internal schemas is reachable.
do $$
declare
  offenders text;
  rpc_allowlist constant text[] := array['my_access', 'assign_membership', 'set_membership_status',
                                         'set_user_active', 'set_permission_override', 'reveal_sensitive',
                                         -- P3 accounting core
                                         'create_journal_draft', 'discard_journal_draft', 'post_journal',
                                         'reverse_journal', 'trial_balance', 'period_close_checks',
                                         'begin_period_close', 'cancel_period_close', 'close_period',
                                         'reopen_period', 'post_opening_balances', 'complete_opening_balances',
                                         -- P4 money, transfers and reconciliation
                                         'money_control', 'account_activity', 'create_financial_account',
                                         'update_financial_account', 'set_financial_account_active',
                                         'record_balance_adjustment', 'create_transfer', 'confirm_transfer',
                                         'cancel_transfer', 'reverse_transfer', 'create_reconciliation_session',
                                         'discard_reconciliation_session', 'add_statement_lines',
                                         'match_statement_line', 'unmatch_statement_line', 'exclude_statement_line',
                                         'include_statement_line', 'complete_reconciliation',
                                         'reopen_reconciliation', 'reconciliation_workspace',
                                         'reconciliation_candidates', 'unreconciled_movements',
                                         'reconciliation_status',
                                         -- P5 sales, receivables and refunds
                                         'find_contact_duplicates', 'create_contact', 'create_invoice_draft',
                                         'update_invoice_draft', 'issue_invoice', 'invoice_public_link',
                                         'record_payment', 'create_payment_claim', 'confirm_payment_submission',
                                         'reject_payment_submission', 'mark_submission_duplicate',
                                         'apply_payment_credit', 'reverse_credit_application', 'reverse_payment',
                                         'cancel_invoice', 'void_invoice', 'correct_invoice',
                                         'update_invoice_due_date', 'list_invoice_positions', 'ar_control_report',
                                         'create_refund', 'confirm_refund', 'reject_refund', 'cancel_refund',
                                         'reverse_refund', 'payment_refund_options', 'list_payments', 'ar_aging',
                                         'regenerate_invoice_link', 'revoke_invoice_link',
                                         'set_invoice_link_expiry', 'invoice_document', 'payment_receipt_document',
                                         'refund_receipt_document',
                                         -- P6 purchases, payables and direct expenses
                                         'create_bill_draft', 'update_bill_draft', 'submit_bill', 'recall_bill',
                                         'reject_bill', 'approve_bill', 'cancel_bill', 'void_bill', 'correct_bill',
                                         'update_bill_due_date', 'record_vendor_payment', 'reverse_vendor_payment',
                                         'list_bill_positions', 'ap_control_report', 'list_vendor_payments',
                                         'ap_aging', 'find_purchase_duplicates', 'create_expense_draft',
                                         'update_expense_draft', 'submit_expense', 'recall_expense',
                                         'reject_expense', 'confirm_expense', 'cancel_expense', 'reverse_expense',
                                         'correct_expense', 'register_document', 'link_document', 'unlink_document',
                                         'list_document_links', 'list_missing_evidence',
                                         -- P7 tax facts, rules, determination, payments, filings and the calendar
                                         'tax_rule_draft_save', 'tax_rule_publish', 'tax_rule_discard',
                                         'tax_rule_in_force', 'tax_record_entity_profile', 'tax_profile_identifier',
                                         'tax_record_contact_facts', 'tax_record_aggregation_fact',
                                         'tax_engine_activate', 'tax_preview_document', 'tax_override_set',
                                         'tax_override_withdraw', 'tax_confirm_line', 'tax_review_queue',
                                         'tax_record_payment', 'tax_reverse_payment', 'tax_record_filing',
                                         'tax_link_evidence', 'tax_list_evidence', 'tax_reconcile_period',
                                         'tax_period_position', 'tax_list_payments', 'tax_control_report',
                                         'tax_ledger_report', 'tax_final_preview', 'tax_final_compute',
                                         'tax_calendar', 'tax_overview',
                                         -- the three token-scoped functions (also open to `anon`, see below)
                                         'public_invoice_view', 'public_submit_payment_claim',
                                         'public_receipt_view'];
  -- The ONLY functions the anonymous role may execute: each is scoped by an unguessable invoice token (Step 07 §4,
  -- Step 11 §8) and reveals nothing else.
  anon_allowlist constant text[] := array['public_invoice_view', 'public_submit_payment_claim', 'public_receipt_view'];
begin
  select string_agg(format('anon can execute public.%s', p.proname), ', ')
    into offenders
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  where p.prokind = 'f' and has_function_privilege('anon', p.oid, 'EXECUTE')
    and p.proname <> all (anon_allowlist)
    and p.oid not in (select d.objid from pg_depend d where d.deptype = 'e');
  if offenders is not null then
    raise exception 'INVARIANT FAILED: %', offenders;
  end if;

  select string_agg(a.name, ', ') into offenders
  from unnest(anon_allowlist) as a(name)
  where (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
         where p.proname = a.name and has_function_privilege('anon', p.oid, 'EXECUTE')) <> 1;
  if offenders is not null then
    raise exception 'INVARIANT FAILED: the anon token functions are not each executable exactly once: %', offenders;
  end if;

  select string_agg(format('authenticated can execute public.%s', p.proname), ', ')
    into offenders
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  where p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and p.proname <> all (rpc_allowlist)
    and p.oid not in (select d.objid from pg_depend d where d.deptype = 'e');
  if offenders is not null then
    raise exception 'INVARIANT FAILED: %', offenders;
  end if;

  select string_agg(format('%s can use schema %s', r.rolname, n.nspname), ', ')
    into offenders
  from pg_roles r
  join pg_namespace n on n.nspname = 'app_private'
  where r.rolname in ('anon', 'authenticated') and has_schema_privilege(r.rolname, n.oid, 'USAGE');
  if offenders is not null then
    raise exception 'INVARIANT FAILED: %', offenders;
  end if;

  if has_schema_privilege('anon', 'app_authz', 'USAGE') then
    raise exception 'INVARIANT FAILED: anon can use schema app_authz';
  end if;
end
$$;
