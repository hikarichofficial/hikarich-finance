"use client";

/**
 * Segment-level error boundary (Next.js App Router convention; Step 09 §25-§27/Step 10 §21-§25's own "error
 * visuals" item, decision 155's Part 5 list) -- the same repo-wide gap `loading.tsx`'s own doc comment
 * records: nothing under `(app)` caught a render/data error before this, so an RPC exception, a permission
 * failure, or a network fault during a page's own data fetch fell straight through to Next.js's bare default
 * error screen, with no app chrome and no recovery action. This file gives that segment an Error Boundary
 * instead; `(app)/layout.tsx` and `AppShell` stay outside it exactly as with `loading.tsx`, so the sidebar/
 * top bar keep rendering and only the content area shows this fallback.
 *
 * `error.message` is deliberately never rendered: an RPC failure's own text can carry internal detail (a
 * raised Postgres exception, a `FORBIDDEN: missing <permission>` string, a constraint name) -- the same
 * customer-facing-vs-internal boundary Step 11 §16 already establishes for invoice document data (decision
 * 201), applied here to error text instead of guessed at fresh. `reset()` is Next.js's own built-in mechanism
 * for re-rendering the segment, not a custom refetch. Reuses `.list-empty` (`globals.css`), the same panel
 * `loading.tsx` and every List/Detail screen's own empty state already use.
 */
export default function AppError({
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div className="list-empty" role="alert">
      <p>Terjadi masalah saat memuat halaman ini.</p>
      <button type="button" className="btn-secondary" onClick={reset}>
        Coba Lagi
      </button>
    </div>
  );
}
