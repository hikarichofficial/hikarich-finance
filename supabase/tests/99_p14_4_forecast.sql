-- P14 decision 250 (OWNER answer to decision 139): forecasts are the average actual of the 3 complete
-- months before the Entity's current month, and a chosen budget's amount replaces it where the budget
-- plans that category-month. Also covers the budget report's forecast column, input validation and the
-- planning.view boundary. Synthetic data; one transaction, rolled back.
begin;
set local client_min_messages = warning;

create table test_helpers.p150 (k text primary key, v uuid);
grant all on test_helpers.p150 to public;

do $$
declare
  pt uuid;
  other uuid;
  v_owner uuid := 'e1500000-0000-0000-0000-000000000001';
  v_nobody uuid := 'e1500000-0000-0000-0000-000000000002';
  v_cat uuid;
begin
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p14_fc', 'P14 Forecast (synthetic)') returning id into pt;
  perform app_private.provision_default_coa(pt);
  insert into public.entities (entity_type, code, legal_name) values ('company', 'p14_fc_other', 'P14 Forecast other (synthetic)') returning id into other;
  perform app_private.provision_default_coa(other);
  perform test_helpers.mk_user(v_owner, 'p150-owner');
  perform test_helpers.mk_user(v_nobody, 'p150-nobody');
  perform test_helpers.mk_member(pt, v_owner, 'owner');
  perform test_helpers.mk_member(other, v_owner, 'owner');
  insert into test_helpers.p150 values ('pt', pt), ('other', other), ('owner', v_owner), ('nobody', v_nobody);
  insert into public.categories (entity_id, name, kind) values (pt, 'Forecast Revenue', 'revenue') returning id into v_cat;
  insert into test_helpers.p150 values ('rev', v_cat);
  insert into public.categories (entity_id, name, kind) values (pt, 'Forecast Expense', 'expense') returning id into v_cat;
  insert into test_helpers.p150 values ('exp', v_cat);
  insert into public.categories (entity_id, name, kind) values (pt, 'Idle Revenue', 'revenue') returning id into v_cat;
  insert into test_helpers.p150 values ('idle', v_cat);
end
$$;

do $$
declare
  pt uuid := (select v from test_helpers.p150 where k = 'pt');
  other uuid := (select v from test_helpers.p150 where k = 'other');
  v_owner uuid := (select v from test_helpers.p150 where k = 'owner');
  v_nobody uuid := (select v from test_helpers.p150 where k = 'nobody');
  v_rev uuid := (select v from test_helpers.p150 where k = 'rev');
  v_exp uuid := (select v from test_helpers.p150 where k = 'exp');
  v_idle uuid := (select v from test_helpers.p150 where k = 'idle');
  v_anchor date := date_trunc('month', test_helpers.today(pt))::date;
  v_cust uuid;
  v_vend uuid;
  v_inv uuid;
  v_bill uuid;
  v_budget uuid;
  v_other_budget uuid;
  r record;
  n integer;
