import { existsSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  ALL_GUIDES,
  GUIDE_GROUPS,
  GUIDE_IMAGE_NAME,
  findGuide,
  guideImageUrl,
  linkedSlugs,
  neighbours,
  paragraphs,
  parseInline,
} from "@/domain/guide/guides";

describe("guide content integrity (decision 299)", () => {
  it("has unique slugs and titles", () => {
    const slugs = ALL_GUIDES.map((g) => g.slug);
    expect(new Set(slugs).size).toBe(slugs.length);
    expect(new Set(ALL_GUIDES.map((g) => g.title)).size).toBe(ALL_GUIDES.length);
    for (const slug of slugs) expect(slug).toMatch(/^[a-z0-9-]+$/);
  });

  it("gives every guide the parts a reader needs", () => {
    for (const guide of ALL_GUIDES) {
      expect(guide.summary.length, guide.slug).toBeGreaterThan(20);
      expect(guide.path.length, guide.slug).toBeGreaterThan(5);
      expect(guide.who.length, guide.slug).toBeGreaterThan(10);
      expect(guide.steps.length, guide.slug).toBeGreaterThanOrEqual(3);
      for (const step of guide.steps) {
        expect(step.title.length, guide.slug).toBeGreaterThan(3);
        expect(step.text.length, `${guide.slug}: ${step.title}`).toBeGreaterThan(10);
      }
    }
  });

  it("only links and relates to guides that exist", () => {
    for (const guide of ALL_GUIDES) {
      for (const slug of [...linkedSlugs(guide), ...(guide.related ?? [])]) {
        expect(findGuide(slug), `${guide.slug} -> ${slug}`).toBeDefined();
        expect(slug).not.toBe(guide.slug);
      }
    }
  });

  it("references screenshots by safe names, and every referenced file exists", () => {
    const dir = path.join(process.cwd(), "src", "content", "guide", "images");
    for (const guide of ALL_GUIDES) {
      for (const step of guide.steps) {
        if (!step.image) continue;
        expect(step.image.file, guide.slug).toMatch(GUIDE_IMAGE_NAME);
        expect(step.image.caption.length, guide.slug).toBeGreaterThan(3);
        expect(
          existsSync(path.join(dir, step.image.file)),
          `${guide.slug}: ${step.image.file}`,
        ).toBe(true);
      }
    }
  });

  it("states plainly that an issued unpaid invoice becomes a receivable on its own", () => {
    const invoice = findGuide("buat-terbitkan-invoice");
    const concept = findGuide("memahami-piutang-pendapatan");
    expect(invoice?.quick).toMatch(/piutang usaha/i);
    expect(concept?.quick).toMatch(/otomatis menjadi piutang usaha/i);
  });

  it("keeps every group non-empty and in the reading order", () => {
    expect(GUIDE_GROUPS.map((g) => g.key)).toEqual([
      "mulai",
      "kas-bank",
      "penjualan",
      "pembelian",
      "pajak-lainnya",
      "akuntansi-laporan",
      "aset-pinjaman",
      "payroll-perencanaan",
      "administrasi-dokumen",
    ]);
    for (const group of GUIDE_GROUPS) expect(group.guides.length).toBeGreaterThan(0);
  });
});

describe("guide helpers", () => {
  it("splits bold and links out of a paragraph", () => {
    expect(
      parseInline("Tekan **Simpan** lalu baca [Cara Masuk](masuk-dan-ganti-entitas)."),
    ).toEqual([
      { kind: "text", text: "Tekan " },
      { kind: "bold", text: "Simpan" },
      { kind: "text", text: " lalu baca " },
      { kind: "link", text: "Cara Masuk", slug: "masuk-dan-ganti-entitas" },
      { kind: "text", text: "." },
    ]);
  });

  it("leaves plain text alone", () => {
    expect(parseInline("tanpa tanda")).toEqual([{ kind: "text", text: "tanpa tanda" }]);
  });

  it("splits a step into paragraphs on blank lines", () => {
    expect(paragraphs("satu\n\ndua\n\n\ntiga")).toEqual(["satu", "dua", "tiga"]);
  });

  it("serves screenshots under a URL without the image extension", () => {
    expect(guideImageUrl("rekening-daftar.jpg")).toBe("/guide/image/rekening-daftar");
  });

  it("finds neighbours in reading order", () => {
    const first = ALL_GUIDES[0]!;
    expect(neighbours(first.slug).prev).toBeUndefined();
    expect(neighbours(first.slug).next?.slug).toBe(ALL_GUIDES[1]!.slug);
    expect(neighbours("tidak-ada")).toEqual({});
  });
});
