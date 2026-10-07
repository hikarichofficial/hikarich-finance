import Link from "next/link";
import {
  FLOW_INTRO,
  FLOW_PAGE_TITLE,
  QUICK_LOOKUP,
  flowNumber,
  flowPageUrl,
  flowStages,
} from "@/domain/guide/flows";
import { findGuide } from "@/domain/guide/guides";

export const metadata = { title: `${FLOW_PAGE_TITLE} · Panduan` };

/**
 * Alur Kerja (decisions 300, 328): the index of the guide's flow diagrams. Every diagram has its own page;
 * here they are listed in the order of the owner's journey, from the first time using the app to every
 * menu, grouped by stage, plus a quick lookup table. Same content as the PDF's flow chapter.
 */
export default function FlowOverviewPage() {
  const stages = flowStages();
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

      {stages.map((stage) => (
        <section key={stage.title} className="guide-flow-stage" aria-label={stage.title}>
          <h2>{stage.title}</h2>
          <ol className="guide-flow-cards">
            {stage.flows.map((flow) => (
              <li key={flow.id}>
                <Link className="guide-flow-card" href={flowPageUrl(flow.id)}>
                  <span className="guide-flow-card-number">{flowNumber(flow.id)}</span>
                  <span className="guide-flow-card-body">
                    <strong>{flow.title}</strong>
                    <span>{flow.summary}</span>
                  </span>
                </Link>
              </li>
            ))}
          </ol>
        </section>
      ))}

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
    </article>
  );
}
