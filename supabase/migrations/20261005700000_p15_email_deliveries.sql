-- P15: history of e-mails sent from the app ("Riwayat Pengiriman Email"), OWNER request of 5 October 2026: an
-- invoice or a payment receipt can be sent to the customer's e-mail, and the person must be able to see what was
-- sent, to whom and when, and send it again. One append-only row per attempt; nothing here changes money or the
-- books. The row is written only through `record_email_delivery` (direct writes are closed), by someone who may
-- manage the invoice link; anyone who may view invoices can read the history.
create table public.email_deliveries (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.entities (id) on delete restrict,
  kind text not null check (kind in ('invoice', 'payment_receipt')),
  target_id uuid not null,
  recipient text not null check (length(btrim(recipient)) > 0),
  status text not null check (status in ('sent', 'failed')),
  detail text,
  sent_at timestamptz not null default now(),
  sent_by uuid,
  unique (entity_id, id)
);
create index email_deliveries_target_idx on public.email_deliveries (entity_id, kind, target_id, sent_at desc);
create trigger tg_forbid_update before update on public.email_deliveries
  for each row execute function app_private.tg_forbid_update();
create trigger tg_forbid_delete before delete on public.email_deliveries
  for each row execute function app_private.tg_forbid_delete();
create trigger tg_forbid_truncate before truncate on public.email_deliveries
  for each statement execute function app_private.tg_forbid_truncate();
call app_private.secure_table('public.email_deliveries');
call app_private.expose_select('public.email_deliveries');
create policy email_deliveries_select on public.email_deliveries for select to authenticated
  using (app_authz.has_permission(entity_id, 'invoices.view'));

create function public.record_email_delivery(
  p_entity uuid, p_kind text, p_target uuid, p_recipient text, p_status text, p_detail text default null)
returns uuid
language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'invoices.regenerate_link') then
    raise exception 'FORBIDDEN: missing invoices.regenerate_link' using errcode = 'insufficient_privilege';
  end if;
  if p_kind not in ('invoice', 'payment_receipt') or p_status not in ('sent', 'failed')
     or length(btrim(coalesce(p_recipient, ''))) = 0 then
    raise exception 'INVALID: kind, status and recipient are required' using errcode = 'invalid_parameter_value';
  end if;
  if (p_kind = 'invoice' and not exists (select 1 from public.invoices where id = p_target and entity_id = p_entity))
     or (p_kind = 'payment_receipt' and not exists (select 1 from public.payments where id = p_target and entity_id = p_entity)) then
    raise exception 'INVALID: the document does not belong to this Entity' using errcode = 'invalid_parameter_value';
  end if;
  insert into public.email_deliveries (entity_id, kind, target_id, recipient, status, detail, sent_by)
  values (p_entity, p_kind, p_target, btrim(p_recipient), p_status, left(p_detail, 500), auth.uid())
  returning id into v_id;
  return v_id;
end
$$;

revoke all on function public.record_email_delivery(uuid, text, uuid, text, text, text) from public, anon;
grant execute on function public.record_email_delivery(uuid, text, uuid, text, text, text) to authenticated;
