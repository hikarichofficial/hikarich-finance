-- P15 decision 303: the Custom Reports no longer count cancelled (void) invoices and bills.
begin;
set local client_min_messages = warning;

do $$
declare
  v_def text := pg_get_functiondef('public.run_custom_report(uuid, text, date, date)'::regprocedure);
begin
  perform test_helpers.assert(v_def not like '%''void''%', '1.1 the report no longer selects void documents');
  perform test_helpers.assert(v_def like '%i.status = ''issued''%' and v_def like '%b.status = ''approved''%',
    '1.2 invoices count when issued and bills when approved');
end
$$;

rollback;
