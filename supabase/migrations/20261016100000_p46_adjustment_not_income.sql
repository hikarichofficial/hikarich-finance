-- P46 (owner question of 9 October 2026): a Rp 5.000.000 "Penyesuaian Lanjutan" into a revenue account (4100) raised
-- the books but not the tax. The adjustment is a plain journal against a chosen counter account; the tax base (the
-- turnover for PPh Final UMKM, the combined turnover, the personal-tax summary) is built from invoices, marketplace
-- settlements and recorded income ("Catat Pendapatan"), never from a free journal. So an adjustment may not book
-- income at all: revenue, revenue-reduction and other-income accounts are refused here, and the screen sends the user
-- to Penjualan > Catat Pendapatan, which makes the same journal AND reaches the tax base.
-- record_balance_adjustment is patched in place (exact text replacement of the live definition, count-checked), so
-- whatever earlier migrations changed in it is kept.
do $patch$
declare
  v_def text;
  v_old constant text := E'  select base_currency into v_base from public.entities where id = p_entity;';
  v_new constant text := E'  if v_counter.account_class in (''revenue'', ''contra_revenue'', ''other_income'') then
    raise exception ''INVALID: an adjustment cannot book income; record it with Catat Pendapatan so it reaches the tax''
      using errcode = ''invalid_parameter_value'';
  end if;

' || v_old;
begin
  v_def := pg_get_functiondef(
    'public.record_balance_adjustment(uuid, text, uuid, text, numeric, numeric, date, uuid, text)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'P46: expected exactly one patch point in record_balance_adjustment';
  end if;
  execute replace(v_def, v_old, v_new);
end
$patch$;
