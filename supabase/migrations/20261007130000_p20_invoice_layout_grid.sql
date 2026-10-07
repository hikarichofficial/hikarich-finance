-- P20 (decision 318): the invoice document sits on a grid of twelve columns. Each block of the layout (decision 310)
-- may carry `row` (1-200), `col` (1-12) and `span` (1-12, never past column 12), so the owner can put every block
-- where it belongs and see it on a ruler. The three keys come together (a block has all or none); a block
-- without them still needs the earlier `width` (full, half or fit), and a layout saved before this change stays
-- valid. Presentation only: no amount, tax or number can be changed or hidden through it.

create or replace function app_private.valid_invoice_layout(p jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog, public as $$
declare
  v_ids constant text[] := array['logo', 'issuer', 'title', 'customer', 'dates', 'lines', 'totals',
                                 'payments', 'instructions', 'notes', 'terms'];
  v_required constant text[] := array['issuer', 'title', 'customer', 'dates', 'lines', 'totals'];
  b jsonb;
  v_seen text[] := '{}';
  v_id text;
  v_placed int;
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
    if exists (select 1 from jsonb_object_keys(b) k where k not in ('key', 'show', 'align', 'width', 'col', 'span', 'row')) then return false; end if;
    v_id := b ->> 'key';
    if v_id is null or not (v_id = any (v_ids)) or v_id = any (v_seen) then return false; end if;
    v_seen := v_seen || v_id;
    if jsonb_typeof(b -> 'show') is distinct from 'boolean' then return false; end if;
    if (b ->> 'align') is null or (b ->> 'align') not in ('left', 'center', 'right') then return false; end if;
    v_placed := (case when b ? 'col' then 1 else 0 end) + (case when b ? 'span' then 1 else 0 end)
              + (case when b ? 'row' then 1 else 0 end);
    if v_placed = 0 then
      if (b ->> 'width') is null or (b ->> 'width') not in ('full', 'half', 'fit') then return false; end if;
    elsif v_placed = 3 then
      if b ? 'width' and (b ->> 'width') not in ('full', 'half', 'fit') then return false; end if;
      if jsonb_typeof(b -> 'col') is distinct from 'number' or jsonb_typeof(b -> 'span') is distinct from 'number'
         or jsonb_typeof(b -> 'row') is distinct from 'number' then return false; end if;
      if (b ->> 'col')::numeric <> trunc((b ->> 'col')::numeric) or (b ->> 'span')::numeric <> trunc((b ->> 'span')::numeric)
         or (b ->> 'row')::numeric <> trunc((b ->> 'row')::numeric) then return false; end if;
      if (b ->> 'col')::int not between 1 and 12 or (b ->> 'span')::int not between 1 and 12
         or (b ->> 'col')::int + (b ->> 'span')::int > 13 or (b ->> 'row')::int not between 1 and 200 then return false; end if;
    else
      return false;
    end if;
    if v_id = any (v_required) and (b ->> 'show') <> 'true' then return false; end if;
  end loop;
  return true;
end
$$;
