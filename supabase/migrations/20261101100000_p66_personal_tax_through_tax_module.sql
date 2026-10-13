-- p66 (decision 417): the tax a person pays in themselves goes through the same tax module as the company's.
--
-- Until now a Personal book had two ways to record a tax it paid: the tax module (Pajak > Pelaporan & Bukti, with NTPN,
-- proof and a detail page, the way the company does it) and, for the Pajak Pribadi estimate, two expense categories in
-- Pembelian > Beban. The second way booked the payment as a cost although the monthly final-tax accrual had already
-- recognised the cost, so the tax was counted twice, and it carried no NTPN or proof. The owner asked for one way: the
-- tax module.
--
--   * PPh Final UMKM of a Personal book: unchanged engine (accrual from the 1st of the next month, payment by the tax
--     module settles the liability). The Pajak Pribadi estimate now reads "sudah disetor" from those payments.
--   * PPh 25 (the monthly instalment of an individual): a new payment type 'pph25' of the same module, Personal books
--     only. It is paid in advance of the yearly tax, so there is no recognised liability to settle: it debits the
--     "Setoran Pajak Penghasilan" account (6060) and credits the bank, and it is not part of the tax control against the
--     tax payable account nor of the period reconciliation.
--   * The two Beban categories are no longer provisioned for a new Personal book. The summary still reads an old
--     expense booked in them, so nothing recorded before is lost.
--
-- The long functions are patched in place with the exact old text required (the block fails otherwise).

alter table public.tax_payments drop constraint tax_payments_tax_type_check;
alter table public.tax_payments add constraint tax_payments_tax_type_check
  check (tax_type in ('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm', 'pph25'));

do $$
declare
  v_patch text[][] := array[
    -- (function, old text, new text, how many times the old text must occur in that function)
    -- the payment command
    array['public.tax_record_payment(uuid,text,text,date,date,uuid,text,text,text,text,text)',
          $o$('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm')$o$,
          $n$('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm', 'pph25')$n$, '1'],
    array['public.tax_record_payment(uuid,text,text,date,date,uuid,text,text,text,text,text)',
          $o$  perform app_private.assert_business_date(p_date);$o$,
          $n$  if p_tax_type = 'pph25' and e.entity_type <> 'personal' then
    raise exception 'INVALID: the PPh 25 instalment is paid by a person, so it is recorded in a Personal book only'
      using errcode = 'invalid_parameter_value';
  end if;
  perform app_private.assert_business_date(p_date);$n$, '1'],
    array['public.tax_record_payment(uuid,text,text,date,date,uuid,text,text,text,text,text)',
          $o$  if v_payable > v_outstanding then$o$,
          $n$  -- A PPh 25 instalment is paid in advance of the yearly tax: there is no recognised liability to settle.
  if p_tax_type <> 'pph25' and v_payable > v_outstanding then$n$, '1'],
    array['public.tax_record_payment(uuid,text,text,date,date,uuid,text,text,text,text,text)',
          $o$when 'wht_pph26' then 'PPh 26' else 'PPh Final' end$o$,
          $n$when 'wht_pph26' then 'PPh 26' when 'pph25' then 'PPh 25' else 'PPh Final' end$n$, '1'],
    array['public.tax_record_payment(uuid,text,text,date,date,uuid,text,text,text,text,text)',
          $o$jsonb_build_object('account_key', 'TAX_PAYABLE', 'debit', v_payable,$o$,
          $n$jsonb_build_object('account_key', case when p_tax_type = 'pph25' then 'PERSONAL_INCOME_TAX_PAID' else 'TAX_PAYABLE' end, 'debit', v_payable,$n$, '1'],
    -- the capacity trigger: an instalment has no accrual to be capped by
    array['app_private.tg_tax_payments_capacity()',
          $o$  if new.status <> 'confirmed' then$o$,
          $n$  if new.status <> 'confirmed' or new.tax_type = 'pph25' then$n$, '1'],
    -- the position of a period
    array['public.tax_period_position(uuid,text,date,date)',
          $o$('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm')$o$,
          $n$('vat', 'wht_pph23', 'wht_pph4_2', 'wht_pph26', 'wht_pph21', 'final_umkm', 'pph25')$n$, '1'],
    -- differences: an instalment has no return of its own and is never "overpaid" against an accrual
    array['app_private.tax_period_differences(uuid,text,date,date)',
          $o$    if p_type <> 'final_umkm' then$o$,
          $n$    if p_type not in ('final_umkm', 'pph25') then$n$, '1'],
    array['app_private.tax_period_differences(uuid,text,date,date)',
          $o$  elsif v_outstanding < 0 then$o$,
          $n$  elsif v_outstanding < 0 and p_type <> 'pph25' then$n$, '1'],
    -- the tax control compares tax payable only: an instalment never touches it
    array['app_private.tax_control(uuid,date)',
          $o$where p.entity_id = p_entity and p.payment_date <= v_asof$o$,
          $n$where p.entity_id = p_entity and p.tax_type <> 'pph25' and p.payment_date <= v_asof$n$, '2'],
    -- the filtered summary of Ringkasan Pajak lists accrued tax; an instalment has none
    array['public.tax_scope_summary(uuid,date,date)',
          $o$where t.entity_id = p_entity and t.status = 'confirmed'$o$,
          $n$where t.entity_id = p_entity and t.status = 'confirmed' and t.tax_type <> 'pph25'$n$, '1'],
    -- the Pajak Pribadi summary reads what was paid from the tax module (and still from an old expense)
    array['public.personal_tax_summary(uuid,integer)',
          $o$      and c.personal_tax_role in ('tax_paid_final', 'tax_paid_installment') and b.bill_date between v_from and v_to
  ) q;$o$,
          $n$      and c.personal_tax_role in ('tax_paid_final', 'tax_paid_installment') and b.bill_date between v_from and v_to
    union all
    select extract(month from t.tax_period)::integer,
           case t.tax_type when 'final_umkm' then 'tax_paid_final' else 'tax_paid_installment' end,
           t.payable_applied
    from public.tax_payments t
    where t.entity_id = p_entity and t.status = 'confirmed' and t.tax_type in ('final_umkm', 'pph25')
      and t.tax_period between v_from and v_to
  ) q;$n$, '1'],
    -- a new Personal book no longer gets the two Beban categories for tax paid
    array['app_private.provision_personal_tax_categories(uuid)',
          $o$      ('Biaya Usaha & Jasa', 'expense', '6050', 'business_cost', 105),
      ('Setoran PPh Final UMKM', 'expense', '6060', 'tax_paid_final', 106),
      ('Setoran PPh 25 (Angsuran)', 'expense', '6060', 'tax_paid_installment', 107)$o$,
          $n$      ('Biaya Usaha & Jasa', 'expense', '6050', 'business_cost', 105)$n$, '1']
  ];
  i integer;
  v_def text;
  v_src text;
  v_count integer;
begin
  for i in 1 .. array_length(v_patch, 1) loop
    v_def := pg_catalog.pg_get_functiondef(v_patch[i][1]::regprocedure);
    v_src := (select p.prosrc from pg_catalog.pg_proc p where p.oid = v_patch[i][1]::regprocedure);
    v_count := (length(v_src) - length(replace(v_src, v_patch[i][2], ''))) / length(v_patch[i][2]);
    if v_count <> v_patch[i][4]::integer then
      raise exception 'p66 patch % (%): the old text occurs % time(s), expected %', i, v_patch[i][1], v_count, v_patch[i][4];
    end if;
    execute replace(v_def, v_patch[i][2], v_patch[i][3]);
  end loop;
end
$$;
