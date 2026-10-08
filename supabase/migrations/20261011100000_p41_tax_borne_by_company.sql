-- OWNER, 8 October 2026: "jangan gunakan potongan. tapi gunakan bahasa beban pajak untuk PT. dari nominal yang
-- dibayarkan, ada tambahan beban pajak PT sehingga nominalnya akan jadi lebih besar, walaupun pembayaran pada
-- tujuan yang terpisah, 1 provider, 1 nya lagi negara pajak."
--
-- Until now a withholding was taken OUT of what the vendor is paid (vendor owed total - tax). From now the income tax
-- found by the tax engine (PPh 23 / 4(2) / 26) is the company's own cost on top of the purchase:
--   * the vendor (bill) or the payee (expense, from the account) is paid the FULL amount;
--   * the tax is a separate liability to the tax office (credit Tax Payables, same tax ledger and calendar as before);
--   * it is booked as an expense on top of the purchase (debit "Denda & Beban Pajak Lainnya", system key
--     TAX_PENALTY_EXPENSE), so the company's cost is larger by exactly that amount.
-- `withheld_total` keeps its column name and meaning "income tax found on this document"; only what the vendor is owed
-- changes (total, no longer total - withheld_total). Production holds no bill or expense with a non-zero
-- withheld_total (checked before this migration), so no posted document changes meaning.
--
-- Also: PMK 141/PMK.03/2015 lists internet, hosting and data services, software services, advertising and freight /
-- logistics as PPh 23 objects (research of 8 October 2026, docs project note). The five default categories that said
-- "not an object" now say PPh 23 for a domestic vendor; a line's own answer always wins.

-- ------------------------------------------------------------ the posting functions, patched in place
do $$
declare
  v_patch text[][] := array[
    -- bill approval: the vendor is owed the full total
    array[$o$add_line(v_lines, v_ap, 0, v_base_total - v_wht, v_desc,$o$,
          $n$add_line(v_lines, v_ap, 0, v_base_total, v_desc,$n$, '1'],
    array[$o$orig_fields(b.currency, v_base, b.total, b.exchange_rate, v_base_total - v_wht)$o$,
          $n$orig_fields(b.currency, v_base, b.total, b.exchange_rate, v_base_total)$n$, '1'],
    -- expense confirmation: the full total leaves the account
    array[$o$add_line(v_lines, fa.ledger_account_id, 0, v_base_total - v_wht, v_desc,$o$,
          $n$add_line(v_lines, fa.ledger_account_id, 0, v_base_total, v_desc,$n$, '1'],
    array[$o$orig_fields(x.currency, v_base, x.total, x.exchange_rate, v_base_total - v_wht)$o$,
          $n$orig_fields(x.currency, v_base, x.total, x.exchange_rate, v_base_total)$n$, '1'],
    array[$o$'out', x.total - v_wht, v_base_total - v_wht,$o$,
          $n$'out', x.total, v_base_total,$n$, '1'],
    -- both: the stored base total is the full total
    array[$o$base_total = v_base_total - v_wht, withheld_total = v_wht,$o$,
          $n$base_total = v_base_total, withheld_total = v_wht,$n$, '2'],
    -- both: the tax is a liability to the tax office AND the company's own expense
    array[$o$'description', 'Income tax withheld: ' || v_desc);$o$,
          $n$'description', 'Income tax payable to the tax office: ' || v_desc);
    v_lines := v_lines || jsonb_build_object(
      'account_key', 'TAX_PENALTY_EXPENSE', 'debit', v_wht, 'credit', 0,
      'description', 'Income tax borne by the company: ' || v_desc);$n$, '2'],
    array[$o$-- What the vendor is owed is the total less the income tax withheld; the withholding is a liability to the tax office.$o$,
          $n$-- The vendor is owed the full total; the income tax is the company's own cost and a liability to the tax office (decision 362).$n$, '1'],
    array[$o$-- The money that leaves the account is the total less the income tax withheld; the withholding is a liability.$o$,
          $n$-- The full total leaves the account; the income tax is the company's own cost and a liability to the tax office (decision 362).$n$, '1'],
    -- payable of a bill: the capacity check, the aging and the payment command now use the full total
    array[$o$b.total - b.withheld_total$o$, $n$b.total$n$, '3'],
    -- the explanation shown with a determination
    array[$o$'%s is withheld from the payee: the vendor is owed that much less, and it is credited to Tax Payables and accrues in the %s ledger for %s. The gross expense is unchanged.'$o$,
          $n$'%s is a tax cost of the company, paid to the tax office apart from the vendor: the vendor is paid in full, the amount is credited to Tax Payables, booked as a tax expense on top of the purchase and accrues in the %s ledger for %s.'$n$, '1'],
    array[$o$'Nothing is withheld: the vendor is owed the full amount.'$o$,
          $n$'No income tax is added to this purchase: the vendor is paid the full amount.'$n$, '1'],
    -- default categories for new Entities
    array[$o$'Pemasaran & Iklan', 'MARKETING_EXPENSE', 110, 'wht_none'$o$,
          $n$'Pemasaran & Iklan', 'MARKETING_EXPENSE', 110, 'wht_service_other_listed'$n$, '1'],
    array[$o$'Software & Langganan', 'SOFTWARE_SUBSCRIPTION_EXPENSE', 130, 'wht_none'$o$,
          $n$'Software & Langganan', 'SOFTWARE_SUBSCRIPTION_EXPENSE', 130, 'wht_service_other_listed'$n$, '1'],
    array[$o$'Hosting, Domain & Cloud', 'HOSTING_CLOUD_EXPENSE', 140, 'wht_none'$o$,
          $n$'Hosting, Domain & Cloud', 'HOSTING_CLOUD_EXPENSE', 140, 'wht_service_other_listed'$n$, '1'],
    array[$o$'Komunikasi & Internet', 'COMMUNICATION_EXPENSE', 190, 'wht_none'$o$,
          $n$'Komunikasi & Internet', 'COMMUNICATION_EXPENSE', 190, 'wht_service_other_listed'$n$, '1'],
    array[$o$'Ekspedisi & Pengiriman', 'TRAVEL_TRANSPORT_EXPENSE', 205, 'wht_none'$o$,
          $n$'Ekspedisi & Pengiriman', 'TRAVEL_TRANSPORT_EXPENSE', 205, 'wht_service_other_listed'$n$, '1']
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
      raise exception 'tax-borne patch % expected % function(s), found %', i, v_patch[i][3], v_n;
    end if;
  end loop;
end
$$;

-- ------------------------------------------------------------ Entities that already exist
-- Only a category still on the standard "not an object" answer moves; one the owner set is left alone.
update public.categories
set tax_category_key = 'wht_service_other_listed'
where kind = 'expense'
  and tax_category_key = 'wht_none'
  and normalized_name in ('pemasaran & iklan', 'software & langganan', 'hosting, domain & cloud',
                          'komunikasi & internet', 'ekspedisi & pengiriman');
