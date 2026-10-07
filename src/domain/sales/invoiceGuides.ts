/** Which part of a block lines up: its start (left or top edge), its middle or its end (right or bottom edge). */
export type GuidePart = "start" | "middle" | "end";

/** Somewhere a moving block can line up with: the page edge, the page middle, an edge or the middle of another
 * block. `at` is a position on one axis (percent of the page width, or pixels). */
export interface GuideTarget {
  at: number;
  label: string;
}

/** A line the editor draws where the moving block lines up (like the smart guides of Canva). */
export interface GuideHit {
  at: number;
  labels: string[];
}

export interface Snap {
  /** How far to move the block so it lines up. */
  delta: number;
  hits: GuideHit[];
}

/** The nearest alignment on one axis: the block's start, middle and end (`parts`) against the targets. Within
 * `tolerance` the block snaps to the closest target (`delta`), and every target the block then lines up with is
 * reported so all of them can be drawn. `null` when nothing is close enough. */
export function snapAxis(
  parts: readonly { at: number; part: GuidePart }[],
  targets: readonly GuideTarget[],
  tolerance: number,
): Snap | null {
  let best: number | null = null;
  for (const part of parts) {
    for (const target of targets) {
      const distance = target.at - part.at;
      if (Math.abs(distance) > tolerance) continue;
      if (best === null || Math.abs(distance) < Math.abs(best)) best = distance;
    }
  }
  if (best === null) return null;
  const hits = new Map<number, string[]>();
  for (const part of parts) {
    for (const target of targets) {
      if (Math.abs(target.at - part.at - best) > 0.01) continue;
      const key = Math.round(target.at * 100) / 100;
      const labels = hits.get(key) ?? [];
      if (!labels.includes(target.label)) labels.push(target.label);
      hits.set(key, labels);
    }
  }
  return {
    delta: best,
    hits: [...hits.entries()].map(([at, labels]) => ({ at, labels })),
  };
}
