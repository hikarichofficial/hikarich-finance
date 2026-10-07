-- P21 (decision 319): the invoice document sits on a grid of twenty-four columns and a lane of the page may hold
-- several blocks stacked on top of each other. The layout may carry `grid` (24, the number of columns its `col` and
-- `span` count in; without it the layout still counts twelve, as saved by P20) and a block may carry `stack`
-- (1-99, its place in its lane from the top). Columns run 1-24 under `grid` 24, else 1-12. Presentation only: no
-- amount, tax or number can be changed or hidden through it; the rules for who may save and the six required
-- blocks are unchanged.

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
  v_cols int := 12;
begin
  if jsonb_typeof(p) is distinct from 'object' then return false; end if;
  if exists (select 1 from jsonb_object_keys(p) k where k not in ('v', 'blocks', 'logo_size', 'grid')) then return false; end if;
  if p -> 'v' is distinct from '1'::jsonb then return false; end if;
  if p ? 'grid' then
    if p -> 'grid' is distinct from '24'::jsonb then return false; end if;
    v_cols := 24;
  end if;
  if p ? 'logo_size' and (p ->> 'logo_size') not in ('sm', 'md', 'lg') then return false; end if;
  if jsonb_typeof(p -> 'blocks') is distinct from 'array' or jsonb_array_length(p -> 'blocks') <> array_length(v_ids, 1) then
    return false;
  end if;
  for b in select * from jsonb_array_elements(p -> 'blocks') loop
    if jsonb_typeof(b) is distinct from 'object' then return false; end if;
    if exists (select 1 from jsonb_object_keys(b) k where k not in ('key', 'show', 'align', 'width', 'col', 'span', 'row', 'stack')) then return false; end if;
    v_id := b ->> 'key';
    if v_id is null or not (v_id = any (v_ids)) or v_id = any (v_seen) then return false; end if;
    v_seen := v_seen || v_id;
    if jsonb_typeof(b -> 'show') is distinct from 'boolean' then return false; end if;
    if (b ->> 'align') is null or (b ->> 'align') not in ('left', 'center', 'right') then return false; end if;
    v_placed := (case when b ? 'col' then 1 else 0 end) + (case when b ? 'span' then 1 else 0 end)
              + (case when b ? 'row' then 1 else 0 end);
    if v_placed = 0 then
      if b ? 'stack' or p ? 'grid' then return false; end if;
      if (b ->> 'width') is null or (b ->> 'width') not in ('full', 'half', 'fit') then return false; end if;
    elsif v_placed = 3 then
      if b ? 'width' and (b ->> 'width') not in ('full', 'half', 'fit') then return false; end if;
      if jsonb_typeof(b -> 'col') is distinct from 'number' or jsonb_typeof(b -> 'span') is distinct from 'number'
         or jsonb_typeof(b -> 'row') is distinct from 'number' then return false; end if;
      if (b ->> 'col')::numeric <> trunc((b ->> 'col')::numeric) or (b ->> 'span')::numeric <> trunc((b ->> 'span')::numeric)
         or (b ->> 'row')::numeric <> trunc((b ->> 'row')::numeric) then return false; end if;
      if (b ->> 'col')::int not between 1 and v_cols or (b ->> 'span')::int not between 1 and v_cols
         or (b ->> 'col')::int + (b ->> 'span')::int > v_cols + 1 or (b ->> 'row')::int not between 1 and 200 then return false; end if;
      if b ? 'stack' then
        if jsonb_typeof(b -> 'stack') is distinct from 'number'
           or (b ->> 'stack')::numeric <> trunc((b ->> 'stack')::numeric)
           or (b ->> 'stack')::int not between 1 and 99 then return false; end if;
      end if;
    else
      return false;
    end if;
    if v_id = any (v_required) and (b ->> 'show') <> 'true' then return false; end if;
  end loop;
  return true;
end
$$;
