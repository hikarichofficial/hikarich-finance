-- Decision 425 (OWNER, 21 October 2026): the bot can run the sales operations of the website -- find or create a customer,
-- issue an invoice, record the payment, look an invoice up -- always after the layered verification in the chat.
-- Same delegate model as decisions 422-424: each function is callable by the service role only, acts as the paired
-- user and calls the website's own commands, so every permission check, period guard, maker-checker rule and audit
-- entry still runs. Nothing here can do more than the user could do on the website. Closing or reopening periods,
-- roles and access, backups and the bot's own settings are NOT reachable from the bot.

-- What a sales operation needs to know about an Entity: the receiving accounts and the payment links an invoice may carry.
create function public.telegram_sales_context(p_link uuid, p_entity uuid) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_out jsonb;
begin
  perform app_private.telegram_act_as(p_link);
  if not app_authz.has_permission(p_entity, 'invoices.view') then
    raise exception 'FORBIDDEN: missing invoices.view' using errcode = 'insufficient_privilege';
  end if;
  select jsonb_build_object(
    'today', app_private.entity_today(p_entity),
    'currency', app_private.entity_base_currency(p_entity),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'currency', a.currency)
                                           order by a.name)
                          from public.financial_accounts a where a.entity_id = p_entity and a.is_active), '[]'::jsonb),
    'channels', coalesce((select jsonb_agg(jsonb_build_object(
                            'id', ch.id, 'name', ch.name, 'kind', ch.method_kind,
                            'has_url', ch.payment_url is not null, 'account_id', ch.settlement_financial_account_id)
                                           order by ch.name)
                          from public.payment_channels ch where ch.entity_id = p_entity and ch.is_active), '[]'::jsonb))
    into v_out;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return v_out;
end
$$;

-- Customers that may be the one meant. 'same_name' is the website's own suspected-duplicate rule; 'like' is a looser
-- match on part of the name, offered so the owner can pick instead of creating a second record.
create function public.telegram_sales_customers(p_link uuid, p_entity uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_name text := lower(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'));
  v_like text;
  v_out jsonb;
begin
  if length(v_name) < 2 or length(v_name) > 200 then
    raise exception 'INVALID: a customer name of 2 to 200 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  v_like := '%' || replace(replace(replace(v_name, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  perform app_private.telegram_act_as(p_link);
  if not app_authz.has_permission(p_entity, 'contacts.view') then
    raise exception 'FORBIDDEN: missing contacts.view' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.display_name, 'email', c.email, 'kind', c.kind,
           'severity', case when c.normalized_name = v_name then 'same_name' else 'like' end)
           order by (c.normalized_name = v_name) desc, c.display_name), '[]'::jsonb)
    into v_out
  from (select * from public.contacts c0
        where c0.entity_id = p_entity and c0.kind in ('customer', 'both') and c0.status = 'active'
          and (c0.normalized_name = v_name or c0.normalized_name like v_like)
        order by (c0.normalized_name = v_name) desc, c0.display_name
        limit 8) c;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return v_out;
end
$$;

create function public.telegram_sales_create_customer(
  p_link uuid, p_entity uuid, p_key text, p_name text, p_email text, p_phone text, p_allow_similar boolean)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_id uuid;
begin
  if p_key is null or length(btrim(p_key)) < 8 or length(p_key) > 100 then
    raise exception 'INVALID: an idempotency key of 8 to 100 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.telegram_act_as(p_link);
  v_id := public.create_contact(p_entity, p_key, 'customer', p_name, nullif(btrim(coalesce(p_email, '')), ''),
                                nullif(btrim(coalesce(p_phone, '')), ''), null, null, null, null, null,
                                'Dibuat lewat Telegram', coalesce(p_allow_similar, false));
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return v_id;
end
$$;

