import Link from "next/link";
import { FLOWS, FLOW_INTRO, FLOW_PAGE_TITLE, QUICK_LOOKUP } from "@/domain/guide/flows";
import { findGuide } from "@/domain/guide/guides";
import { FlowDiagram } from "@/features/guide/FlowDiagram";

export const metadata = { title: `${FLOW_PAGE_TITLE} · Panduan` };

/**
 * Alur Kerja (decision 300): the guide's flow diagrams -- "when this happens, which menu do I open and what
 * comes next" -- plus a quick lookup table. Same content as the PDF's flow chapter.
 */
export default function FlowOverviewPage() {
  return (
    <article className="record-detail guide-screen guide-page">
      <nav className="guide-breadcrumb" aria-label="Jejak halaman">
        <Link href="/guide">← Semua Panduan</Link>
        <span>Alur Kerja</span>
      </nav>
      <header>
        <h1>{FLOW_PAGE_TITLE}</h1>
        <p className="list-screen-summary">{FLOW_INTRO}</p>
      </header>

      <nav className="guide-flow-toc" aria-label="Daftar diagram">
        <h2>Diagram yang tersedia</h2>
        <ul className="guide-list">
          {FLOWS.map((flow) => (
            <li key={flow.id}>
              <a href={`#alur-${flow.id}`}>{flow.title}</a>
            </li>
          ))}
        </ul>
      </nav>

      <section className="guide-table-section" aria-labelledby="alur-cepat">
        <h2 id="alur-cepat">Saya mau ... buka menu apa?</h2>
        <div className="guide-table-scroll">
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Saya mau</th>
                <th scope="col">Buka menu</th>
                <th scope="col">Panduan lengkap</th>
              </tr>
            </thead>
            <tbody>
              {QUICK_LOOKUP.map((row) => {
                const guide = findGuide(row.guide);
                return (
                  <tr key={row.want}>
                    <td>{row.want}</td>
                    <td>{row.menu}</td>
                    <td>
                      {guide ? <Link href={`/guide/${guide.slug}`}>{guide.title}</Link> : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      {FLOWS.map((flow) => (
        <FlowDiagram key={flow.id} flow={flow} headingLevel={2} />
      ))}
    </article>
  );
}
