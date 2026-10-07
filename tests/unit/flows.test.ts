import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  FLOWS,
  FLOW_ID,
  QUICK_LOOKUP,
  allNodes,
  describeNode,
  findFlow,
  flowNeighbours,
  flowNumber,
  flowOutline,
  flowPageUrl,
  flowStages,
  flowsForGuide,
} from "@/domain/guide/flows";
import { ALL_GUIDES, findGuide } from "@/domain/guide/guides";

const GUIDE_DIR = path.join(process.cwd(), "src", "content", "guide");

describe("flow diagrams (decision 300)", () => {
  it("has unique, safe ids and a title, summary and items for every flow", () => {
    expect(new Set(FLOWS.map((f) => f.id)).size).toBe(FLOWS.length);
    for (const flow of FLOWS) {
      expect(flow.id).toMatch(FLOW_ID);
      expect(flow.title.length, flow.id).toBeGreaterThan(10);
      expect(flow.summary.length, flow.id).toBeGreaterThan(20);
      expect(flow.items.length, flow.id).toBeGreaterThanOrEqual(3);
    }
  });

  it("starts with a start node and ends with an end node", () => {
    for (const flow of FLOWS) {
      expect(flow.items[0]?.kind, flow.id).toBe("start");
      expect(flow.items.at(-1)?.kind, flow.id).toBe("end");
    }
  });

  it("gives every choice at least two answers, each labelled", () => {
    for (const flow of FLOWS) {
      const walk = (items: typeof flow.items) => {
        for (const item of items) {
          if (item.kind !== "choice") continue;
          expect(item.question.length, flow.id).toBeGreaterThan(5);
          expect(item.branches.length, flow.id).toBeGreaterThanOrEqual(2);
          expect(item.branches.length, flow.id).toBeLessThanOrEqual(3);
          for (const branch of item.branches) {
            expect(branch.label.length, flow.id).toBeGreaterThan(1);
            walk(branch.items);
          }
        }
      };
      walk(flow.items);
    }
  });

  it("names a menu or a note on every step, and never an empty title", () => {
    for (const flow of FLOWS) {
      for (const node of allNodes(flow.items)) {
        expect(node.title.trim().length, flow.id).toBeGreaterThan(3);
        if (node.kind === "step" && node.actor === "anda") {
          expect(Boolean(node.menu) || Boolean(node.note) || node.title.length > 8, flow.id).toBe(
            true,
          );
        }
      }
    }
  });

  it("only points to guides that exist, and the diagram page slug is not a guide slug", () => {
    for (const flow of FLOWS) {
      expect(flow.guides.length, flow.id).toBeGreaterThan(0);
      for (const slug of flow.guides)
        expect(findGuide(slug), `${flow.id} -> ${slug}`).toBeDefined();
    }
    for (const row of QUICK_LOOKUP) expect(findGuide(row.guide), row.want).toBeDefined();
    expect(ALL_GUIDES.map((g) => g.slug)).not.toContain("alur-kerja");
    expect(ALL_GUIDES.map((g) => g.slug)).not.toContain("image");
    expect(ALL_GUIDES.map((g) => g.slug)).not.toContain("diagram");
  });

  it("answers the payment question: the money-in flow names the payment menus", () => {
    const flow = findFlow("uang-masuk");
    expect(flow).toBeDefined();
    const menus = allNodes(flow?.items ?? []).map((n) => n.menu ?? "");
    expect(menus.some((m) => m.includes("Catat Pembayaran"))).toBe(true);
    expect(menus.some((m) => m.includes("Klaim Pembayaran"))).toBe(true);
    expect(flowsForGuide("terima-pembayaran").map((f) => f.id)).toContain("uang-masuk");
  });

  it("has a drawn SVG for every flow that is built from the current alur.json", () => {
    const source = readFileSync(path.join(GUIDE_DIR, "alur.json"));
    const hash = createHash("sha256").update(source).digest("hex").slice(0, 16);
    for (const flow of FLOWS) {
      const file = path.join(GUIDE_DIR, "diagrams", `${flow.id}.svg`);
      expect(existsSync(file), `${flow.id}.svg -- run scripts/guide/build_flow_diagrams.py`).toBe(
        true,
      );
      const svg = readFileSync(file, "utf8");
      expect(svg.startsWith("<svg"), flow.id).toBe(true);
      expect(
        svg,
        `${flow.id}.svg is out of date -- run scripts/guide/build_flow_diagrams.py`,
      ).toContain(`sha256:${hash}`);
      expect(svg).not.toMatch(/<script|onload=|javascript:/i);
    }
  });

  it("describes a flow as a plain-text outline", () => {
    const flow = findFlow("uang-masuk");
    const outline = flowOutline(flow?.items ?? []);
    expect(outline.some((l) => l.question)).toBe(true);
    expect(outline.some((l) => l.text.startsWith("Jika: "))).toBe(true);
    const first = flow?.items[0];
    expect(first && first.kind !== "choice" ? describeNode(first) : "").toMatch(/^Pelanggan: /);
  });

  it("orders the diagrams as the journey: first use, then each menu (decision 328)", () => {
    const stages = flowStages();
    expect(stages.map((stage) => stage.title)).toEqual([
      "Tahap 1 · Memulai",
      "Tahap 2 · Penjualan",
      "Tahap 3 · Pembelian",
      "Tahap 4 · Kas & Bank",
      "Tahap 5 · Pembukuan (Akuntansi)",
      "Tahap 6 · Pajak",
      "Tahap 7 · Aset & Pendanaan",
      "Tahap 8 · Payroll",
      "Tahap 9 · Perencanaan",
      "Tahap 10 · Laporan",
      "Tahap 11 · Dokumen & Administrasi",
    ]);
    expect(stages.flatMap((stage) => stage.flows).length).toBe(FLOWS.length);
    expect(FLOWS[0]?.id).toBe("masuk-pertama-kali");
    for (const flow of FLOWS) expect(flow.stage, flow.id).toMatch(/^Tahap \d+ · /);
  });

  it("gives every diagram its own page with a previous and a next one", () => {
    expect(flowNumber(FLOWS[0]?.id ?? "")).toBe(1);
    expect(flowNeighbours(FLOWS[0]?.id ?? "").prev).toBeUndefined();
    expect(flowNeighbours(FLOWS.at(-1)?.id ?? "").next).toBeUndefined();
    const second = FLOWS[1];
    expect(flowNeighbours(second?.id ?? "").prev?.id).toBe(FLOWS[0]?.id);
    expect(flowNeighbours(second?.id ?? "").next?.id).toBe(FLOWS[2]?.id);
    expect(flowPageUrl("uang-masuk")).toBe("/guide/alur-kerja/uang-masuk");
  });

  it("covers every menu of the journey with at least one diagram", () => {
    const covered = new Set(FLOWS.flatMap((flow) => flow.guides));
    for (const slug of [
      "masuk-dan-ganti-entitas",
      "tambah-rekening",
      "buat-terbitkan-invoice",
      "catat-tagihan-vendor",
      "transfer-antar-rekening",
      "jurnal-manual",
      "bayar-pajak",
      "catat-aset-tetap",
      "jalankan-payroll-bulanan",
      "atur-transaksi-berulang",
      "laporan-keuangan-utama",
      "backup-restore",
    ])
      expect(covered.has(slug), slug).toBe(true);
  });
});
