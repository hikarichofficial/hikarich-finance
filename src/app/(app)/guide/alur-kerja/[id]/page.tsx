import Link from "next/link";
import { notFound } from "next/navigation";
import { FLOWS, findFlow, flowNeighbours, flowNumber, flowPageUrl } from "@/domain/guide/flows";
import { findGuide } from "@/domain/guide/guides";
import { FlowDiagram } from "@/features/guide/FlowDiagram";

export function generateStaticParams() {
  return FLOWS.map((flow) => ({ id: flow.id }));
}

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const flow = findFlow(id);
  return { title: flow ? `${flow.title} · Alur Kerja` : "Alur Kerja" };
}

/**
 * One flow diagram on its own page (decision 328), so each situation is read alone and never mixed with
 * another. The pages follow the owner's journey: the previous and next buttons walk through it in order.
 */
export default async function FlowPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const flow = findFlow(id);
  if (!flow) notFound();
  const { prev, next } = flowNeighbours(id);
  const guides = flow.guides.map((slug) => findGuide(slug)).filter((guide) => guide !== undefined);

  return (
    <article className="record-detail guide-screen guide-page">
      <nav className="guide-breadcrumb" aria-label="Jejak halaman">
        <Link href="/guide/alur-kerja">← Semua Diagram</Link>
        <span>{flow.stage}</span>
      </nav>
      <header>
        <p className="guide-flow-position">
          Diagram {flowNumber(flow.id)} dari {FLOWS.length}
        </p>
        <h1>{flow.title}</h1>
        <p className="list-screen-summary">{flow.summary}</p>
      </header>

      <FlowDiagram flow={flow} standalone />

      {guides.length > 0 ? (
        <section aria-labelledby="flow-guides">
          <h2 id="flow-guides">Panduan langkah demi langkah</h2>
          <ul className="guide-list">
            {guides.map((guide) => (
              <li key={guide.slug}>
                <Link href={`/guide/${guide.slug}`}>{guide.title}</Link>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <nav className="guide-flow-nav" aria-label="Diagram sebelum dan sesudah">
        {prev ? (
          <Link className="guide-flow-nav-link" href={flowPageUrl(prev.id)}>
            <span>‹ Sebelumnya</span>
            <strong>{prev.title}</strong>
          </Link>
        ) : (
          <span />
        )}
        {next ? (
          <Link className="guide-flow-nav-link guide-flow-nav-next" href={flowPageUrl(next.id)}>
            <span>Berikutnya ›</span>
            <strong>{next.title}</strong>
          </Link>
        ) : (
          <span />
        )}
      </nav>
    </article>
  );
}
