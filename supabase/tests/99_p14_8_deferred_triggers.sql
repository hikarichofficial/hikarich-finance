-- P14 decision 269: a constraint trigger that is INITIALLY DEFERRED runs at COMMIT, outside the SECURITY
-- DEFINER command that wrote the row, as the signed-in person -- who has no table privileges. Its function
-- must therefore be SECURITY DEFINER itself. The test files cannot observe a commit (each runs in one
-- transaction that is rolled back), so this checks the structure instead.
begin;
set local client_min_messages = warning;

do $$
declare
  v_bad text;
begin
  select string_agg(c.relname || '.' || t.tgname || ' -> ' || p.proname, ', ') into v_bad
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_proc p on p.oid = t.tgfoid
  where not t.tgisinternal and t.tginitdeferred and c.relnamespace = 'public'::regnamespace and not p.prosecdef;
  perform test_helpers.assert(v_bad is null,
    '1.0 every initially deferred constraint trigger runs as its owner (not: ' || coalesce(v_bad, '') || ')');

  perform test_helpers.assert(
    (select p.prosecdef and p.proconfig @> array['search_path=pg_catalog, public']
     from pg_proc p where p.oid = 'app_private.tg_payroll_payments_capacity()'::regprocedure),
    '1.1 the payroll payment capacity check is SECURITY DEFINER with a pinned search_path');
end
$$;

rollback;
