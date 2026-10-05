import { flowDiagramUrl, flowOutline, type Flow } from "@/domain/guide/flows";

/**
 * One flow diagram: the picture (an SVG served by the auth-checked diagram route) plus the same diagram as a
 * plain-text outline, for screen readers and for anyone who prefers reading a list.
 */
export function FlowDiagram({ flow, headingLevel = 3 }: { flow: Flow; headingLevel?: 2 | 3 }) {
  const Heading = headingLevel === 2 ? "h2" : "h3";
  const outline = flowOutline(flow.items);
  return (
    <figure className="guide-flow" id={`alur-${flow.id}`}>
      <Heading>{flow.title}</Heading>
      <p className="guide-flow-summary">{flow.summary}</p>
      {/* eslint-disable-next-line @next/next/no-img-element -- an SVG from our own auth-checked route */}
      <img
        className="guide-flow-image"
        src={flowDiagramUrl(flow.id)}
        alt={`Diagram alur: ${flow.title}. Versi teksnya ada di bawah gambar.`}
        loading="lazy"
      />
      <details className="guide-flow-text">
        <summary>Lihat diagram ini sebagai daftar teks</summary>
        <ul>
          {outline.map((line, index) => (
            <li
              key={index}
              style={{ marginLeft: `${line.depth * 16}px` }}
              className={line.question ? "guide-flow-question" : undefined}
            >
              {line.text}
            </li>
          ))}
        </ul>
      </details>
    </figure>
  );
}
