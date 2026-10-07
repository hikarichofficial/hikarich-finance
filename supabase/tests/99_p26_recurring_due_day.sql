-- Decision 325: a recurring invoice/bill can be due on a fixed day of the month. Pure date rule, no data written.
begin;
set local client_min_messages = warning;

do $$
declare
  r public.recurring_rules;
begin
  r.due_offset_days := 30;
  r.due_day_of_month := null;
  perform test_helpers.assert(app_private.recurring_due_date(r, date '2026-11-05') = date '2026-12-05', '1.1 without a fixed day the old offset still applies');
  r.due_day_of_month := 20;
  perform test_helpers.assert(app_private.recurring_due_date(r, date '2026-11-05') = date '2026-11-20', '1.2 due on the 20th of the same month');
  perform test_helpers.assert(app_private.recurring_due_date(r, date '2026-11-25') = date '2026-12-20', '1.3 a day already passed falls in the next month');
  perform test_helpers.assert(app_private.recurring_due_date(r, date '2026-11-20') = date '2026-11-20', '1.4 the same day is allowed');
  r.due_day_of_month := 31;
  perform test_helpers.assert(app_private.recurring_due_date(r, date '2027-02-03') = date '2027-02-28', '1.5 day 31 uses the last day of a short month');
  perform test_helpers.assert(app_private.recurring_due_date(r, date '2026-12-31') = date '2026-12-31', '1.6 day 31 in a long month');
  r.due_day_of_month := 19;
  perform test_helpers.assert(app_private.recurring_due_date(r, date '2026-12-28') = date '2027-01-19', '1.7 across the year end');
end
$$;

rollback;
