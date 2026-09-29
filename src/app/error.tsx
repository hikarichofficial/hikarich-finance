"use client";

/**
 * Root-level error boundary (Next.js App Router convention; Step 09 §25-§27/Step 10 §21-§25's own "error
 * visuals" item, decision 155's Part 5 list) -- the deferred half of decision 211's own gap. `(app)/error.tsx`
 * already covers every authenticated screen; this covers `/login`, `/auth/mfa`, `/auth/step-up` and the
 * public `/i/[token]`/`/i/[token]/receipt` pages, which sit outside the `(app)` route group and had no error
 * boundary of their own -- most importantly the public invoice page, where an unhandled exception (a network
 * fault, an unexpected RPC error -- distinct from the deliberate `notFound()` call `/i/[token]/page.tsx`
 * already makes for an invalid/expired token, still routed to `not-found.tsx`) previously fell straight
 * through to Next.js's bare default error screen in front of a customer, not staff. Next.js only falls back
 * to a root `error.tsx` for a segment that has no closer one of its own, so this never overrides
 * `(app)/error.tsx`.
 *
 * Uses `.shell`/`.card` -- the same layout `/login`, `/auth/mfa`, `/auth/step-up` and `/i/[token]`'s own
 * `not-found.tsx` (P5) already render with, matching decision 211's `(app)/loading.tsx`/`error.tsx` in every
 * other respect: `error.message` is deliberately never rendered (the same customer-facing-vs-internal
 * boundary Step 11 §16 already establishes for invoice document data), and `reset()` is Next.js's own retry
 * mechanism, not a custom refetch.
 */
export default function RootError({
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <main className="shell">
      <section className="card" role="alert">
        <h1>Terjadi kesalahan</h1>
        <p>Terjadi masalah saat memuat halaman ini.</p>
        <button type="button" className="btn-secondary" onClick={reset}>
          Coba Lagi
        </button>
      </section>
    </main>
  );
}
