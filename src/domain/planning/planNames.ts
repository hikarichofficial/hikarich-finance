import type { PlanPeriodType } from "@/domain/planning/planning";

/**
 * Suggested titles for a Budget or a Revenue Target (OWNER, 10 October 2026).
 *
 * The name of a plan is not an account -- it is a label the OWNER invents, so there is no register to pick
 * from. But an empty box still asks the person to think of a wording, and the wordings people use are few and
 * predictable. These are offered the way every other picker offers its list: click to see them all, type to
 * narrow, or ignore them and type something else entirely. Nothing here is stored or enforced.
 *
 * Names already used in this Entity come first, so the second year's budget is named like the first one's
 * rather than however it occurs to someone that day.
 */

const QUARTERS = ["Kuartal I", "Kuartal II", "Kuartal III", "Kuartal IV"] as const;

function nounFor(kind: "budget" | "revenue_target"): string {
  return kind === "budget" ? "Anggaran" : "Target Pendapatan";
}

/**
 * The list to offer, most useful first: what this Entity has called its plans before, then the shapes that
 * follow from the period type and the year. Duplicates are dropped, keeping the earlier (used-before) one.
 */
export function planNameSuggestions(
  kind: "budget" | "revenue_target",
  year: number,
  used: readonly string[] = [],
  periodType?: PlanPeriodType | "",
): string[] {
  const noun = nounFor(kind);
  const generated: string[] = [];

  if (periodType === "monthly") {
    generated.push(`${noun} Bulanan ${year}`);
  } else if (periodType === "annual") {
    generated.push(`${noun} Tahunan ${year}`);
  } else if (periodType === "custom") {
    generated.push(...QUARTERS.map((q) => `${noun} ${q} ${year}`));
  }

  generated.push(
    `${noun} Tahunan ${year}`,
    `${noun} Operasional ${year}`,
    ...QUARTERS.map((q) => `${noun} ${q} ${year}`),
    `${noun} ${year}`,
  );
  if (kind === "budget") generated.push(`Anggaran Pemasaran ${year}`, `Anggaran Produksi ${year}`);

  const seen = new Set<string>();
  const out: string[] = [];
  for (const name of [...used, ...generated]) {
    const trimmed = name.trim();
    const key = trimmed.toLowerCase();
    if (trimmed === "" || seen.has(key)) continue;
    seen.add(key);
    out.push(trimmed);
  }
  return out;
}
