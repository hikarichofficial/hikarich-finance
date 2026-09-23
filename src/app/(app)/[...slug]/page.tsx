import { requireAccess } from "@/services/identity/access";

/**
 * Catch-all placeholder for every sitemap destination (Step 09 §3) that has no screen yet. The Sidebar
 * and Command Menu already link to all ~50 of them so the information architecture is complete and
 * navigable from day one (Step 09 §28: shell first, screens fill in progressively); Next.js prefers a
 * more specific route the moment a real page is added at that path, so nothing here needs to change
 * when that happens -- this file just shrinks over time as P13's later parts and later P phases add
 * real screens.
 */
export default async function ComingSoonPage({
  params,
  searchParams,
}: {
  params: Promise<{ slug: string[] }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  await requireAccess({ entityCode: entity });
  const { slug } = await params;
  const path = `/${slug.join("/")}`;

  return (
    <section>
      <p className="status-badge status-badge-neutral">Segera hadir</p>
      <h1>{path}</h1>
      <p>
        Halaman ini belum dibangun. Navigasi sudah tersedia; tampilannya menyusul di fase
        berikutnya.
      </p>
    </section>
  );
}
