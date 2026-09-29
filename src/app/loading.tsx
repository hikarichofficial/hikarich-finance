/**
 * Root-level loading UI (Next.js App Router convention; decision 155's Part 5 list) -- the deferred half of
 * decision 211's own gap: `(app)/loading.tsx` already covers every authenticated screen, but `/login`,
 * `/auth/mfa`, `/auth/step-up` and the public `/i/[token]`/`/i/[token]/receipt` pages sit outside the `(app)`
 * route group (`(app)/layout.tsx`'s own doc comment: "every screen except `/login`, `/auth/*` and
 * `/i/[token]`") and had no loading UI of their own. Next.js only falls back to a root `loading.tsx` for a
 * segment that has no closer one of its own, so this never overrides `(app)/loading.tsx`.
 *
 * Renders `.skeleton-panel` (`globals.css`) inside `.shell`/`.card` -- the exact layout `/login`,
 * `/auth/mfa`, `/auth/step-up` and `/i/[token]`'s own `not-found.tsx` (P5) already render with, matching
 * `(app)/loading.tsx`'s own skeleton treatment (Step 09 §25, Step 10 §23/§24; decision 213) but sized to a
 * small centred card (three lines) rather than a list-screen shape, since these routes are a login form or a
 * single document, not a list workspace.
 */
export default function RootLoading() {
  return (
    <main className="shell">
      <section className="card">
        <div className="skeleton-panel" role="status" aria-label="Memuat">
          <div className="skeleton-block skeleton-line" />
          <div className="skeleton-block skeleton-line" />
          <div className="skeleton-block skeleton-line" />
        </div>
      </section>
    </main>
  );
}
