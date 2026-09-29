/**
 * Segment-level loading UI (Next.js App Router convention; decision 155's Part 5 list) -- a genuine,
 * objectively-verifiable structural gap: a repo-wide check found zero `loading.tsx`/`error.tsx` files
 * anywhere in `src/app` except the public invoice token page's own `not-found.tsx` (P5), despite every route
 * under this `(app)` segment fetching its own data via RPC before it can render. Next.js wraps `page.tsx` and
 * everything below it in this segment in a `<Suspense>` boundary automatically once this file exists;
 * `(app)/layout.tsx` (and the `AppShell` it renders -- sidebar, top bar, Entity switcher) sits OUTSIDE that
 * boundary and keeps rendering immediately, so only the content area (`.app-content`, `AppShell.tsx`) shows
 * this fallback while a page's own data is still in flight.
 *
 * Renders `.skeleton-panel` (`globals.css`) -- a pulsing list-screen-shaped stack (a header bar plus six row
 * bars), since List/Detail screens are the majority shape across `(app)`'s own routes. This replaces the
 * plain-text "Memuat…" panel decision 211 originally shipped here: that increment was built while this
 * session mistakenly believed the actual Step 09/Step 10 spec DOCX text was inaccessible to it and reasoned
 * indirectly instead of reading it directly, even though the file was reachable the whole time. Once read
 * (decision 213), Step 09 §25 ("Use skeleton loading for primary workspace content rather than disruptive
 * full-screen spinners") and Step 10 §23/§24 ("Skeletons match final geometry to minimize layout shift";
 * "neutral shimmer or subtle pulse compatible with reduced-motion") made plain that a static text panel did
 * not comply, so this file is corrected to match rather than left as shipped.
 */
export default function AppLoading() {
  return (
    <div className="skeleton-panel" role="status" aria-label="Memuat">
      <div className="skeleton-block skeleton-header" />
      <div className="skeleton-block skeleton-row" />
      <div className="skeleton-block skeleton-row" />
      <div className="skeleton-block skeleton-row" />
      <div className="skeleton-block skeleton-row" />
      <div className="skeleton-block skeleton-row" />
    </div>
  );
}
