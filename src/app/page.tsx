import Image from "next/image";
import { entityLabel } from "@/domain/authz/access";
import { logoutAction } from "@/features/auth/actions";
import { requireAccess } from "@/services/identity/access";

// P2: the shell is now behind authentication. Still no business UI or financial data (that starts in P3+).
export default async function Home({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });
  const switchable = access.memberships.filter((m) => !m.mfa_required || m.mfa_satisfied);

  return (
    <main className="shell">
      <section className="card">
        <Image
          className="mark"
          src="/brand/hikarich-mark-512.png"
          alt="Logo Hikarich"
          width={96}
          height={96}
          priority
        />
        <h1>Hikarich Finance</h1>
        <p>
          {access.display_name ?? "Pengguna"} · {membership.role_key.toUpperCase()} di{" "}
          {membership.entity_name}
        </p>
        {switchable.length > 1 ? (
          <nav className="entities" aria-label="Pilih Entity">
            {switchable.map((m) => (
              <a
                key={m.entity_id}
                href={`/?entity=${encodeURIComponent(m.entity_code)}`}
                aria-current={m.entity_id === membership.entity_id ? "page" : undefined}
              >
                {entityLabel(m)}
              </a>
            ))}
          </nav>
        ) : null}
        <span className="badge">P2 · Auth &amp; Entity Isolation</span>
        <form action={logoutAction} className="logout">
          <button type="submit">Keluar</button>
        </form>
      </section>
    </main>
  );
}
