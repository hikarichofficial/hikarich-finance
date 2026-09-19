-- P2 (Step 15 §6): Row Level Security policies and browser privileges (Step 06 §5, §6, §11).
--
-- Model
--   * `anon` gets nothing, anywhere.
--   * `authenticated` gets SELECT on tables it may legitimately read (RLS decides which rows) and, for the
--     master-data tables below, INSERT/UPDATE/DELETE that RLS also constrains. All financial commands
--     (journals, periods, numbering, memberships, audit, ...) have NO browser write privilege: they run
--     through trusted server code and database functions (Step 13 §5/§12).
--   * Sensitive columns (tax identifiers, account numbers) are withheld with column privileges, so they
--     cannot be selected or written by browser roles at all; they are revealed only through audited RPCs.
--   * Tables with RLS enabled and no policy (idempotency, outbox, counters) stay fully closed.

-- ------------------------------------------------------------ helper procedures
create procedure app_private.expose_select(rel regclass, hidden text[] default array[]::text[])
language plpgsql as $$
declare
  v_cols text;
begin
  if cardinality(hidden) = 0 then
    execute format('grant select on %s to authenticated', rel);
    return;
  end if;
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_cols
  from pg_attribute a
  where a.attrelid = rel and a.attnum > 0 and not a.attisdropped and a.attname <> all (hidden);
  execute format('grant select (%s) on %s to authenticated', v_cols, rel);
end
$$;

-- System-managed columns are never writable by browser roles; neither are generated columns.
create procedure app_private.expose_write(rel regclass, hidden text[] default array[]::text[])
language plpgsql as $$
declare
  v_insert text;
  v_update text;
begin
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_insert
  from pg_attribute a
  where a.attrelid = rel and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
    and a.attname <> all (array['created_at', 'created_by', 'updated_at', 'updated_by', 'version'] || hidden);
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into v_update
  from pg_attribute a
  where a.attrelid = rel and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
    and a.attname <> all (array['id', 'entity_id', 'created_at', 'created_by', 'updated_at', 'updated_by', 'version'] || hidden);
  execute format('grant insert (%s) on %s to authenticated', v_insert, rel);
  execute format('grant update (%s) on %s to authenticated', v_update, rel);
  execute format('grant delete on %s to authenticated', rel);
end
$$;

-- ------------------------------------------------------------ reference data (any active user)
call app_private.expose_select('public.currencies');
create policy currencies_select on public.currencies for select to authenticated
  using (app_authz.is_active_user());

call app_private.expose_select('public.exchange_rates');
create policy exchange_rates_select on public.exchange_rates for select to authenticated
  using (app_authz.is_active_user());

call app_private.expose_select('public.permissions');
create policy permissions_select on public.permissions for select to authenticated
  using (app_authz.is_active_user());

call app_private.expose_select('public.roles');
create policy roles_select on public.roles for select to authenticated
  using (app_authz.is_active_user());

call app_private.expose_select('public.role_permissions');
create policy role_permissions_select on public.role_permissions for select to authenticated
  using (app_authz.is_active_user());

call app_private.expose_select('public.coa_templates');
create policy coa_templates_select on public.coa_templates for select to authenticated
  using (app_authz.is_active_user());

call app_private.expose_select('public.coa_template_accounts');
create policy coa_template_accounts_select on public.coa_template_accounts for select to authenticated
  using (app_authz.is_active_user());

-- ------------------------------------------------------------ identity and Entity access
-- Own row always; other users only for administrators of a shared Entity.
call app_private.expose_select('public.profiles');
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or app_authz.shares_entity_with(id, 'users.view'));

call app_private.expose_select('public.entities');
create policy entities_select on public.entities for select to authenticated
  using (app_authz.is_member(id));

call app_private.expose_select('public.entity_profiles');
create policy entity_profiles_select on public.entity_profiles for select to authenticated
  using (app_authz.is_member(entity_id));

call app_private.expose_select('public.entity_settings');
create policy entity_settings_select on public.entity_settings for select to authenticated
  using (app_authz.has_permission(entity_id, 'settings.view'));

-- A user may always see their own membership rows (needed to discover which Entities they can enter);
-- administrators see the memberships of their Entity.
call app_private.expose_select('public.entity_memberships');
create policy entity_memberships_select on public.entity_memberships for select to authenticated
  using (user_id = auth.uid() or app_authz.has_permission(entity_id, 'users.view'));

call app_private.expose_select('public.membership_permission_overrides');
create policy membership_overrides_select on public.membership_permission_overrides for select to authenticated
  using (exists (
    select 1 from public.entity_memberships m
    where m.id = membership_id
      and (m.user_id = auth.uid() or app_authz.has_permission(m.entity_id, 'users.view'))));

call app_private.expose_select('public.approval_rules');
create policy approval_rules_select on public.approval_rules for select to authenticated
  using (app_authz.has_permission(entity_id, 'settings.view'));

-- Security Center data (Step 06 §6): each user sees their own devices/events; OWNER-level holders of
-- `security.view` see those of their Entity. The device fingerprint hash is never exposed.
call app_private.expose_select('public.trusted_devices', array['fingerprint_hash']);
create policy trusted_devices_select on public.trusted_devices for select to authenticated
  using (user_id = auth.uid() or app_authz.shares_entity_with(user_id, 'security.view'));

call app_private.expose_select('public.security_events');
create policy security_events_select on public.security_events for select to authenticated
  using (user_id = auth.uid()
         or (entity_id is not null and app_authz.has_permission(entity_id, 'security.view')));

call app_private.expose_select('public.audit_events');
create policy audit_events_select on public.audit_events for select to authenticated
  using ((entity_id is not null and app_authz.has_permission(entity_id, 'audit.view'))
         or (entity_id is null and app_authz.has_any_permission('security.view')));

