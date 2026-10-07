-- P19 (decision 317): a block of the invoice document can be as wide as its own content ("fit"), so the logo can sit
-- right beside the company name with the invoice title at the far right. Only presentation: the layout rules
-- are the same as before (decision 310) with one more allowed width value.

create or replace function app_private.valid_invoice_layout(p jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog, public as $$
declare
  v_ids constant text[] := array['logo', 'issuer', 'title', 'customer', 'dates', 'lines', 'totals',
                                 'payments', 'instructions', 'notes', 'terms'];
  v_required constant text[] := array['issuer', 'title', 'customer', 'dates', 'lines', 'totals'];
  b jsonb;
  v_seen text[] := '{}';
  v_id text;
begin
  if jsonb_typeof(p) is distinct from 'object' then return false; end if;
  if exists (select 1 from jsonb_object_keys(p) k where k not in ('v', 'blocks', 'logo_size')) then return false; end if;
  if p -> 'v' is distinct from '1'::jsonb then return false; end if;
  if p ? 'logo_size' and (p ->> 'logo_size') not in ('sm', 'md', 'lg') then return false; end if;
  if jsonb_typeof(p -> 'blocks') is distinct from 'array' or jsonb_array_length(p -> 'blocks') <> array_length(v_ids, 1) then
    return false;
  end if;
  for b in select * from jsonb_array_elements(p -> 'blocks') loop
    if jsonb_typeof(b) is distinct from 'object' then return false; end if;
    if exists (select 1 from jsonb_object_keys(b) k where k not in ('key', 'show', 'align', 'width')) then return false; end if;
    v_id := b ->> 'key';
    if v_id is null or not (v_id = any (v_ids)) or v_id = any (v_seen) then return false; end if;
    v_seen := v_seen || v_id;
    if jsonb_typeof(b -> 'show') is distinct from 'boolean' then return false; end if;
    if (b ->> 'align') is null or (b ->> 'align') not in ('left', 'center', 'right') then return false; end if;
    if (b ->> 'width') is null or (b ->> 'width') not in ('full', 'half', 'fit') then return false; end if;
    if v_id = any (v_required) and (b ->> 'show') <> 'true' then return false; end if;
  end loop;
  return true;
end
$$;
