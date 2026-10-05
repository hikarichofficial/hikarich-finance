-- OWNER, 5 October 2026: "untuk jam default website gunakan saja jam lokal yaitu WITA Asia/Makassar" --
-- the OWNER's own location is WITA, so a brand-new Entity should start there instead of WIB. This only
-- changes the column default for Entities created from now on; it does not touch the timezone already
-- stored on an existing Entity (changing that is `update_entity_time_settings`, from Settings, which the
-- OWNER can do herself for each Entity -- decision 248 already offers WITA as a choice there).

alter table public.entities alter column timezone set default 'Asia/Makassar';
