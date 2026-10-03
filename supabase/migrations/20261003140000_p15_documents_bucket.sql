-- P15 (decision 275): the private Storage bucket for evidence files (Step 13 §16, decisions 141-142).
--
-- The bucket has no Storage policy on purpose: no browser and no signed-in session can read or write it
-- directly. Only the application server (service-role key, `src/services/documents/storage.ts`) puts a file
-- there, after `register_document` accepted it, and mints a short-lived signed URL, after
-- `get_document_download_grant` re-checked the caller's permission (Step 06 §5: a storage path is not
-- permission). Guarded because a plain PostgreSQL rebuild (CI) has no `storage` schema.
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit)
    values ('documents', 'documents', false, 26214400)
    on conflict (id) do nothing;
  end if;
end
$$;
