@AGENTS.md

# Hikarich Finance — working rules

- Read `docs/SPEC_INDEX.md` first. The Step 01–17 specs are FINAL & LOCKED; do not redesign or simplify them.
- Do not improvise beyond the specs. Anything that changes economic meaning, tax treatment, authorization or a user workflow goes to the OWNER as a question.
- Follow the build order P0–P15 (`docs/TASK_BOARD.md`); record decisions in `docs/DECISIONS.md` and update `docs/TRACEABILITY.md`.
- Never commit secrets. Preview/Development must never point at the production Supabase project.
- Before finishing a slice run `pnpm check`, `pnpm build` and `pnpm db:test`.