begin
  perform test_helpers.login(v_owner);
  v_cust := public.create_contact(pt, 'key-p150-c1', 'customer', 'Klien Forecast');
  v_vend := public.create_contact(pt, 'key-p150-c2', 'vendor', 'Vendor Forecast');

  -- Revenue: 600rb one month ago, 300rb two months ago (in the window), 999.999 four months ago (outside)
  -- and 1jt this month (not part of the baseline) -> baseline (600rb + 300rb) / 3 = 300rb.
  v_inv := public.create_invoice_draft(pt, 'key-p150-i1', v_cust, (v_anchor - interval '1 month' + interval '14 days')::date,
    (v_anchor - interval '1 month' + interval '14 days')::date,
    jsonb_build_array(jsonb_build_object('description', 'Jasa', 'unit_price', '600000', 'category_id', v_rev)));
  perform public.issue_invoice(v_inv, 'key-p150-i1-issue');
  v_inv := public.create_invoice_draft(pt, 'key-p150-i2', v_cust, (v_anchor - interval '2 months' + interval '9 days')::date,
    (v_anchor - interval '2 months' + interval '9 days')::date,
    jsonb_build_array(jsonb_build_object('description', 'Jasa', 'unit_price', '300000', 'category_id', v_rev)));
  perform public.issue_invoice(v_inv, 'key-p150-i2-issue');
  v_inv := public.create_invoice_draft(pt, 'key-p150-i3', v_cust, (v_anchor - interval '4 months' + interval '3 days')::date,
    (v_anchor - interval '4 months' + interval '3 days')::date,
    jsonb_build_array(jsonb_build_object('description', 'Jasa', 'unit_price', '999999', 'category_id', v_rev)));
  perform public.issue_invoice(v_inv, 'key-p150-i3-issue');
  v_inv := public.create_invoice_draft(pt, 'key-p150-i4', v_cust, test_helpers.today(pt), test_helpers.today(pt),
    jsonb_build_array(jsonb_build_object('description', 'Jasa', 'unit_price', '1000000', 'category_id', v_rev)));
  perform public.issue_invoice(v_inv, 'key-p150-i4-issue');
  -- A draft invoice in the window is not actual.
  perform public.create_invoice_draft(pt, 'key-p150-i5', v_cust, (v_anchor - interval '1 month')::date,
    (v_anchor - interval '1 month')::date,
    jsonb_build_array(jsonb_build_object('description', 'Draf', 'unit_price', '777777', 'category_id', v_rev)));

  -- Expense: an approved bill of 150rb three months ago -> baseline 50rb.
  v_bill := public.create_bill_draft(pt, 'key-p150-b1', v_vend, (v_anchor - interval '3 months')::date,
    (v_anchor - interval '3 months')::date,
    jsonb_build_array(jsonb_build_object('description', 'Sewa', 'unit_price', '150000', 'category_id', v_exp)));
  perform public.submit_bill(v_bill, 'key-p150-b1-submit');
  perform public.approve_bill(v_bill, 'key-p150-b1-approve');

  -- A budget for the next three months that plans revenue for next month only.
  v_budget := public.create_budget(pt, 'key-p150-bg', 'Anggaran Forecast', 'monthly', v_anchor,
    (v_anchor + interval '3 months' - interval '1 day')::date);
  perform public.set_budget_lines(v_budget, jsonb_build_array(
    jsonb_build_object('category_id', v_rev, 'period_month', (v_anchor + interval '1 month')::date, 'budgeted_amount', '450000'),
    jsonb_build_object('category_id', v_exp, 'period_month', v_anchor, 'budgeted_amount', '80000')));
  v_other_budget := public.create_budget(other, 'key-p150-bg-o', 'Lain', 'monthly', v_anchor,
    (v_anchor + interval '1 month' - interval '1 day')::date);

  -- 1. baseline only (no budget)
  select count(*) into n from public.get_planning_forecast(pt, 3);
  perform test_helpers.assert(n = 6, '1.1 two active categories with activity x 3 months (the idle one is left out)');
  perform test_helpers.assert(not exists (select 1 from public.get_planning_forecast(pt, 3) f where f.category_id = v_idle),
    '1.2 a category with no activity and no budget line is not listed');
  for r in select * from public.get_planning_forecast(pt, 3) loop
    if r.category_id = v_rev then
      perform test_helpers.assert(r.baseline_amount = 300000 and r.forecast_amount = 300000 and r.budget_amount is null
        and r.source = 'average_3m', format('1.3 revenue %s: baseline 300rb', r.period_month));
    else
      perform test_helpers.assert(r.category_id = v_exp and r.baseline_amount = 50000 and r.forecast_amount = 50000
        and r.source = 'average_3m', format('1.4 expense %s: baseline 50rb', r.period_month));
    end if;
  end loop;
  perform test_helpers.assert((select min(period_month) from public.get_planning_forecast(pt, 3)) = v_anchor
    and (select max(period_month) from public.get_planning_forecast(pt, 3)) = (v_anchor + interval '2 months')::date,
    '1.5 months run from the Entity''s current month');

  -- 2. adjusted by the budget where it plans
  for r in select * from public.get_planning_forecast(pt, 3, v_budget) loop
    if r.category_id = v_rev and r.period_month = (v_anchor + interval '1 month')::date then
      perform test_helpers.assert(r.forecast_amount = 450000 and r.budget_amount = 450000 and r.baseline_amount = 300000
        and r.source = 'budget', '2.1 next month revenue follows the budget');
    elsif r.category_id = v_exp and r.period_month = v_anchor then
      perform test_helpers.assert(r.forecast_amount = 80000 and r.source = 'budget', '2.2 this month expense follows the budget');
    else
      perform test_helpers.assert(r.source = 'average_3m' and r.forecast_amount = r.baseline_amount,
        format('2.3 unplanned %s %s keeps the baseline', r.category_name, r.period_month));
    end if;
  end loop;

  -- 3. the budget report's forecast column
  for r in select * from public.get_budget_report(v_budget) loop
    perform test_helpers.assert(
      (r.category_id = v_rev and r.forecast_amount = 300000) or (r.category_id = v_exp and r.forecast_amount = 50000),
      format('3.1 budget report forecast for %s %s is the baseline', r.category_name, r.period_month));
  end loop;

  -- 4. validation
  perform test_helpers.expect_msg(format('select * from public.get_planning_forecast(%L, 0)', pt), 'INVALID', '4.1 months 1..24');
  perform test_helpers.expect_msg(format('select * from public.get_planning_forecast(%L, 25)', pt), 'INVALID', '4.2 months 1..24');
  perform test_helpers.expect_msg(format('select * from public.get_planning_forecast(%L, 3, %L)', pt, v_other_budget),
    'INVALID', '4.3 a budget of another Entity is refused');
  perform test_helpers.logout();

  -- 5. permission
  perform test_helpers.login(v_nobody);
  perform test_helpers.expect_msg(format('select * from public.get_planning_forecast(%L, 3)', pt), 'FORBIDDEN',
    '5.1 planning.view is required');
  perform test_helpers.logout();
end
$$;

rollback;
