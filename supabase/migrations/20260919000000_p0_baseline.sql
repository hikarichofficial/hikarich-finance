-- P0 baseline migration (Step 15 §4 / Step 14 §6).
-- Purpose: establish the ordered, immutable migration history and prove the
-- clean-rebuild pipeline. It creates NO business tables; Step 02 schema
-- foundations begin in P1.

-- Supabase already provides the `extensions` schema; the test harness stubs it.
create extension if not exists pgcrypto with schema extensions;
