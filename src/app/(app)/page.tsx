import { requireAccess } from "@/services/identity/access";

// P13 Part 1: the page itself is still a placeholder -- the actual Dashboard (Step 09 §8, widgets
// sourced from modules that don't exist yet) is built once those modules ship. This route's job for
// now is to prove the shell (Sidebar/TopBar/EntitySwitcher/CommandMenu) renders real, permission-scoped
// data end to end.
export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });

  return (
    <section>
      <h1>Selamat datang, {access.display_name ?? "Pengguna"}</h1>
      <p>
        Anda masuk sebagai <strong>{membership.role_key.toUpperCase()}</strong> di{" "}
        <strong>{membership.entity_name}</strong>.
      </p>
      <p className="status-badge status-badge-progress">P13 · Shell &amp; Navigasi</p>
    </section>
  );
}
