import Link from "next/link";
import { GUIDE_GROUPS } from "@/domain/guide/guides";
import { GuideSearch } from "@/features/guide/GuideSearch";

export const metadata = { title: "Panduan · Hikarich Finance" };

/**
 * Panduan (decision 299): the list of every step-by-step guide, grouped by menu. The text comes from the
 * same JSON files the PDF is built from.
 */
export default function GuideIndexPage() {
  const items = GUIDE_GROUPS.flatMap((group) =>
    group.guides.map((guide) => ({
      slug: guide.slug,
      title: guide.title,
      summary: guide.summary,
      group: group.title,
    })),
  );
  return (
    <div className="list-screen guide-screen">
      <header className="list-screen-header">
        <div>
          <h1>Panduan</h1>
          <p className="list-screen-summary">
            Cara memakai Hikarich Finance, langkah demi langkah. Setiap panduan menjelaskan menu
            yang dibuka, isian yang harus diisi, apa yang terjadi di pembukuan, dan kesalahan yang
            sering terjadi.
          </p>
        </div>
      </header>
      <GuideSearch items={items} />
      <p className="guide-hint">
        Belum tahu harus mulai dari mana?{" "}
        <Link href="/guide/urutan-langkah-awal">Baca urutan langkah pertama kali memakai</Link>.
        Ingin tahu soal invoice yang belum dibayar?{" "}
        <Link href="/guide/memahami-piutang-pendapatan">
          Baca penjelasan piutang dan pendapatan
        </Link>
        .
      </p>
      {GUIDE_GROUPS.map((group) => (
        <section
          className="guide-group"
          key={group.key}
          aria-labelledby={`guide-group-${group.key}`}
        >
          <h2 id={`guide-group-${group.key}`}>{group.title}</h2>
          <p className="guide-group-description">{group.description}</p>
          <ul className="guide-card-list">
            {group.guides.map((guide) => (
              <li key={guide.slug}>
                <Link href={`/guide/${guide.slug}`} className="guide-card">
                  <span className="guide-card-title">{guide.title}</span>
                  <span className="guide-card-summary">{guide.summary}</span>
                  <span className="guide-card-path">{guide.path}</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </div>
  );
}
