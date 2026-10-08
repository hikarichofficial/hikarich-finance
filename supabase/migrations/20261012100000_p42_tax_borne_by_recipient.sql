-- OWNER, 8 October 2026 (second message): "kalau kontrak dengan freelancer tersebut adalah 10jt, masak PT saya yang
-- membayar lebih." A contract of Rp 10.000.000 is the company's whole cost. Migration p41 made the income tax an
-- extra cost on top of the contract; this migration puts the posting back: the PAYEE bears the income tax.
--   * the vendor (bill) or the payee (expense, from the account) is paid the total LESS the income tax;
--   * the income tax is a liability to the tax office (credit Tax Payables, same tax ledger and calendar), paid by the
--     company out of the contract amount, so the company's cost is the contract amount and nothing more;
--   * no separate tax expense line (the debit to "Denda & Beban Pajak Lainnya" that p41 added is gone).
-- Production holds no bill or expense with a non-zero withheld_total (checked before this migration), so no posted
-- document changes meaning. The five categories that p41 moved to PPh 23 stay on PPh 23 (decision 362 part 2).

do $$
declare
  v_patch text[][] := array[
    array[$o$add_line(v_lines, v_ap, 0, v_base_total, v_desc,$o$,
          $n$add_line(v_lines, v_ap, 0, v_base_total - v_wht, v_desc,$n$, '1'],
    array[$o$orig_fields(b.currency, v_base, b.total, b.exchange_rate, v_base_total)$o$,
          $n$orig_fields(b.currency, v_base, b.total, b.exchange_rate, v_base_total - v_wht)$n$, '1'],
    array[$o$add_line(v_lines, fa.ledger_account_id, 0, v_base_total, v_desc,$o$,
          $n$add_line(v_lines, fa.ledger_account_id, 0, v_base_total - v_wht, v_desc,$n$, '1'],
    array[$o$orig_fields(x.currency, v_base, x.total, x.exchange_rate, v_base_total)$o$,
          $n$orig_fields(x.currency, v_base, x.total, x.exchange_rate, v_base_total - v_wht)$n$, '1'],
    array[$o$'out', x.total, v_base_total,$o$,
          $n$'out', x.total - v_wht, v_base_total - v_wht,$n$, '1'],
    array[$o$base_total = v_base_total, withheld_total = v_wht,$o$,
          $n$base_total = v_base_total - v_wht, withheld_total = v_wht,$n$, '2'],
    array[$o$'description', 'Income tax payable to the tax office: ' || v_desc);
    v_lines := v_lines || jsonb_build_object(
      'account_key', 'TAX_PENALTY_EXPENSE', 'debit', v_wht, 'credit', 0,
      'description', 'Income tax borne by the company: ' || v_desc);$o$,
          $n$'description', 'Income tax withheld: ' || v_desc);$n$, '2'],
    array[$o$-- The vendor is owed the full total; the income tax is the company's own cost and a liability to the tax office (decision 362).$o$,
          $n$-- What the vendor is owed is the total less the income tax withheld; the withholding is a liability to the tax office.$n$, '1'],
    array[$o$-- The full total leaves the account; the income tax is the company's own cost and a liability to the tax office (decision 362).$o$,
          $n$-- The money that leaves the account is the total less the income tax withheld; the withholding is a liability.$n$, '1'],
    array[$o$'%s is a tax cost of the company, paid to the tax office apart from the vendor: the vendor is paid in full, the amount is credited to Tax Payables, booked as a tax expense on top of the purchase and accrues in the %s ledger for %s.'$o$,
          $n$'%s is withheld from the payee: the vendor is owed that much less, and it is credited to Tax Payables and accrues in the %s ledger for %s. The gross expense is unchanged.'$n$, '1'],
    array[$o$'No income tax is added to this purchase: the vendor is paid the full amount.'$o$,
          $n$'Nothing is withheld: the vendor is owed the full amount.'$n$, '1'],
    array[$o$> b.total or v_base + new.base_ap_amount > b.base_total$o$,
          $n$> b.total - b.withheld_total or v_base + new.base_ap_amount > b.base_total$n$, '1'],
    array[$o$(b.total)::numeric, b.s_settled,
         case when b.is_closed then 0 else (b.total) - b.s_settled end,$o$,
          $n$(b.total - b.withheld_total)::numeric, b.s_settled,
         case when b.is_closed then 0 else (b.total - b.withheld_total) - b.s_settled end,$n$, '1'],
    array[$o$when (b.total) - b.s_settled = 0 then 'paid'$o$,
          $n$when (b.total - b.withheld_total) - b.s_settled = 0 then 'paid'$n$, '1'],
    array[$o$(not b.is_closed and (b.total) - b.s_settled > 0 and b.due_date < v_asof),
         case when not b.is_closed and (b.total) - b.s_settled > 0 and b.due_date$o$,
          $n$(not b.is_closed and (b.total - b.withheld_total) - b.s_settled > 0 and b.due_date < v_asof),
         case when not b.is_closed and (b.total - b.withheld_total) - b.s_settled > 0 and b.due_date$n$, '1'],
    array[$o$b.bill_date, b.total as total, b.base_total, b.exchange_rate,$o$,
          $n$b.bill_date, b.total - b.withheld_total as total, b.base_total, b.exchange_rate,$n$, '1']
  ];
  i integer;
  f record;
  v_n integer;
begin
  for i in 1 .. array_length(v_patch, 1) loop
    v_n := 0;
    for f in
      select p.oid from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('public', 'app_private') and p.prokind = 'f' and position(v_patch[i][1] in p.prosrc) > 0
      order by p.oid
    loop
      execute replace(pg_catalog.pg_get_functiondef(f.oid), v_patch[i][1], v_patch[i][2]);
      v_n := v_n + 1;
    end loop;
    if v_n <> v_patch[i][3]::integer then
      raise exception 'tax-borne-by-recipient patch % expected % function(s), found %', i, v_patch[i][3], v_n;
    end if;
  end loop;
end
$$;