-- ------------------------------------------------------------ numbering (read-only for browser roles)
call app_private.expose_select('public.numbering_sequences');
create policy numbering_sequences_select on public.numbering_sequences for select to authenticated
  using (app_authz.has_permission(entity_id, 'settings.view'));

call app_private.expose_select('public.issued_document_numbers');
create policy issued_numbers_select on public.issued_document_numbers for select to authenticated
  using (app_authz.has_permission(entity_id, 'settings.view'));

-- ------------------------------------------------------------ master data with browser writes
-- Categories: readable by every member of the Entity, managed with `categories.manage`.
call app_private.expose_select('public.categories');
call app_private.expose_write('public.categories');
create policy categories_select on public.categories for select to authenticated
  using (app_authz.is_member(entity_id));
create policy categories_insert on public.categories for insert to authenticated
  with check (app_authz.has_permission(entity_id, 'categories.manage'));
create policy categories_update on public.categories for update to authenticated
  using (app_authz.has_permission(entity_id, 'categories.manage'))
  with check (app_authz.has_permission(entity_id, 'categories.manage'));
create policy categories_delete on public.categories for delete to authenticated
  using (app_authz.has_permission(entity_id, 'categories.manage'));

-- Contacts: the tax identifier is withheld (revealed through `reveal_sensitive`).
call app_private.expose_select('public.contacts', array['tax_identifier']);
call app_private.expose_write('public.contacts', array['tax_identifier']);
create policy contacts_select on public.contacts for select to authenticated
  using (app_authz.has_permission(entity_id, 'contacts.view'));
create policy contacts_insert on public.contacts for insert to authenticated
  with check (app_authz.has_permission(entity_id, 'contacts.create'));
create policy contacts_update on public.contacts for update to authenticated
  using (app_authz.has_permission(entity_id, 'contacts.edit'))
  with check (app_authz.has_permission(entity_id, 'contacts.edit'));
create policy contacts_delete on public.contacts for delete to authenticated
  using (app_authz.has_permission(entity_id, 'contacts.archive'));

-- Bank details of contacts are managed by trusted server code only (account numbers are sensitive).
call app_private.expose_select('public.contact_bank_accounts', array['account_number']);
create policy contact_bank_accounts_select on public.contact_bank_accounts for select to authenticated
  using (app_authz.has_permission(entity_id, 'contacts.view'));

call app_private.expose_select('public.products');
call app_private.expose_write('public.products');
create policy products_select on public.products for select to authenticated
  using (app_authz.has_permission(entity_id, 'products.view'));
create policy products_insert on public.products for insert to authenticated
  with check (app_authz.has_permission(entity_id, 'products.create'));
create policy products_update on public.products for update to authenticated
  using (app_authz.has_permission(entity_id, 'products.edit'))
  with check (app_authz.has_permission(entity_id, 'products.edit'));
create policy products_delete on public.products for delete to authenticated
  using (app_authz.has_permission(entity_id, 'products.archive'));

call app_private.expose_select('public.product_aliases');
call app_private.expose_write('public.product_aliases');
create policy product_aliases_select on public.product_aliases for select to authenticated
  using (app_authz.has_permission(entity_id, 'products.view'));
create policy product_aliases_insert on public.product_aliases for insert to authenticated
  with check (app_authz.has_permission(entity_id, 'products.edit'));
create policy product_aliases_update on public.product_aliases for update to authenticated
  using (app_authz.has_permission(entity_id, 'products.edit'))
  with check (app_authz.has_permission(entity_id, 'products.edit'));
create policy product_aliases_delete on public.product_aliases for delete to authenticated
  using (app_authz.has_permission(entity_id, 'products.edit'));

-- ------------------------------------------------------------ accounting (read-only for browser roles)
call app_private.expose_select('public.ledger_accounts');
create policy ledger_accounts_select on public.ledger_accounts for select to authenticated
  using (app_authz.has_permission(entity_id, 'accounting.view'));

call app_private.expose_select('public.accounting_periods');
create policy accounting_periods_select on public.accounting_periods for select to authenticated
  using (app_authz.has_permission(entity_id, 'accounting.view'));

call app_private.expose_select('public.posting_batches');
create policy posting_batches_select on public.posting_batches for select to authenticated
  using (app_authz.has_permission(entity_id, 'accounting.view'));

call app_private.expose_select('public.journal_entries');
create policy journal_entries_select on public.journal_entries for select to authenticated
  using (app_authz.has_permission(entity_id, 'accounting.view'));

call app_private.expose_select('public.journal_lines');
create policy journal_lines_select on public.journal_lines for select to authenticated
  using (app_authz.has_permission(entity_id, 'accounting.view'));

call app_private.expose_select('public.category_account_mappings');
create policy category_account_mappings_select on public.category_account_mappings for select to authenticated
  using (app_authz.has_permission(entity_id, 'accounting.view'));

-- ------------------------------------------------------------ money (read-only for browser roles)
call app_private.expose_select('public.financial_accounts', array['account_number']);
create policy financial_accounts_select on public.financial_accounts for select to authenticated
  using (app_authz.has_permission(entity_id, 'money.view'));

call app_private.expose_select('public.payment_channels');
create policy payment_channels_select on public.payment_channels for select to authenticated
  using (app_authz.has_permission(entity_id, 'money.view'));

-- idempotency_keys, outbox_events and numbering_counters intentionally keep RLS enabled with no policy
-- and no browser privilege: they are internal to trusted server code.

revoke all on all functions in schema app_private from public;
revoke all on all procedures in schema app_private from public;
