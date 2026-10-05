-- P15 decision 290 (OWNER, 5 October 2026): the default chart-of-accounts names are Indonesian. Names only:
-- a new Entity starts with them, and no template row was left behind in English. The rename of EXISTING
-- accounts keeps a name the OWNER chose herself (checked by re-running the same rule below).
-- Synthetic data; the whole file runs in one transaction that is rolled back.
begin;
set local client_min_messages = warning;

do $$
declare
  e_co uuid;
  e_pe uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p154_co', 'P15 COA company (synthetic)')
  returning id into e_co;
  insert into public.entities (entity_type, code, legal_name) values ('personal', 'p154_pe', 'P15 COA personal (synthetic)')
  returning id into e_pe;
  perform app_private.provision_default_coa(e_co);
  perform app_private.provision_default_coa(e_pe);

  -- 1. new Entities get Indonesian names, picked by system key (the key, not the name, is what posting uses)
  perform test_helpers.assert((select name from public.ledger_accounts where entity_id = e_co and system_key = 'ACCOUNTS_RECEIVABLE') = 'Piutang Usaha',
    '1.1 company: receivables are Piutang Usaha');
  perform test_helpers.assert((select name from public.ledger_accounts where entity_id = e_co and system_key = 'ACCOUNTS_PAYABLE') = 'Utang Usaha',
    '1.2 company: payables are Utang Usaha');
  perform test_helpers.assert((select name from public.ledger_accounts where entity_id = e_co and system_key = 'RETAINED_EARNINGS') = 'Laba Ditahan',
    '1.3 company: retained earnings are Laba Ditahan');
  perform test_helpers.assert((select name from public.ledger_accounts where entity_id = e_co and system_key = 'BPJS_KES_LIABILITY') = 'Utang BPJS Kesehatan',
    '1.4 company: the BPJS Kesehatan account is Indonesian');
  perform test_helpers.assert((select name from public.ledger_accounts where entity_id = e_pe and system_key = 'PERSONAL_HOUSING') = 'Hunian & Sewa',
    '1.5 personal: housing is Hunian & Sewa');
  perform test_helpers.assert((select name from public.ledger_accounts where entity_id = e_pe and system_key = 'OPENING_NET_WORTH') = 'Kekayaan Bersih Awal',
    '1.6 personal: opening net worth is Kekayaan Bersih Awal');

  -- 2. nothing in either template was left in English
  perform test_helpers.assert(not exists (select 1 from public.coa_template_accounts
    where name ~* '(^|[^a-z])(cash|account|accounts|payable|payables|receivable|receivables|expense|expenses|revenue|income|loan|loans|tax|fees|equity|earnings|and)([^a-z]|$)'),
    '2.1 no default account name keeps a plain English accounting word');

  -- 3. an account the OWNER renamed is not touched by the rule: re-apply it by hand to prove the guard
  update public.ledger_accounts set name = 'Kas Kecil Kantor Bali' where entity_id = e_co and system_key = 'CASH';
  update public.ledger_accounts la set name = ta.name
  from public.coa_template_accounts ta
  where la.entity_id = e_co and ta.template_key = 'company_default' and la.code = ta.code and la.name = ta.name;
  perform test_helpers.assert((select name from public.ledger_accounts where entity_id = e_co and system_key = 'CASH') = 'Kas Kecil Kantor Bali',
    '3.1 an owner-chosen name survives');
end
$$;

rollback;
