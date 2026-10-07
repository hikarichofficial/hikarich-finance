import alur from "@/content/guide/alur.json";

/**
 * Flow diagrams of the user guide (decision 300). One source -- `src/content/guide/alur.json` -- is drawn
 * into the SVG files under `src/content/guide/diagrams/` by `scripts/guide/build_flow_diagrams.py`, and the
 * very same layout feeds the PDF. This module only reads the source: for the lookup table, for the plain-text
 * version of each diagram (screen readers, search) and for the integrity test.
 */

export type FlowActor = "pelanggan" | "anda" | "sistem";

export interface FlowNode {
  readonly kind: "start" | "step" | "end";
  readonly actor?: FlowActor;
  readonly title: string;
  readonly menu?: string;
  readonly note?: string;
}

export interface FlowBranch {
  readonly label: string;
  readonly items: readonly FlowItem[];
}

export interface FlowChoice {
  readonly kind: "choice";
  readonly question: string;
  readonly branches: readonly FlowBranch[];
}

export type FlowItem = FlowNode | FlowChoice;

export interface Flow {
  readonly id: string;
  /** "Tahap 3 · Pembelian": the stage of the owner's journey this diagram belongs to (decision 328). */
  readonly stage: string;
  readonly title: string;
  readonly summary: string;
  readonly guides: readonly string[];
  readonly width?: number;
  readonly items: readonly FlowItem[];
}

export interface QuickLookup {
  readonly want: string;
  readonly menu: string;
  readonly guide: string;
}

export const FLOW_PAGE_TITLE: string = alur.title;
export const FLOW_INTRO: string = alur.intro;
export const QUICK_LOOKUP: readonly QuickLookup[] = alur.quick as readonly QuickLookup[];
export const FLOWS: readonly Flow[] = alur.flows as readonly Flow[];

/** Diagram ids are plain lowercase names -- also the only thing the diagram route serves. */
export const FLOW_ID = /^[a-z0-9][a-z0-9-]*$/;

/** The diagram is served by an auth-checked route (see `/guide/diagram/[id]`), never from `public/`. */
export function flowDiagramUrl(id: string): string {
  return `/guide/diagram/${id}`;
}

export function findFlow(id: string): Flow | undefined {
  return FLOWS.find((flow) => flow.id === id);
}

export interface FlowStage {
  readonly title: string;
  readonly flows: readonly Flow[];
}

/**
 * The diagrams grouped by stage, in the order of the journey (decision 328): first time using the app, then
 * sales, purchases, cash and bank, bookkeeping, tax, assets, payroll, planning, reports, documents and
 * administration. The order of `alur.json` IS the order shown; stages are the runs of equal `stage`.
 */
export function flowStages(): readonly FlowStage[] {
  const stages: { title: string; flows: Flow[] }[] = [];
  for (const flow of FLOWS) {
    const last = stages.at(-1);
    if (last && last.title === flow.stage) last.flows.push(flow);
    else stages.push({ title: flow.stage, flows: [flow] });
  }
  return stages;
}

/** 1-based position of a diagram in the journey. */
export function flowNumber(id: string): number {
  return FLOWS.findIndex((flow) => flow.id === id) + 1;
}

/** The diagram before and after this one in the journey. */
export function flowNeighbours(id: string): { prev?: Flow; next?: Flow } {
  const index = FLOWS.findIndex((flow) => flow.id === id);
  if (index < 0) return {};
  return { prev: FLOWS[index - 1], next: FLOWS[index + 1] };
}

/** The address of one diagram's own page. */
export function flowPageUrl(id: string): string {
  return `/guide/alur-kerja/${id}`;
}

/** Diagrams that explain a given guide, shown above its steps. */
export function flowsForGuide(slug: string): readonly Flow[] {
  return FLOWS.filter((flow) => flow.guides.includes(slug));
}

const ACTOR_LABEL: Record<FlowActor, string> = {
  pelanggan: "Pelanggan",
  anda: "Anda",
  sistem: "Sistem",
};

/** One line of text for a node: who, what, and which menu. */
export function describeNode(node: FlowNode): string {
  const who = node.actor ? `${ACTOR_LABEL[node.actor]}: ` : "";
  const parts = [`${who}${node.title}`];
  if (node.menu) parts.push(`Menu: ${node.menu}`);
  if (node.note) parts.push(node.note);
  return parts.join(". ");
}

/** The diagram as an outline of text lines (indent = depth), the accessible twin of the picture. */
export function flowOutline(
  items: readonly FlowItem[],
  depth = 0,
): { depth: number; text: string; question?: boolean }[] {
  const lines: { depth: number; text: string; question?: boolean }[] = [];
  for (const item of items) {
    if (item.kind === "choice") {
      lines.push({ depth, text: item.question, question: true });
      for (const branch of item.branches) {
        lines.push({ depth: depth + 1, text: `Jika: ${branch.label}` });
        if (branch.items.length === 0) {
          lines.push({ depth: depth + 2, text: "Tidak ada langkah tambahan, lanjut ke bawah" });
        } else {
          lines.push(...flowOutline(branch.items, depth + 2));
        }
      }
    } else {
      lines.push({ depth, text: describeNode(item) });
    }
  }
  return lines;
}

/** Every `Menu:`-bearing node and every guide referenced, for tests. */
export function allNodes(items: readonly FlowItem[]): FlowNode[] {
  return items.flatMap((item) =>
    item.kind === "choice" ? item.branches.flatMap((b) => allNodes(b.items)) : [item],
  );
}
