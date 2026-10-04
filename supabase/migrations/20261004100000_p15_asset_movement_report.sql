-- Asset Movement/Disposal report (Step 12 report catalogue; tracked as an open item since decision 178, still
-- open through decision 200, never a schema gap: `asset_events` already carries every lifecycle event
-- (`transferred`, `condition_changed`, `split`, `disposed`, `disposal_reversed`, `registered`, `activated`,
-- `cancelled`, `opening_loaded`) and `asset_disposals` already carries the financial detail of a disposal
-- (proceeds, cost/accumulated removed, net book value, gain/loss, journal). This purely-additive RPC reads
-- both, exactly as `asset_depreciation_report`/`asset_control_report` already do for their own slice of the
-- same data -- no new table, no change to any existing table, function or trigger.
--
-- A disposal-type event's `details` jsonb carries the disposal row's own id under the key `disposal` (set by
-- `app_private.asset_event` at the two call sites in `20260926100300_p8_asset_lifecycle.sql`), so the join
-- below is exact, not a guess from free text.
create function public.asset_movement_report(
  p_entity uuid, p_from date default null, p_to date default null, p_limit integer default 500)
returns table (
  asset_id uuid, asset_code text, asset_name text, event_date date, event_type text, description text,
  proceeds text, cost_removed text, accumulated_removed text, net_book_value text, gain_loss text,
  journal_id uuid, disposal_status text
)
language plpgsql stable security definer set search_path = pg_catalog, public as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = 'invalid_authorization_specification';
  end if;
  if not app_authz.has_permission(p_entity, 'assets.view') then
    raise exception 'FORBIDDEN: missing assets.view' using errcode = 'insufficient_privilege';
  end if;
  return query
  select f.id, f.asset_code, f.name, ev.event_date, ev.event_type,
         case ev.event_type
           when 'transferred' then 'Dipindahkan: ' || coalesce(ev.details ->> 'from_location', '-') || ' -> '
                                    || coalesce(ev.details ->> 'to_location', '-')
           when 'condition_changed' then 'Kondisi berubah: ' || coalesce(ev.details ->> 'from', '-') || ' -> '
                                          || coalesce(ev.details ->> 'to', '-')
           when 'split' then 'Dipecah menjadi aset baru'
           when 'disposed' then 'Dilepas (' || coalesce(d.disposal_type, ev.details ->> 'type') || ')'
           when 'disposal_reversed' then 'Pelepasan dibatalkan (diaktifkan kembali)'
           when 'registered' then 'Didaftarkan dari dokumen pembelian'
           when 'activated' then 'Diaktifkan (mulai dipakai)'
           when 'cancelled' then 'Dibatalkan'
           when 'opening_loaded' then 'Dimuat sebagai saldo awal (migrasi)'
           else ev.event_type
         end,
         d.proceeds::text, d.cost_removed::text, d.accumulated_removed::text, d.net_book_value::text,
         d.gain_loss::text, d.journal_id, d.status
  from public.asset_events ev
  join public.fixed_assets f on f.id = ev.asset_id and f.entity_id = ev.entity_id
  left join public.asset_disposals d on d.entity_id = ev.entity_id and d.id = nullif(ev.details ->> 'disposal', '')::uuid
  where ev.entity_id = p_entity
    and ev.event_type in ('transferred', 'condition_changed', 'split', 'disposed', 'disposal_reversed',
                           'registered', 'activated', 'cancelled', 'opening_loaded')
    and (p_from is null or ev.event_date >= p_from)
    and (p_to is null or ev.event_date <= p_to)
  order by ev.event_date desc, ev.created_at desc
  limit least(greatest(coalesce(p_limit, 500), 1), 5000);
end
$$;

revoke all on function public.asset_movement_report(uuid, date, date, integer) from public, anon;
grant execute on function public.asset_movement_report(uuid, date, date, integer) to authenticated;