-- Creates the draft and issues it in one transaction: if issuing is refused, no draft is left behind. Returns the number
-- and the token of the public page (the page carries the invoice's own payment link and, later, its receipts).
create function public.telegram_sales_issue_invoice(
  p_link uuid, p_entity uuid, p_key text, p_customer uuid, p_issue date, p_due date, p_lines jsonb,
  p_channel uuid, p_account uuid, p_note text)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_id uuid;
  v_token text;
  i public.invoices%rowtype;
begin
  if p_key is null or length(btrim(p_key)) < 8 or length(p_key) > 90 then
    raise exception 'INVALID: an idempotency key of 8 to 90 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.telegram_act_as(p_link);
  v_id := public.create_invoice_draft(p_entity, p_key || ':d', p_customer, p_issue, p_due, p_lines, null, null,
                                      nullif(btrim(coalesce(p_note, '')), ''), null, null, 'Dibuat lewat Telegram',
                                      p_account, p_channel);
  perform public.issue_invoice(v_id, p_key || ':i');
  select * into i from public.invoices where id = v_id;
  if app_authz.has_permission(p_entity, 'invoices.regenerate_link') then
    select l.token into v_token from public.invoice_public_link(v_id) l;
  end if;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return jsonb_build_object('invoice_id', i.id, 'number', i.invoice_number, 'status', i.status, 'total', i.total::text,
                            'currency', i.currency, 'due_date', i.due_date, 'token', v_token);
end
$$;

-- Looks an issued invoice up by its number among the Entities the user may view. Shows what the website shows: the
-- derived settlement status, what is outstanding, the receipts, and the token of the public page when the user may share it.
create function public.telegram_sales_find_invoice(p_link uuid, p_number text) returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  v_number text := upper(btrim(coalesce(p_number, '')));
  v_out jsonb;
begin
  if length(v_number) < 4 or length(v_number) > 40 then
    raise exception 'INVALID: an invoice number such as INV-001-0007 is required' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.telegram_act_as(p_link);
  select coalesce(jsonb_agg(jsonb_build_object(
           'invoice_id', i.id, 'entity_id', i.entity_id, 'entity_name', coalesce(e.brand_name, e.legal_name),
           'entity_type', e.entity_type, 'number', i.invoice_number, 'status', i.status,
           'customer_id', i.customer_id, 'customer', c.display_name, 'currency', i.currency,
           'total', i.total::text, 'settled', s.settled::text,
           'outstanding', case when i.status = 'issued' then (i.total - s.settled)::text else '0' end,
           'settlement', case when i.status <> 'issued' then null
                              when i.total - s.settled = 0 then 'paid'
                              when s.settled = 0 then 'unpaid' else 'partial' end,
           'due_date', i.due_date, 'overdue', i.status = 'issued' and i.total - s.settled > 0
                                              and i.due_date < app_private.entity_today(i.entity_id),
           'can_record_payment', app_authz.has_permission(i.entity_id, 'invoices.confirm_payment'),
           'token', case when app_authz.has_permission(i.entity_id, 'invoices.regenerate_link')
                         then (select l.token from public.invoice_public_links l
                               where l.invoice_id = i.id order by (l.status = 'active') desc, l.created_at desc limit 1) end,
           'receipts', coalesce((select jsonb_agg(jsonb_build_object('number', p.payment_number, 'date', p.payment_date,
                                                                    'amount', a.amount::text) order by p.payment_date, p.payment_number)
                                 from public.payment_allocations a join public.payments p on p.id = a.payment_id
                                 where a.invoice_id = i.id and a.status = 'active'), '[]'::jsonb))
           order by e.legal_name), '[]'::jsonb)
    into v_out
  from public.invoices i
  join public.entities e on e.id = i.entity_id
  join public.contacts c on c.id = i.customer_id
  cross join lateral app_private.invoice_settled(i.id) s
  where upper(i.invoice_number) = v_number
    and app_authz.has_permission(i.entity_id, 'invoices.view');
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return v_out;
end
$$;

-- Records that a customer paid an invoice (the website's "Catat Pembayaran"): posts to the ledger and moves the derived status.
create function public.telegram_sales_record_payment(
  p_link uuid, p_key text, p_invoice uuid, p_account uuid, p_date date, p_amount numeric)
returns jsonb
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub text := current_setting('request.jwt.claim.sub', true);
  i public.invoices%rowtype;
  v_payment uuid;
  v_number text;
  v_settled numeric;
  v_token text;
begin
  if p_key is null or length(btrim(p_key)) < 8 or length(p_key) > 100 then
    raise exception 'INVALID: an idempotency key of 8 to 100 characters is required' using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.telegram_act_as(p_link);
  select * into i from public.invoices where id = p_invoice;
  if not found or not app_authz.has_permission(i.entity_id, 'invoices.view') then
    raise exception 'FORBIDDEN: that invoice is not available to this account' using errcode = 'insufficient_privilege';
  end if;
  v_payment := public.record_payment(
    i.entity_id, p_key, i.customer_id, p_account, p_date, p_amount,
    jsonb_build_array(jsonb_build_object('invoice_id', i.id, 'amount', p_amount::text)),
    null, null, null, null, false, 'Dicatat lewat Telegram');
  select p.payment_number into v_number from public.payments p where p.id = v_payment;
  select s.settled into v_settled from app_private.invoice_settled(i.id) s;
  if app_authz.has_permission(i.entity_id, 'invoices.regenerate_link') then
    select l.token into v_token from public.invoice_public_link(i.id) l;
  end if;
  perform app_private.telegram_restore_claims(v_claims, v_sub);
  return jsonb_build_object(
    'payment_id', v_payment, 'receipt_number', v_number, 'invoice_number', i.invoice_number,
    'settled', v_settled::text, 'outstanding', (i.total - v_settled)::text,
    'settlement', case when i.total - v_settled = 0 then 'paid' when v_settled = 0 then 'unpaid' else 'partial' end,
    'token', v_token);
end
$$;

revoke all on function public.telegram_sales_context(uuid, uuid) from public, anon, authenticated;
revoke all on function public.telegram_sales_customers(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.telegram_sales_create_customer(uuid, uuid, text, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.telegram_sales_issue_invoice(uuid, uuid, text, uuid, date, date, jsonb, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.telegram_sales_find_invoice(uuid, text) from public, anon, authenticated;
revoke all on function public.telegram_sales_record_payment(uuid, text, uuid, uuid, date, numeric) from public, anon, authenticated;
grant execute on function public.telegram_sales_context(uuid, uuid) to service_role;
grant execute on function public.telegram_sales_customers(uuid, uuid, text) to service_role;
grant execute on function public.telegram_sales_create_customer(uuid, uuid, text, text, text, text, boolean) to service_role;
grant execute on function public.telegram_sales_issue_invoice(uuid, uuid, text, uuid, date, date, jsonb, uuid, uuid, text) to service_role;
grant execute on function public.telegram_sales_find_invoice(uuid, text) to service_role;
grant execute on function public.telegram_sales_record_payment(uuid, text, uuid, uuid, date, numeric) to service_role;
