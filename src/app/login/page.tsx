import { redirect } from "next/navigation";
import { LoginForm } from "@/features/auth/AuthForms";
import { getAccessSnapshot } from "@/lib/auth/session";
import { safeNextPath } from "@/domain/authz/access";

export const metadata = { title: "Masuk · Hikarich Finance" };

const NOTICES: Record<string, string> = {
  disabled: "Akun ini dinonaktifkan. Hubungi OWNER.",
  no_access: "Akun ini belum memiliki akses ke Entity mana pun. Hubungi OWNER.",
};

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; error?: string }>;
}) {
  const { next, error } = await searchParams;
  const destination = safeNextPath(next, "/");

  // Already signed in with a usable account: go straight to the app.
  const access = await getAccessSnapshot();
  if (access?.active && access.memberships.length > 0 && !error) redirect(destination);

  return (
    <main className="shell">
      <section className="card">
        <h1>Masuk</h1>
        <p>Hikarich Finance — akses terbatas.</p>
        <LoginForm next={destination} notice={error ? NOTICES[error] : undefined} />
      </section>
    </main>
  );
}
