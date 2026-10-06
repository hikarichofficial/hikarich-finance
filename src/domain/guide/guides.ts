import mulai from "@/content/guide/mulai.json";
import kasBank from "@/content/guide/kas-bank.json";
import penjualan from "@/content/guide/penjualan.json";
import pembelian from "@/content/guide/pembelian.json";
import pajakLainnya from "@/content/guide/pajak-lainnya.json";
import akuntansiLaporan from "@/content/guide/akuntansi-laporan.json";
import asetPinjaman from "@/content/guide/aset-pinjaman.json";
import payrollPerencanaan from "@/content/guide/payroll-perencanaan.json";
import administrasiDokumen from "@/content/guide/administrasi-dokumen.json";

/**
 * The step-by-step user guide (decision 299). One content source -- the JSON files under
 * `src/content/guide/` -- feeds both the "Panduan" pages in the website and the PDF generator
 * (`scripts/guide/build_guide_pdf.py`), so the two can never disagree. Button and field labels in the text
 * are written between `**double asterisks**`; a link to another guide is `[teks](slug)`.
 */

export interface GuideImage {
  readonly file: string;
  readonly caption: string;
}

export interface GuideStep {
  readonly title: string;
  readonly text: string;
  readonly image?: GuideImage;
  readonly tip?: string;
  readonly warning?: string;
}

export interface GuideTable {
  readonly title: string;
  readonly columns: readonly string[];
  readonly rows: readonly (readonly string[])[];
}

export interface GuideError {
  readonly message: string;
  readonly meaning: string;
}

export interface Guide {
  readonly slug: string;
  readonly title: string;
  readonly summary: string;
  readonly path: string;
  readonly who: string;
  readonly quick?: string;
  readonly steps: readonly GuideStep[];
  readonly tables?: readonly GuideTable[];
  readonly result?: readonly string[];
  readonly rules?: readonly string[];
  readonly mistakes?: readonly string[];
  readonly errors?: readonly GuideError[];
  readonly related?: readonly string[];
}

export interface GuideGroup {
  readonly key: string;
  readonly title: string;
  readonly description: string;
  readonly guides: readonly Guide[];
}

export const GUIDE_GROUPS: readonly GuideGroup[] = [
  mulai,
  kasBank,
  penjualan,
  pembelian,
  pajakLainnya,
  akuntansiLaporan,
  asetPinjaman,
  payrollPerencanaan,
  administrasiDokumen,
] as readonly GuideGroup[];

export const ALL_GUIDES: readonly Guide[] = GUIDE_GROUPS.flatMap((group) => group.guides);

export function findGuide(slug: string): Guide | undefined {
  return ALL_GUIDES.find((guide) => guide.slug === slug);
}

export function groupOfGuide(slug: string): GuideGroup | undefined {
  return GUIDE_GROUPS.find((group) => group.guides.some((guide) => guide.slug === slug));
}

/** Previous/next guide in reading order, for the pager at the bottom of a guide page. */
export function neighbours(slug: string): { prev?: Guide; next?: Guide } {
  const index = ALL_GUIDES.findIndex((guide) => guide.slug === slug);
  if (index < 0) return {};
  return { prev: ALL_GUIDES[index - 1], next: ALL_GUIDES[index + 1] };
}

/** Screenshot file names are plain lowercase names -- they are also the only thing the image route serves. */
export const GUIDE_IMAGE_NAME = /^[a-z0-9][a-z0-9-]*\.jpg$/;

/**
 * The image URL carries the name WITHOUT ".jpg": the app proxy skips paths ending in an image extension
 * (so it would not check the session), while this route must go through the same sign-in check as every
 * other page.
 */
export function guideImageUrl(file: string): string {
  return `/guide/image/${file.replace(/\.jpg$/, "")}`;
}

export type InlineToken =
  | { readonly kind: "text"; readonly text: string }
  | { readonly kind: "bold"; readonly text: string }
  | { readonly kind: "link"; readonly text: string; readonly slug: string };

/**
 * Splits one paragraph of guide text into plain, bold (`**x**`) and link (`[text](slug)`) pieces. Pure so
 * the website and the tests share it; the PDF generator has the same grammar.
 */
export function parseInline(input: string): InlineToken[] {
  const tokens: InlineToken[] = [];
  const pattern = /\*\*([^*]+)\*\*|\[([^\]]+)\]\(([a-z0-9-]+)\)/g;
  let last = 0;
  for (const match of input.matchAll(pattern)) {
    const at = match.index ?? 0;
    if (at > last) tokens.push({ kind: "text", text: input.slice(last, at) });
    if (match[1] !== undefined) tokens.push({ kind: "bold", text: match[1] });
    else tokens.push({ kind: "link", text: match[2] ?? "", slug: match[3] ?? "" });
    last = at + match[0].length;
  }
  if (last < input.length) tokens.push({ kind: "text", text: input.slice(last) });
  return tokens;
}

/** Paragraphs of a step: the text is split on blank lines. */
export function paragraphs(text: string): string[] {
  return text
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
}

/** Every `[text](slug)` in the guide, for the integrity test. */
export function linkedSlugs(guide: Guide): string[] {
  const texts: string[] = [
    guide.summary,
    guide.quick ?? "",
    ...(guide.result ?? []),
    ...(guide.rules ?? []),
    ...(guide.mistakes ?? []),
    ...guide.steps.flatMap((s) => [s.text, s.tip ?? "", s.warning ?? ""]),
  ];
  const slugs: string[] = [];
  for (const text of texts) {
    for (const token of parseInline(text)) if (token.kind === "link") slugs.push(token.slug);
  }
  return slugs;
}
