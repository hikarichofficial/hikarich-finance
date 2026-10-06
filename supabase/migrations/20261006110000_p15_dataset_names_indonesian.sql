-- P15 decision 303 (OWNER, 6 October 2026): the three Custom Report datasets are named in Indonesian, like the rest of
-- the screens (finding #104: "Expense by Vendor" was shown as is). Display text only: the dataset keys, the permission
-- each one needs and everything the report computes are unchanged.
update public.report_datasets set
  name = 'Penjualan per Pelanggan',
  description = 'Invoice yang sudah terbit, dikelompokkan per pelanggan.',
  dimension_label = 'Pelanggan',
  measure_label = 'Total invoice'
where dataset_key = 'invoices_by_customer' and name = 'Sales by Customer';

update public.report_datasets set
  name = 'Pengeluaran per Vendor',
  description = 'Tagihan vendor yang sudah diakui, dikelompokkan per vendor.',
  dimension_label = 'Vendor',
  measure_label = 'Total tagihan'
where dataset_key = 'bills_by_vendor' and name = 'Expense by Vendor';

update public.report_datasets set
  name = 'Pengeluaran Langsung per Penerima',
  description = 'Pengeluaran langsung yang sudah dikonfirmasi, dikelompokkan per penerima.',
  dimension_label = 'Penerima',
  measure_label = 'Total pengeluaran'
where dataset_key = 'expenses_by_payee' and name = 'Direct Expenses by Payee';
