-- P23 (decision 322): the owner sees which bank account number is saved. `account_number` stays a column the
-- browser roles can never read (Step 06 §6, finding #90); this adds `account_number_masked`, a stored generated
-- column that holds only stars and the last four digits (a number of four digits or fewer is all stars), and
-- lets the same roles read it under the same row rule (`money.view`). The audit trail keeps leaving it out like the
-- number itself. Backups and restores already skip generated columns, so nothing else changes.

alter table public.financial_accounts
  add column account_number_masked text generated always as (
    case
      when account_number is null then null
      when length(account_number) <= 4 then repeat('*', length(account_number))
      else repeat('*', length(account_number) - 4) || right(account_number, 4)
    end
  ) stored;

grant select (account_number_masked) on public.financial_accounts to authenticated;

drop trigger tg_audit on public.financial_accounts;
create trigger tg_audit after insert or update or delete on public.financial_accounts
  for each row execute function app_private.tg_audit('entity_id', 'account_number', 'account_number_masked');
