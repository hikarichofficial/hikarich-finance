-- P15 decision 303: the Custom Report datasets are named in Indonesian; keys and permissions are unchanged.
begin;
set local client_min_messages = warning;

do $$
begin
  perform test_helpers.assert((select count(*) from public.report_datasets) = 3, '1.1 still three datasets');
  perform test_helpers.assert((select name from public.report_datasets where dataset_key = 'bills_by_vendor') = 'Pengeluaran per Vendor',
    '1.2 the vendor dataset is Indonesian');
  perform test_helpers.assert(not exists (select 1 from public.report_datasets where name ~* '(^| )(by|sales|expense|expenses|direct)( |$)'),
    '1.3 no dataset name keeps an English word');
  perform test_helpers.assert((select required_permission from public.report_datasets where dataset_key = 'invoices_by_customer') = 'invoices.view',
    '1.4 the permission each dataset needs is unchanged');
end
$$;

rollback;
