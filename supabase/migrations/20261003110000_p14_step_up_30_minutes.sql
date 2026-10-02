-- P14 decision 270 (OWNER: "verifikasinya diubah menjadi 30 menit. karena 10 menit terlalu cepat"):
-- the recent re-authentication window of Step 06 §8 goes from 10 to 30 minutes.
--
-- Every sensitive command calls `app_authz.recent_step_up()` with no argument, so changing the default is
-- the whole change; which commands need a step-up, and who may run them, is untouched. The application
-- mirrors the same number in `STEP_UP_WINDOW_MINUTES`.
create or replace function app_authz.recent_step_up(p_max_age interval default interval '30 minutes') returns boolean
language sql stable as $$
  select coalesce(app_authz.last_authenticated_at() >= now() - p_max_age, false)
$$;
