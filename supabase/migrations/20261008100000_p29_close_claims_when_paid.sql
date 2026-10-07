-- Decision 334: a customer's payment claim ("Saya Sudah Bayar") that is still waiting for confirmation is closed
-- automatically as soon as the invoice is fully paid by another payment (for example the Owner used "Catat
-- Pembayaran" instead of confirming the claim). Before this the claim stayed in "Perlu Perhatian" and on the
-- claims page although nothing was left to pay, and confirming it could only fail.
--
-- The claim that is being confirmed right now is never touched (the payment it creates carries its id), and a
-- claim on an invoice that is only partly paid stays pending. Closing is a rejection with a stated reason, the
-- same status the invoice cancel/void path already uses; the record is kept, never deleted.

create function app_private.tg_allocation_closes_claims() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
declare
  i public.invoices%rowtype;
  v_settled numeric;
begin
  select * into i from public.invoices where id = new.invoice_id and entity_id = new.entity_id;
  if not found then
    return new;
  end if;
  select coalesce(sum(a.amount), 0) into v_settled
  from public.payment_allocations a where a.invoice_id = new.invoice_id and a.status = 'active';
  if v_settled >= i.total then
    update public.payment_submissions s
    set status = 'rejected',
        review_reason = 'Invoice sudah lunas oleh pembayaran lain; klaim ini ditutup otomatis.',
        reviewed_at = now()
    where s.invoice_id = new.invoice_id and s.entity_id = new.entity_id and s.status = 'pending'
      and s.id is distinct from (select p.submission_id from public.payments p where p.id = new.payment_id);
  end if;
  return new;
end
$$;
revoke all on function app_private.tg_allocation_closes_claims() from public;

create trigger tg_closes_claims after insert on public.payment_allocations
  for each row execute function app_private.tg_allocation_closes_claims();

-- Claims that were left pending on an invoice that is already fully paid are closed the same way.
update public.payment_submissions s
set status = 'rejected',
    review_reason = 'Invoice sudah lunas oleh pembayaran lain; klaim ini ditutup otomatis.',
    reviewed_at = now()
from public.invoices i
where s.status = 'pending' and i.id = s.invoice_id and i.entity_id = s.entity_id
  and (select coalesce(sum(a.amount), 0) from public.payment_allocations a
       where a.invoice_id = i.id and a.status = 'active') >= i.total;
