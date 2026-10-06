-- P15 decision 303 (finding #102): a monthly recurring rule keeps the day it started on, capped at each month's last day.
begin;
set local client_min_messages = warning;

do $$
begin
  -- 31 January, monthly: February has 28 days in 2027, March is back to the 31st (it used to stay on the 28th).
  perform test_helpers.assert(app_private.recurring_next_date(date '2027-01-31', 'monthly', 1, 31) = date '2027-02-28',
    '1.1 31 Jan -> 28 Feb');
  perform test_helpers.assert(app_private.recurring_next_date(date '2027-02-28', 'monthly', 1, 31) = date '2027-03-31',
    '1.2 28 Feb -> 31 Mar (the start day is kept)');
  perform test_helpers.assert(app_private.recurring_next_date(date '2027-03-31', 'monthly', 1, 31) = date '2027-04-30',
    '1.3 31 Mar -> 30 Apr');
  -- a leap year February
  perform test_helpers.assert(app_private.recurring_next_date(date '2028-01-30', 'monthly', 1, 30) = date '2028-02-29',
    '1.4 30 Jan 2028 -> 29 Feb 2028');
  -- every second month
  perform test_helpers.assert(app_private.recurring_next_date(date '2027-02-28', 'monthly', 2, 31) = date '2027-04-30',
    '1.5 an interval of two months keeps the anchor');
  -- weekly and custom days are not affected by the anchor
  perform test_helpers.assert(app_private.recurring_next_date(date '2027-01-31', 'weekly', 1, 31) = date '2027-02-07',
    '1.6 weekly is plain +7 days');
  perform test_helpers.assert(app_private.recurring_next_date(date '2027-01-31', 'custom_days', 10, 31) = date '2027-02-10',
    '1.7 custom days are plain +N days');
  -- no anchor: the old behaviour (counts from the date given)
  perform test_helpers.assert(app_private.recurring_next_date(date '2027-01-31', 'monthly', 1) = date '2027-02-28',
    '1.8 the three-argument form is unchanged');
end
$$;

rollback;
