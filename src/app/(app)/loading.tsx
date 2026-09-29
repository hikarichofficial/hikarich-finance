/**
 * Segment-level loading UI (Next.js App Router convention; Step 09 §25-§27/Step 10 §21-§25's own "loading
 * visuals" item, decision 155's Part 5 list) -- a genuine, objectively-verifiable structural gap: a repo-wide
 * check found zero `loading.tsx`/`error.tsx` files anywhere in `src/app` except the public invoice token
 * page's own `not-found.tsx` (P5), despite every route under this `(app)` segment fetching its own data via
 * RPC before it can render. Next.js wraps `page.tsx` and everything below it in this segment in a `<Suspense>`
 * boundary automatically once this file exists; `(app)/layout.tsx` (and the `AppShell` it renders -- sidebar,
 * top bar, Entity switcher) sits OUTSIDE that boundary and keeps rendering immediately, so only the content
 * area (`.app-content`, `AppShell.tsx`) shows this fallback while a page's own data is still in flight.
 *
 * Reuses `.list-empty` (`globals.css`) verbatim -- the same muted, centred panel already shown for "no rows"
 * across every List/Detail screen in the app -- rather than inventing a new loading visual (a spinner/skeleton
 * component has no existing precedent anywhere in this codebase to extend).
 */
export default function AppLoading() {
  return (
    <div className="list-empty" role="status" aria-live="polite">
      <p>Memuat…</p>
    </div>
  );
}
