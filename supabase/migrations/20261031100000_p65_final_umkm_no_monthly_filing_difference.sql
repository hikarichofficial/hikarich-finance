-- P65 (decision 412): PPh Final UMKM has no monthly return, so a month without a filing is not a difference.
-- The payment with its NTPN is deemed the return (decision 341); the only return is the yearly SPT Tahunan, recorded
-- in the December masa. `tax_period_differences` reported "No filing is recorded for this period" for such a month
-- and the reconciliation then demanded a note for a month that is in order. A filing that IS recorded (the December
-- SPT Tahunan receipt) is still compared with the ledger as before.
create or replace function app_private.tax_period_differences(p_entity uuid, p_type text, p_period date, p_as_of date) returns jsonb
language plpgsql stable set search_path = pg_catalog, public as $$
declare
  f jsonb := app_private.tax_period_figures(p_entity, p_type, p_period, p_as_of);
  v_out jsonb := '[]'::jsonb;
  v_pay numeric := (f ->> 'accrued_payable')::numeric;
  v_asset numeric := (f ->> 'accrued_asset')::numeric;
  v_outstanding numeric := (f ->> 'outstanding_payable')::numeric;
begin
  if f ->> 'filing_id' is null then
    if p_type <> 'final_umkm' then
      v_out := v_out || jsonb_build_object('code', 'filing_missing', 'text', 'No filing is recorded for this period', 'amount', null);
    end if;
  else
    if (f ->> 'reported_tax')::numeric <> v_pay then
      v_out := v_out || jsonb_build_object('code', 'filed_tax_differs',
        'text', format('The filing reports tax of %s; the tax ledger holds %s', trim_scale((f ->> 'reported_tax')::numeric), trim_scale(v_pay)),
        'amount', ((f ->> 'reported_tax')::numeric - v_pay)::text);
    end if;
    if p_type = 'vat' and (f ->> 'reported_credit')::numeric <> v_asset then
      v_out := v_out || jsonb_build_object('code', 'filed_credit_differs',
        'text', format('The filing credits input VAT of %s; the tax ledger holds %s', trim_scale((f ->> 'reported_credit')::numeric), trim_scale(v_asset)),
        'amount', ((f ->> 'reported_credit')::numeric - v_asset)::text);
    end if;
    if (f ->> 'reported_base')::numeric <> (f ->> 'base')::numeric then
      v_out := v_out || jsonb_build_object('code', 'filed_base_differs',
        'text', format('The filing reports a base of %s; the determinations hold %s', trim_scale((f ->> 'reported_base')::numeric), trim_scale((f ->> 'base')::numeric)),
        'amount', ((f ->> 'reported_base')::numeric - (f ->> 'base')::numeric)::text);
    end if;
  end if;
  if v_outstanding > 0 then
    v_out := v_out || jsonb_build_object('code', 'unpaid', 'text', format('%s of the tax for this period is not paid yet', trim_scale(v_outstanding)),
      'amount', v_outstanding::text);
  elsif v_outstanding < 0 then
    v_out := v_out || jsonb_build_object('code', 'overpaid', 'text', format('%s more was paid than the tax ledger holds', trim_scale(-v_outstanding)),
      'amount', v_outstanding::text);
  end if;
  return v_out;
end
$$;
