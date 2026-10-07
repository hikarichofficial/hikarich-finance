-- P22 (decision 321): the invoice document is free again. Version 2 of the layout has no grid: every block carries
-- where it is placed in one of three zones (`zone`: head, table or foot; `x` and `w`, its left edge and width as
-- percent of the page, 0-100 with `x + w` at most 100 and `w` at least 8; `y`, whole pixels 0-600 from the top of the
-- zone or from the bottom of the block it follows; `h`, a whole minimum height 0-600 pixels), how its text is aligned
-- (`align`, `valign`), how large it is drawn (`size`: xs, sm, md, lg, xl) and which block it follows (`after`, null or
-- another block of the same zone; no loops, never the item table). The item table is always the whole page in the
-- `table` zone and no other block is. Presentation only: no amount, tax or number can be changed or hidden through
-- it; the rules for who may save and the six required blocks are unchanged. Layouts of version 1 stay valid (they are
-- shown as the standard arrangement), so nothing saved or frozen into an issued invoice is touched.

create or replace function app_private.valid_invoice_layout_v2(p jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog, public as $$
declare
  v_ids constant text[] := array['logo', 'issuer', 'title', 'customer', 'dates', 'lines', 'totals',
                                 'payments', 'instructions', 'notes', 'terms'];
  v_required constant text[] := array['issuer', 'title', 'customer', 'dates', 'lines', 'totals'];
  v_keys constant text[] := array['key', 'show', 'align', 'valign', 'size', 'zone', 'x', 'w', 'y', 'h', 'after'];
  b jsonb;
  v_seen text[] := '{}';
  v_id text;
  v_k text;
  v_zone text;
  v_x numeric;
  v_w numeric;
  v_after jsonb := '{}'::jsonb;
  v_zones jsonb := '{}'::jsonb;
  v_cur text;
  v_next text;
  v_hops int;
begin
  if jsonb_typeof(p) is distinct from 'object' then return false; end if;
  if exists (select 1 from jsonb_object_keys(p) k where k not in ('v', 'blocks')) then return false; end if;
  if p -> 'v' is distinct from '2'::jsonb then return false; end if;
  if jsonb_typeof(p -> 'blocks') is distinct from 'array' or jsonb_array_length(p -> 'blocks') <> array_length(v_ids, 1) then
    return false;
  end if;
  for b in select * from jsonb_array_elements(p -> 'blocks') loop
    if jsonb_typeof(b) is distinct from 'object' then return false; end if;
    if exists (select 1 from jsonb_object_keys(b) k where not (k = any (v_keys))) then return false; end if;
    foreach v_k in array v_keys loop
      if not (b ? v_k) then return false; end if;
    end loop;
    v_id := b ->> 'key';
    if jsonb_typeof(b -> 'key') is distinct from 'string' or not (v_id = any (v_ids)) or v_id = any (v_seen) then return false; end if;
    v_seen := v_seen || v_id;
    if jsonb_typeof(b -> 'show') is distinct from 'boolean' then return false; end if;
    if v_id = any (v_required) and (b ->> 'show') <> 'true' then return false; end if;
    if jsonb_typeof(b -> 'align') is distinct from 'string' or (b ->> 'align') not in ('left', 'center', 'right') then return false; end if;
    if jsonb_typeof(b -> 'valign') is distinct from 'string' or (b ->> 'valign') not in ('top', 'middle', 'bottom') then return false; end if;
    if jsonb_typeof(b -> 'size') is distinct from 'string' or (b ->> 'size') not in ('xs', 'sm', 'md', 'lg', 'xl') then return false; end if;
    if jsonb_typeof(b -> 'zone') is distinct from 'string' or (b ->> 'zone') not in ('head', 'table', 'foot') then return false; end if;
    v_zone := b ->> 'zone';
    if (v_id = 'lines') <> (v_zone = 'table') then return false; end if;
    if jsonb_typeof(b -> 'x') is distinct from 'number' or jsonb_typeof(b -> 'w') is distinct from 'number'
       or jsonb_typeof(b -> 'y') is distinct from 'number' or jsonb_typeof(b -> 'h') is distinct from 'number' then return false; end if;
    v_x := (b ->> 'x')::numeric;
    v_w := (b ->> 'w')::numeric;
    if v_x not between 0 and 100 or v_w not between 8 and 100 or v_x + v_w > 100 then return false; end if;
    if v_id = 'lines' and (v_x <> 0 or v_w <> 100) then return false; end if;
    if (b ->> 'y')::numeric <> trunc((b ->> 'y')::numeric) or (b ->> 'y')::numeric not between 0 and 600 then return false; end if;
    if (b ->> 'h')::numeric <> trunc((b ->> 'h')::numeric) or (b ->> 'h')::numeric not between 0 and 600 then return false; end if;
    if jsonb_typeof(b -> 'after') not in ('null', 'string') then return false; end if;
    if jsonb_typeof(b -> 'after') = 'string' then
      if (b ->> 'after') = v_id or (b ->> 'after') = 'lines' or v_id = 'lines' or not ((b ->> 'after') = any (v_ids)) then return false; end if;
      v_after := v_after || jsonb_build_object(v_id, b ->> 'after');
    end if;
    v_zones := v_zones || jsonb_build_object(v_id, v_zone);
  end loop;
  -- every chain of followers ends at a block of its own (no loop) and stays in one zone
  foreach v_id in array v_ids loop
    v_cur := v_id;
    v_hops := 0;
    while v_after ? v_cur loop
      v_next := v_after ->> v_cur;
      if (v_zones ->> v_next) is distinct from (v_zones ->> v_cur) then return false; end if;
      v_cur := v_next;
      v_hops := v_hops + 1;
      if v_hops > array_length(v_ids, 1) then return false; end if;
    end loop;
  end loop;
  return true;
end
$$;
revoke all on function app_private.valid_invoice_layout_v2(jsonb) from public;

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
  if p -> 'v' = '2'::jsonb then return app_private.valid_invoice_layout_v2(p); end if;
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
