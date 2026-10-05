import Image from "next/image";
import Link from "next/link";
import { notFound } from "next/navigation";
import {
  ALL_GUIDES,
  findGuide,
  groupOfGuide,
  guideImageUrl,
  neighbours,
  paragraphs,
} from "@/domain/guide/guides";
import { flowsForGuide } from "@/domain/guide/flows";
import { FlowDiagram } from "@/features/guide/FlowDiagram";
import { GuideText } from "@/features/guide/GuideText";

export function generateStaticParams() {
  return ALL_GUIDES.map((guide) => ({ slug: guide.slug }));
}

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const guide = findGuide(slug);
  return { title: guide ? `${guide.title} · Panduan` : "Panduan" };
}

/** One guide (decision 299): numbered steps, screenshots, accounting effect, rules, common mistakes. */
export default async function GuidePage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const guide = findGuide(slug);
  if (!guide) notFound();
  const group = groupOfGuide(slug);
  const { prev, next } = neighbours(slug);
  const flows = flowsForGuide(slug);
  const related = (guide.related ?? [])
    .map((relatedSlug) => findGuide(relatedSlug))
    .filter((item): item is NonNullable<typeof item> => item !== undefined);

  return (
    <article className="record-detail guide-screen guide-page">
      <nav className="guide-breadcrumb" aria-label="Jejak halaman">
        <Link href="/guide">← Semua Panduan</Link>
        {group ? <span>{group.title}</span> : null}
      </nav>
      <header>
        <h1>{guide.title}</h1>
        <p className="list-screen-summary">{guide.summary}</p>
      </header>

      <dl className="guide-meta">
        <div>
          <dt>Jalur menu</dt>
          <dd>{guide.path}</dd>
        </div>
        <div>
          <dt>Siapa yang bisa</dt>
          <dd>{guide.who}</dd>
        </div>
      </dl>

      {guide.quick ? (
        <p className="guide-quick">
          <strong>Intinya: </strong>
          <GuideText text={guide.quick} />
        </p>
      ) : null}

      {flows.length > 0 ? (
        <section aria-labelledby="guide-flows">
          <h2 id="guide-flows">Diagram alur</h2>
          {flows.map((flow) => (
            <FlowDiagram key={flow.id} flow={flow} />
          ))}
          <p className="guide-hint">
            Semua diagram ada di <Link href="/guide/alur-kerja">Alur Kerja (Diagram)</Link>.
          </p>
        </section>
      ) : null}

      <section aria-labelledby="guide-steps">
        <h2 id="guide-steps">Langkah-langkah</h2>
        <ol className="guide-steps">
          {guide.steps.map((step, index) => (
            <li key={index} className="guide-step">
              <h3>
                <span className="guide-step-number">{index + 1}</span>
                {step.title}
              </h3>
              {paragraphs(step.text).map((paragraph, i) => (
                <p key={i}>
                  <GuideText text={paragraph} />
                </p>
              ))}
              {step.image ? (
                <figure className="guide-figure">
                  <Image
                    src={guideImageUrl(step.image.file)}
                    alt={step.image.caption}
                    width={1280}
                    height={800}
                    unoptimized
                  />
                  <figcaption>{step.image.caption}</figcaption>
                </figure>
              ) : null}
              {step.tip ? (
                <p className="guide-callout guide-callout-tip">
                  <strong>Tips: </strong>
                  <GuideText text={step.tip} />
                </p>
              ) : null}
              {step.warning ? (
                <p className="guide-callout guide-callout-warning">
                  <strong>Perhatian: </strong>
                  <GuideText text={step.warning} />
                </p>
              ) : null}
            </li>
          ))}
        </ol>
      </section>

      {(guide.tables ?? []).map((table, index) => (
        <section key={index} className="guide-table-section">
          <h2>{table.title}</h2>
          <div className="guide-table-scroll">
            <table className="record-table">
              <thead>
                <tr>
                  {table.columns.map((column) => (
                    <th key={column} scope="col">
                      {column}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {table.rows.map((row, rowIndex) => (
                  <tr key={rowIndex}>
                    {row.map((cell, cellIndex) => (
                      <td key={cellIndex}>{cell}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      ))}

      {guide.result && guide.result.length > 0 ? (
        <section>
          <h2>Hasil setelah berhasil</h2>
          <ul className="guide-list">
            {guide.result.map((item, i) => (
              <li key={i}>
                <GuideText text={item} />
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {guide.rules && guide.rules.length > 0 ? (
        <section>
          <h2>Aturan penting</h2>
          <ul className="guide-list">
            {guide.rules.map((item, i) => (
              <li key={i}>
                <GuideText text={item} />
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {guide.mistakes && guide.mistakes.length > 0 ? (
        <section>
          <h2>Kesalahan yang sering terjadi</h2>
          <ul className="guide-list">
            {guide.mistakes.map((item, i) => (
              <li key={i}>
                <GuideText text={item} />
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {guide.errors && guide.errors.length > 0 ? (
        <section className="guide-table-section">
          <h2>Pesan kesalahan dan artinya</h2>
          <div className="guide-table-scroll">
            <table className="record-table">
              <thead>
                <tr>
                  <th scope="col">Pesan di layar</th>
                  <th scope="col">Artinya</th>
                </tr>
              </thead>
              <tbody>
                {guide.errors.map((error, i) => (
                  <tr key={i}>
                    <td>{error.message}</td>
                    <td>{error.meaning}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      ) : null}

      {related.length > 0 ? (
        <section>
          <h2>Panduan terkait</h2>
          <ul className="guide-list">
            {related.map((item) => (
              <li key={item.slug}>
                <Link href={`/guide/${item.slug}`}>{item.title}</Link>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <nav className="guide-pager" aria-label="Panduan sebelumnya dan berikutnya">
        {prev ? (
          <Link href={`/guide/${prev.slug}`} rel="prev">
            ← {prev.title}
          </Link>
        ) : (
          <span />
        )}
        {next ? (
          <Link href={`/guide/${next.slug}`} rel="next">
            {next.title} →
          </Link>
        ) : (
          <span />
        )}
      </nav>
    </article>
  );
}
