import { AppShell } from "@/features/shell/AppShell";
import { requireAccess } from "@/services/identity/access";

/**
 * Shared authenticated-app chrome (Step 09 §2). This route group applies `AppShell` to every screen
 * except `/login`, `/auth/*` and `/i/[token]` (outside the `(app)` segment, so unaffected -- Step 06 #4:
 * the invitation-claim and pre-auth screens must never depend on an existing session).
 *
 * `requireAccess()` here only gates entry (redirects to /login, /auth/mfa or the disabled/no-access
 * paths, exactly as P2's Home page did); it cannot read the `?entity=` query string (Next.js layouts
 * never receive `searchParams`), so the *active* Entity for chrome and for each page's own business
 * logic is resolved separately -- see AppShell's doc comment.
 */
export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { access } = await requireAccess();
  return <AppShell access={access}>{children}</AppShell>;
}
