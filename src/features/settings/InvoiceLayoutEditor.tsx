"use client";

import {
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { StepUpLink } from "@/features/feedback/StepUp";
import { useActionState } from "@/features/feedback/useActionState";
import { InvoiceDocumentView } from "@/features/sales/InvoiceDocumentView";
import { snapAxis, type GuideHit, type GuideTarget } from "@/domain/sales/invoiceGuides";
import {
  BLOCK_INFO,
  MAX_HEIGHT,
  MAX_OFFSET,
  MIN_WIDTH,
  SIZE_LABEL,
  SIZE_ORDER,
  alignToPage,
  canFollow,
  descendants,
  isDefaultLayout,
  parseInvoiceLayout,
  updateBlock,
  type BlockAlign,
  type BlockSize,
  type BlockValign,
  type BlockZone,
  type InvoiceBlockId,
  type InvoiceBlockSetting,
  type InvoiceLayout,
} from "@/domain/sales/invoiceLayout";
import type { InvoiceDocument } from "@/schemas/sales";
import { saveInvoiceLayoutAction } from "./actions";
import { InvoiceIssuerFields, type IssuerDraft } from "./InvoiceIssuerFields";
import { idleTimeSettingsState } from "./actionsState";

const ALIGN_LABEL: Record<BlockAlign, string> = { left: "Kiri", center: "Tengah", right: "Kanan" };
const VALIGN_LABEL: Record<BlockValign, string> = {
  top: "Atas",
  middle: "Tengah",
  bottom: "Bawah",
};

/** How close (screen pixels) an edge has to be to a guide to snap onto it. */
const SNAP = 6;
/** A block dropped this far (pixels) above the bottom of another one still counts as under it. */
const DETACH = 6;
/** A root block dropped within this many pixels under another block sticks to it ("follows" it). */
const STICK = 18;

/** A grey stand-in so the preview shows where the logo goes when none is uploaded yet. */
const PLACEHOLDER_LOGO =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="180" height="72" viewBox="0 0 180 72">' +
      '<rect width="180" height="72" rx="8" fill="#ece8e1"/>' +
      '<text x="90" y="42" font-family="sans-serif" font-size="14" text-anchor="middle" fill="#8a8378">Logo</text></svg>',
  );

type Edge = "left" | "right" | "bottom";

/** Where everything is on screen when a drag starts (the page does not move while a block is dragged). */
interface Frame {
  wrap: DOMRect;
  canvas: DOMRect;
  page: number;
  zones: Record<BlockZone, DOMRect>;
  boxes: { key: InvoiceBlockId; rect: DOMRect; parent: InvoiceBlockId | null }[];
}

/** The guide lines to draw, in pixels inside the page wrapper. */
interface Overlay {
  xs: { left: number; label: string }[];
  ys: { top: number; label: string }[];
}

function frameOf(root: HTMLElement): Frame {
  const canvas = root.querySelector<HTMLElement>(".doc-canvas")!.getBoundingClientRect();
  const zones = { head: canvas, table: canvas, foot: canvas } as Record<BlockZone, DOMRect>;
  root.querySelectorAll<HTMLElement>(".doc-zone").forEach((el) => {
    zones[el.dataset.zone as BlockZone] = el.getBoundingClientRect();
  });
  const boxes = Array.from(root.querySelectorAll<HTMLElement>(".doc-box[data-box]")).map((el) => {
    const node = el.closest<HTMLElement>(".doc-node");
    const parent = node?.parentElement?.closest<HTMLElement>(".doc-node")?.dataset.node ?? null;
    return {
      key: el.dataset.box as InvoiceBlockId,
      rect: el.getBoundingClientRect(),
      parent: parent as InvoiceBlockId | null,
    };
  });
  return { wrap: root.getBoundingClientRect(), canvas, page: canvas.width, zones, boxes };
}

function targetsX(frame: Frame, skip: Set<InvoiceBlockId>): GuideTarget[] {
  const out: GuideTarget[] = [
    { at: frame.canvas.left, label: "Tepi kiri halaman" },
    { at: frame.canvas.left + frame.canvas.width / 2, label: "Tengah halaman" },
    { at: frame.canvas.right, label: "Tepi kanan halaman" },
  ];
  for (const other of frame.boxes) {
    if (skip.has(other.key)) continue;
    const name = BLOCK_INFO[other.key].label;
    out.push(
      { at: other.rect.left, label: `Kiri ${name}` },
      { at: other.rect.left + other.rect.width / 2, label: `Tengah ${name}` },
      { at: other.rect.right, label: `Kanan ${name}` },
    );
  }
  return out;
}

function targetsY(frame: Frame, skip: Set<InvoiceBlockId>): GuideTarget[] {
  const out: GuideTarget[] = [
    { at: frame.zones.head.top, label: "Atas halaman" },
    { at: frame.zones.foot.top, label: "Bawah tabel" },
  ];
  for (const other of frame.boxes) {
    if (skip.has(other.key)) continue;
    const name = BLOCK_INFO[other.key].label;
    out.push(
      { at: other.rect.top, label: `Atas ${name}` },
      { at: other.rect.top + other.rect.height / 2, label: `Tengah ${name}` },
      { at: other.rect.bottom, label: `Bawah ${name}` },
    );
  }
  return out;
}

/** The labels of a guide, at most two: the page first, then the first block it lines up with. */
function guideLabel(hit: GuideHit): string {
  return hit.labels.length > 2
    ? `${hit.labels.slice(0, 2).join(", ")} (+${hit.labels.length - 2})`
    : hit.labels.join(", ");
}

function overlayOf(frame: Frame, xs: GuideHit[], ys: GuideHit[]): Overlay {
  return {
    xs: xs.map((hit) => ({ left: hit.at - frame.wrap.left, label: guideLabel(hit) })),
    ys: ys.map((hit) => ({ top: hit.at - frame.wrap.top, label: guideLabel(hit) })),
  };
}

function percent(value: number): string {
  return `${Math.round(value * 10) / 10}%`.replace(".", ",");
}

/**
 * Where a dragged block lands (decision 321). It keeps following the block it followed while it stays below it,
 * sticks to a block it is dropped right under, and otherwise becomes a block of its own at the place where it was
 * dropped, in the zone (above or below the item table) it was dropped in.
 */
function placeMoved(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  frame: Frame,
  box: Frame["boxes"][number],
  dx: number,
  dy: number,
  stick: boolean,
): InvoiceLayout {
  const me = layout.blocks.find((entry) => entry.key === id)!;
  const top = box.rect.top + dy;
  const x = me.x + (dx / frame.page) * 100;
  if (box.parent) {
    const parent = frame.boxes.find((other) => other.key === box.parent);
    if (parent) {
      const gap = top - parent.rect.bottom;
      if (gap >= -DETACH) {
        return updateBlock(layout, id, {
          x,
          y: Math.max(0, Math.round(gap)),
          after: box.parent,
        });
      }
    }
  }
  if (stick) {
    const kids = descendants(layout.blocks, id);
    const left = box.rect.left + dx;
    const right = left + box.rect.width;
    let near: { key: InvoiceBlockId; gap: number } | null = null;
    for (const other of frame.boxes) {
      if (other.key === id || kids.has(other.key) || other.key === "lines") continue;
      const gap = top - other.rect.bottom;
      if (gap < -DETACH || gap > STICK) continue;
      const overlap = Math.min(right, other.rect.right) - Math.max(left, other.rect.left);
      if (overlap < 0.3 * Math.min(box.rect.width, other.rect.width)) continue;
      if (!near || Math.abs(gap) < Math.abs(near.gap)) near = { key: other.key, gap };
    }
    if (near) {
      return updateBlock(layout, id, {
        x,
        y: Math.max(0, Math.round(near.gap)),
        after: near.key,
      });
    }
  }
  const table = frame.zones.table;
  const zone: BlockZone =
    top + box.rect.height / 2 < table.top + table.height / 2 ? "head" : "foot";
  return updateBlock(layout, id, {
    x,
    zone,
    after: null,
    y: Math.max(0, Math.round(top - frame.zones[zone].top)),
  });
}

/**
 * The invoice layout editor (decisions 310, 318, 319, 321): the real invoice document drawn from sample data. There
 * is no grid. Every block can be dragged anywhere on the page, widened to the left or right, made taller downwards,
 * and given another text size; red guide lines show when it lines up with the page edges, the page centre or another
 * block. A block dropped right under another one follows it, so the company name stays under the logo whatever its
 * size. Nothing is stored until "Simpan Tampilan"; saving needs a recent step-up and applies to invoices issued
 * from then on.
 */
export function InvoiceLayoutEditor({
  entity,
  saved,
  logo,
  sample,
  issuer,
  stepUpHref,
}: {
  entity: string | undefined;
  saved: InvoiceLayout;
  logo: string | null;
  sample: InvoiceDocument;
  /** The company details as saved (Pengaturan), editable beside the preview. */
  issuer: { values: IssuerDraft; website: string; version: number };
  stepUpHref: string;
}) {
  const [layout, setLayout] = useState<InvoiceLayout>(saved);
  const [issuerDraft, setIssuerDraft] = useState<IssuerDraft>(issuer.values);
  // The preview shows what is typed in the company fields; empty text counts as "not filled in".
  const liveSample = useMemo<InvoiceDocument>(
    () => ({
      ...sample,
      issuer: {
        ...(sample.issuer as Record<string, unknown>),
        ...Object.fromEntries(
          Object.entries(issuerDraft).map(([key, value]) => [
            key,
            value.trim() === "" ? null : value,
          ]),
        ),
      },
    }),
    [sample, issuerDraft],
  );
  const [selected, setSelected] = useState<InvoiceBlockId>("issuer");
  const [dragging, setDragging] = useState<InvoiceBlockId | null>(null);
  const [guides, setGuides] = useState(true);
  const [magnet, setMagnet] = useState(true);
  const [overlay, setOverlay] = useState<Overlay | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [state, action, pending] = useActionState(saveInvoiceLayoutAction, idleTimeSettingsState);
  const wrapRef = useRef<HTMLDivElement>(null);
  /** After a drop the block is measured once and moved the few pixels the page shifted under it. */
  const [settle, setSettle] = useState<{ id: InvoiceBlockId; top: number; round: number } | null>(
    null,
  );

  /** Pairs of blocks that are drawn on top of each other: free placement allows it, but it is almost never meant. */
  const [overlaps, setOverlaps] = useState<string[]>([]);

  const dirty =
    JSON.stringify(parseInvoiceLayout(layout)) !== JSON.stringify(parseInvoiceLayout(saved));
  const current = layout.blocks.find((block) => block.key === selected)!;
  const info = BLOCK_INFO[selected];
  const hidden = layout.blocks.filter((block) => !block.show);
  const serialized = useMemo(() => JSON.stringify(layout), [layout]);

  useLayoutEffect(() => {
    if (!settle || !wrapRef.current) return;
    const el = wrapRef.current.querySelector<HTMLElement>(`.doc-box[data-box="${settle.id}"]`);
    if (!el) {
      setSettle(null);
      return;
    }
    const error = settle.top - el.getBoundingClientRect().top;
    if (Math.abs(error) < 1 || settle.round >= 2) {
      setSettle(null);
      return;
    }
    setLayout((previous) => {
      const me = previous.blocks.find((block) => block.key === settle.id)!;
      return updateBlock(previous, settle.id, { y: me.y + Math.round(error) });
    });
    setSettle({ ...settle, round: settle.round + 1 });
  }, [settle]);

  useLayoutEffect(() => {
    const root = wrapRef.current;
    if (!root) return;
    const boxes = Array.from(root.querySelectorAll<HTMLElement>(".doc-box[data-box]")).map(
      (el) => ({
        key: el.dataset.box as InvoiceBlockId,
        rect: el.getBoundingClientRect(),
      }),
    );
    const found: string[] = [];
    for (let i = 0; i < boxes.length; i += 1) {
      for (let j = i + 1; j < boxes.length; j += 1) {
        const a = boxes[i]!;
        const c = boxes[j]!;
        const across = Math.min(a.rect.right, c.rect.right) - Math.max(a.rect.left, c.rect.left);
        const down = Math.min(a.rect.bottom, c.rect.bottom) - Math.max(a.rect.top, c.rect.top);
        if (across > 3 && down > 3) {
          found.push(`${BLOCK_INFO[a.key].label} dan ${BLOCK_INFO[c.key].label}`);
        }
      }
    }
    setOverlaps((previous) => (previous.join("|") === found.join("|") ? previous : found));
  }, [layout, issuerDraft]);

  /** Drags the block (with the blocks that follow it) with the pointer; it is placed when the pointer is let go. */
  function startMove(event: ReactPointerEvent<HTMLElement>, id: InvoiceBlockId) {
    if (event.button !== 0) return;
    setSelected(id);
    const root = wrapRef.current;
    const nodeEl = event.currentTarget.closest<HTMLElement>(".doc-node");
    if (BLOCK_INFO[id].fixed || !root || !nodeEl) return;
    const frame = frameOf(root);
    const box = frame.boxes.find((entry) => entry.key === id);
    if (!box) return;
    const skip = new Set<InvoiceBlockId>([id, ...descendants(layout.blocks, id)]);
    const tx = targetsX(frame, skip);
    const ty = targetsY(frame, skip);
    const startX = event.clientX;
    const startY = event.clientY;
    let moved = false;
    let dx = 0;
    let dy = 0;
    let stick = true;
    const move = (pointer: PointerEvent) => {
      let ddx = pointer.clientX - startX;
      let ddy = pointer.clientY - startY;
      if (!moved && Math.hypot(ddx, ddy) < 4) return;
      if (!moved) {
        moved = true;
        nodeEl.dataset.moving = "true";
        setDragging(id);
      }
      stick = !pointer.altKey;
      let hitsX: GuideHit[] = [];
      let hitsY: GuideHit[] = [];
      const left = box.rect.left;
      const width = box.rect.width;
      const top = box.rect.top;
      const height = box.rect.height;
      ddx = Math.max(frame.canvas.left - left, Math.min(frame.canvas.right - box.rect.right, ddx));
      if (magnet && !pointer.altKey) {
        const sx = snapAxis(
          [
            { at: left + ddx, part: "start" },
            { at: left + width / 2 + ddx, part: "middle" },
            { at: left + width + ddx, part: "end" },
          ],
          tx,
          SNAP,
        );
        if (sx) {
          ddx += sx.delta;
          hitsX = sx.hits;
        }
        const sy = snapAxis(
          [
            { at: top + ddy, part: "start" },
            { at: top + height / 2 + ddy, part: "middle" },
            { at: top + height + ddy, part: "end" },
          ],
          ty,
          SNAP,
        );
        if (sy) {
          ddy += sy.delta;
          hitsY = sy.hits;
        }
      }
      dx = ddx;
      dy = ddy;
      nodeEl.style.transform = `translate(${dx}px, ${dy}px)`;
      setOverlay(overlayOf(frame, hitsX, hitsY));
      const leftPct = ((left + dx - frame.canvas.left) / frame.page) * 100;
      const names = [...hitsX, ...hitsY].map(guideLabel);
      setStatus(
        names.length > 0
          ? names.join(" · ")
          : `Kiri ${percent(leftPct)} · kanan ${percent(100 - leftPct - (width / frame.page) * 100)}`,
      );
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      nodeEl.style.transform = "";
      delete nodeEl.dataset.moving;
      setDragging(null);
      setOverlay(null);
      setStatus(null);
      if (!moved) return;
      setLayout((previous) => placeMoved(previous, id, frame, box, dx, dy, stick));
      setSettle({ id, top: box.rect.top + dy, round: 0 });
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  /** Drags an edge of the selected block: left and right change its width, the bottom its height. */
  function startResize(
    event: ReactPointerEvent<HTMLElement>,
    id: InvoiceBlockId,
    edges: readonly Edge[],
  ) {
    event.preventDefault();
    event.stopPropagation();
    const root = wrapRef.current;
    if (!root) return;
    const nodeEl = root.querySelector<HTMLElement>(`.doc-node[data-node="${id}"]`);
    const boxEl = root.querySelector<HTMLElement>(`.doc-box[data-box="${id}"]`);
    if (!nodeEl || !boxEl) return;
    const frame = frameOf(root);
    const box = frame.boxes.find((entry) => entry.key === id)!;
    const me = layout.blocks.find((entry) => entry.key === id)!;
    const skip = new Set<InvoiceBlockId>([id, ...descendants(layout.blocks, id)]);
    const tx = targetsX(frame, skip);
    const ty = targetsY(frame, skip);
    const was = {
      x: nodeEl.style.getPropertyValue("--x"),
      w: nodeEl.style.getPropertyValue("--w"),
      bh: boxEl.style.getPropertyValue("--bh"),
    };
    const startX = event.clientX;
    const startY = event.clientY;
    let x = me.x;
    let w = me.w;
    let h = me.h;
    let changed = false;
    const move = (pointer: PointerEvent) => {
      changed = true;
      const free = magnet && !pointer.altKey;
      let left = box.rect.left;
      let right = box.rect.right;
      let bottom = box.rect.bottom;
      const hitsX: GuideHit[] = [];
      const hitsY: GuideHit[] = [];
      if (edges.includes("left")) left += pointer.clientX - startX;
      if (edges.includes("right")) right += pointer.clientX - startX;
      if (edges.includes("bottom")) bottom += pointer.clientY - startY;
      if (free && edges.includes("left")) {
        const snap = snapAxis([{ at: left, part: "start" }], tx, SNAP);
        if (snap) {
          left += snap.delta;
          hitsX.push(...snap.hits);
        }
      }
      if (free && edges.includes("right")) {
        const snap = snapAxis([{ at: right, part: "end" }], tx, SNAP);
        if (snap) {
          right += snap.delta;
          hitsX.push(...snap.hits);
        }
      }
      if (free && edges.includes("bottom")) {
        const snap = snapAxis([{ at: bottom, part: "end" }], ty, SNAP);
        if (snap) {
          bottom += snap.delta;
          hitsY.push(...snap.hits);
        }
      }
      let from = Math.max(0, Math.min(100, ((left - frame.canvas.left) / frame.page) * 100));
      let to = Math.max(0, Math.min(100, ((right - frame.canvas.left) / frame.page) * 100));
      if (to - from < MIN_WIDTH) {
        if (edges.includes("left")) from = to - MIN_WIDTH;
        else to = from + MIN_WIDTH;
      }
      from = Math.max(0, from);
      to = Math.min(100, to);
      x = Math.round(from * 10) / 10;
      w = Math.round((to - from) * 10) / 10;
      if (edges.includes("bottom")) {
        h = Math.max(0, Math.min(MAX_HEIGHT, Math.round(bottom - box.rect.top)));
        boxEl.style.setProperty("--bh", `${h}px`);
      }
      nodeEl.style.setProperty("--x", String(x));
      nodeEl.style.setProperty("--w", String(w));
      setOverlay(overlayOf(frame, hitsX, hitsY));
      setStatus(
        [...hitsX, ...hitsY].length > 0
          ? [...hitsX, ...hitsY].map(guideLabel).join(" · ")
          : `Lebar ${percent(w)} · kiri ${percent(x)} · kanan ${percent(100 - x - w)}` +
              (h > 0 ? ` · tinggi ${h} px` : ""),
      );
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      for (const [name, value] of [
        ["--x", was.x],
        ["--w", was.w],
      ] as const) {
        if (value) nodeEl.style.setProperty(name, value);
        else nodeEl.style.removeProperty(name);
      }
      if (was.bh) boxEl.style.setProperty("--bh", was.bh);
      else boxEl.style.removeProperty("--bh");
      setOverlay(null);
      setStatus(null);
      if (changed) setLayout((previous) => updateBlock(previous, id, { x, w, h }));
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  /** The arrow keys on a focused block: left and right move it by half a percent, up and down by two pixels
   * (Shift: four times as much). */
  function nudge(event: KeyboardEvent<HTMLElement>, setting: InvoiceBlockSetting) {
    if (event.target !== event.currentTarget) return;
    const big = event.shiftKey ? 4 : 1;
    const step =
      event.key === "ArrowLeft"
        ? { x: -0.5 * big }
        : event.key === "ArrowRight"
          ? { x: 0.5 * big }
          : event.key === "ArrowUp"
            ? { y: -2 * big }
            : event.key === "ArrowDown"
              ? { y: 2 * big }
              : null;
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      setSelected(setting.key);
      return;
    }
    if (!step || BLOCK_INFO[setting.key].fixed) return;
    event.preventDefault();
    setLayout((previous) =>
      updateBlock(previous, setting.key, {
        x: setting.x + (step.x ?? 0),
        y: setting.y + (step.y ?? 0),
      }),
    );
  }

  function wrap(setting: InvoiceBlockSetting, node: ReactNode): ReactNode {
    const id = setting.key;
    const chosen = selected === id;
    const fixed = BLOCK_INFO[id].fixed;
    const handle = (edges: readonly Edge[], name: string, label: string) => (
      <span
        key={name}
        className="lay-handle"
        data-handle={name}
        role="presentation"
        title={label}
        onPointerDown={(event) => startResize(event, id, edges)}
      />
    );
    return (
      <div
        className="lay-block"
        data-selected={chosen ? "true" : undefined}
        data-dragging={dragging === id ? "true" : undefined}
        data-fixed={fixed ? "true" : undefined}
        data-block={id}
        tabIndex={0}
        role="button"
        aria-label={`${BLOCK_INFO[id].label}. Seret untuk memindahkan, panah untuk menggeser, Enter untuk memilih.`}
        onPointerDown={(event) => startMove(event, id)}
        onKeyDown={(event) => nudge(event, setting)}
      >
        <span className="lay-tag">
          {BLOCK_INFO[id].label}
          {fixed ? "" : ` · ${percent(setting.x)} – ${percent(setting.x + setting.w)}`}
        </span>
        {node}
        {chosen && !fixed ? (
          <>
            {handle(["left"], "left", "Tarik untuk melebarkan ke kiri")}
            {handle(["right"], "right", "Tarik untuk melebarkan ke kanan")}
            {handle(["bottom"], "bottom", "Tarik untuk memanjangkan ke bawah")}
            {handle(["left", "bottom"], "bottom-left", "Tarik untuk melebarkan ke kiri dan bawah")}
            {handle(
              ["right", "bottom"],
              "bottom-right",
              "Tarik untuk melebarkan ke kanan dan bawah",
            )}
          </>
        ) : null}
      </div>
    );
  }

  function change(next: Partial<Omit<InvoiceBlockSetting, "key">>) {
    setLayout((previous) => updateBlock(previous, selected, next));
  }

  function number(value: string, low: number, high: number, whole: boolean): number | null {
    const parsed = Number(value.replace(",", "."));
    if (value.trim() === "" || !Number.isFinite(parsed)) return null;
    const clamped = Math.max(low, Math.min(high, parsed));
    return whole ? Math.round(clamped) : clamped;
  }

  const followable = layout.blocks.filter(
    (block) => block.key !== selected && canFollow(layout.blocks, selected, block.key),
  );
  const parentName = current.after ? BLOCK_INFO[current.after].label : null;
  const statusText =
    status ??
    `${info.label}: kiri ${percent(current.x)} · kanan ${percent(100 - current.x - current.w)} · lebar ${percent(current.w)}`;

  return (
    <div className="lay-editor">
      <div className="lay-preview">
        <InvoiceIssuerFields
          entity={entity}
          saved={issuer.values}
          draft={issuerDraft}
          onChange={setIssuerDraft}
          website={issuer.website}
          version={issuer.version}
          stepUpHref={stepUpHref}
        />
        <p className="hint">
          Contoh tampilan: data perusahaan di atas asli, pelanggan dan rincian hanya contoh. Seret
          bagian mana pun ke tempat yang diinginkan. Tarik tepi kiri, kanan, atau bawah bagian yang
          dipilih untuk melebarkan atau memanjangkannya. Garis merah muncul saat posisinya pas di
          tengah halaman, di tepi, atau sejajar dengan bagian lain. Bagian yang dilepas tepat di
          bawah bagian lain akan mengikutinya (misalnya nama PT tetap di bawah logo berapa pun
          ukurannya). Tahan Alt saat menyeret untuk menonaktifkan penempelan.
        </p>
        <div className="lay-toggles">
          <label>
            <input
              type="checkbox"
              checked={guides}
              onChange={(event) => setGuides(event.target.checked)}
            />{" "}
            Penggaris dan garis tengah
          </label>
          <label>
            <input
              type="checkbox"
              checked={magnet}
              onChange={(event) => setMagnet(event.target.checked)}
            />{" "}
            Tempel ke garis bantu
          </label>
        </div>
        <p
          className="lay-status"
          role="status"
          aria-live="polite"
          data-snapped={overlay && overlay.xs.length + overlay.ys.length > 0 ? "true" : undefined}
        >
          {statusText}
        </p>
        {overlaps.length > 0 ? (
          <p className="lay-warn" role="alert">
            Perhatian, bagian saling menimpa: {overlaps.join("; ")}. Geser salah satunya atau pilih
            “Mengikuti” agar tetap di bawah bagian di atasnya.
          </p>
        ) : null}
        <div className="lay-area">
          {guides ? (
            <div className="lay-ruler" aria-hidden="true">
              <div className="lay-ruler-pct">
                {[0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100].map((value) => (
                  <span key={value} style={{ left: `${value}%` }} data-major={value % 25 === 0}>
                    {value % 25 === 0 ? `${value}%` : ""}
                  </span>
                ))}
                <i
                  className="lay-ruler-band"
                  style={{ left: `${current.x}%`, width: `${current.w}%` }}
                />
              </div>
            </div>
          ) : null}
          <div className="lay-doc-wrap" ref={wrapRef}>
            <InvoiceDocumentView
              doc={liveSample}
              logo={logo ?? PLACEHOLDER_LOGO}
              layout={layout}
              wrapBlock={wrap}
            />
            {guides ? (
              <div className="lay-grid" aria-hidden="true">
                <span className="lay-edge" data-at="left" />
                <span className="lay-center" />
                <span className="lay-edge" data-at="right" />
              </div>
            ) : null}
            {overlay ? (
              <div className="lay-lines" aria-hidden="true">
                {overlay.xs.map((line) => (
                  <div
                    key={`x${line.left}`}
                    className="lay-guide"
                    data-axis="x"
                    style={{ left: line.left }}
                  >
                    <span>{line.label}</span>
                  </div>
                ))}
                {overlay.ys.map((line) => (
                  <div
                    key={`y${line.top}`}
                    className="lay-guide"
                    data-axis="y"
                    style={{ top: line.top }}
                  >
                    <span>{line.label}</span>
                  </div>
                ))}
              </div>
            ) : null}
          </div>
        </div>
      </div>

      <form action={action} className="record-form lay-panel">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="layout" value={serialized} />

        <h3 className="dashboard-section-title">Bagian terpilih</h3>
        <label className="lay-pick">
          <span className="sr-only">Pilih bagian</span>
          <select
            value={selected}
            onChange={(event) => setSelected(event.target.value as InvoiceBlockId)}
          >
            {layout.blocks.map((block) => (
              <option key={block.key} value={block.key}>
                {BLOCK_INFO[block.key].label}
                {block.show ? "" : " (disembunyikan)"}
              </option>
            ))}
          </select>
        </label>
        <p className="hint">{info.hint}</p>

        {info.fixed ? (
          <p className="hint">
            Tabel item selalu selebar halaman, di antara bagian atas dan bagian bawah. Bagian lain
            bisa diletakkan di atas atau di bawahnya.
          </p>
        ) : (
          <>
            <fieldset className="lay-group">
              <legend>Posisi dan ukuran</legend>
              <div className="lay-fields">
                <label>
                  <span>Dari kiri (%)</span>
                  <input
                    type="number"
                    min={0}
                    max={100}
                    step={0.5}
                    value={current.x}
                    onChange={(event) => {
                      const next = number(event.target.value, 0, 100, false);
                      if (next !== null) change({ x: next });
                    }}
                  />
                </label>
                <label>
                  <span>Lebar (%)</span>
                  <input
                    type="number"
                    min={MIN_WIDTH}
                    max={100}
                    step={0.5}
                    value={current.w}
                    onChange={(event) => {
                      const next = number(event.target.value, MIN_WIDTH, 100, false);
                      if (next !== null) change({ w: next });
                    }}
                  />
                </label>
                <label>
                  <span>{parentName ? "Jarak ke bawah (px)" : "Dari atas area (px)"}</span>
                  <input
                    type="number"
                    min={0}
                    max={MAX_OFFSET}
                    step={2}
                    value={current.y}
                    onChange={(event) => {
                      const next = number(event.target.value, 0, MAX_OFFSET, true);
                      if (next !== null) change({ y: next });
                    }}
                  />
                </label>
                <label>
                  <span>Tinggi minimal (px)</span>
                  <input
                    type="number"
                    min={0}
                    max={MAX_HEIGHT}
                    step={4}
                    value={current.h}
                    onChange={(event) => {
                      const next = number(event.target.value, 0, MAX_HEIGHT, true);
                      if (next !== null) change({ h: next });
                    }}
                  />
                </label>
              </div>
              <p className="hint">Tinggi 0 berarti menyesuaikan isi.</p>
              <div className="lay-segment">
                <button
                  type="button"
                  onClick={() => setLayout(alignToPage(layout, selected, "left"))}
                >
                  Ke kiri halaman
                </button>
                <button
                  type="button"
                  onClick={() => setLayout(alignToPage(layout, selected, "center"))}
                >
                  Tengahkan
                </button>
                <button
                  type="button"
                  onClick={() => setLayout(alignToPage(layout, selected, "right"))}
                >
                  Ke kanan halaman
                </button>
                <button type="button" onClick={() => change({ x: 0, w: 100 })}>
                  Selebar halaman
                </button>
              </div>
            </fieldset>

            <fieldset className="lay-group">
              <legend>Letak</legend>
              <label className="lay-pick">
                <span className="hint">Mengikuti (tetap di bawah bagian ini)</span>
                <select
                  value={current.after ?? ""}
                  onChange={(event) =>
                    change({
                      after: (event.target.value || null) as InvoiceBlockId | null,
                      ...(event.target.value ? { y: Math.max(8, current.y) } : {}),
                    })
                  }
                >
                  <option value="">Tidak — bebas</option>
                  {followable.map((block) => (
                    <option key={block.key} value={block.key}>
                      {BLOCK_INFO[block.key].label}
                    </option>
                  ))}
                </select>
              </label>
              {parentName ? (
                <p className="hint">
                  Ikut bergeser bersama {parentName}: selalu di bawahnya, berapa pun tingginya.
                </p>
              ) : (
                <div className="lay-segment">
                  {(["head", "foot"] as const).map((value) => (
                    <button
                      key={value}
                      type="button"
                      aria-pressed={current.zone === value}
                      onClick={() =>
                        change({ zone: value, y: current.zone === value ? current.y : 0 })
                      }
                    >
                      {value === "head" ? "Di atas tabel" : "Di bawah tabel"}
                    </button>
                  ))}
                </div>
              )}
            </fieldset>
          </>
        )}

        <fieldset className="lay-group">
          <legend>Teks</legend>
          <div className="lay-segment" role="group" aria-label="Perataan teks">
            {(["left", "center", "right"] as const).map((value) => (
              <button
                key={value}
                type="button"
                aria-pressed={current.align === value}
                disabled={!info.canAlign}
                onClick={() => change({ align: value })}
              >
                {ALIGN_LABEL[value]}
              </button>
            ))}
          </div>
          <p className="hint">Posisi vertikal isi (bila bagian dibuat lebih tinggi)</p>
          <div className="lay-segment" role="group" aria-label="Posisi vertikal isi">
            {(["top", "middle", "bottom"] as const).map((value) => (
              <button
                key={value}
                type="button"
                aria-pressed={current.valign === value}
                disabled={info.fixed}
                onClick={() => change({ valign: value })}
              >
                {VALIGN_LABEL[value]}
              </button>
            ))}
          </div>
          <p className="hint">Ukuran huruf{selected === "logo" ? " dan logo" : ""}</p>
          <div className="lay-segment" role="group" aria-label="Ukuran huruf">
            {SIZE_ORDER.map((value: BlockSize) => (
              <button
                key={value}
                type="button"
                aria-pressed={current.size === value}
                disabled={info.fixed}
                onClick={() => change({ size: value })}
              >
                {SIZE_LABEL[value]}
              </button>
            ))}
          </div>
          {selected === "logo" && !logo ? (
            <p className="hint">Belum ada logo. Unggah di Pengaturan → Logo Perusahaan.</p>
          ) : null}
        </fieldset>

        <div className="lay-group">
          <button
            type="button"
            className="btn-secondary"
            disabled={info.required}
            onClick={() => change({ show: false })}
          >
            Sembunyikan bagian ini
          </button>
          {info.required ? (
            <p className="hint">
              Bagian ini memuat nomor, pihak, tanggal, atau angka invoice sehingga tidak bisa
              disembunyikan.
            </p>
          ) : null}
        </div>

        {hidden.length > 0 ? (
          <fieldset className="lay-group">
            <legend>Bagian yang disembunyikan</legend>
            {hidden.map((block) => (
              <div key={block.key} className="lay-hidden-row">
                <span>{BLOCK_INFO[block.key].label}</span>
                <button
                  type="button"
                  className="btn-secondary"
                  onClick={() => {
                    setLayout((previous) => updateBlock(previous, block.key, { show: true }));
                    setSelected(block.key);
                  }}
                >
                  Tampilkan
                </button>
              </div>
            ))}
          </fieldset>
        ) : null}

        <p className="hint">
          Tampilan yang disimpan berlaku untuk invoice yang diterbitkan setelah ini, termasuk draf
          yang belum terbit. Invoice yang sudah terbit tetap seperti saat diterbitkan. Perubahan
          memerlukan verifikasi ulang.{" "}
          <StepUpLink href={stepUpHref}>Verifikasi sekarang</StepUpLink>.
        </p>

        <div className="record-form-actions">
          <button type="submit" className="btn-primary" disabled={pending || !dirty}>
            {pending ? "Menyimpan…" : "Simpan Tampilan"}
          </button>
          <button
            type="button"
            className="btn-secondary"
            disabled={pending || isDefaultLayout(layout)}
            onClick={() => setLayout(parseInvoiceLayout(null))}
          >
            Kembalikan ke Bawaan
          </button>
        </div>
        {dirty ? <p className="hint">Ada perubahan yang belum disimpan.</p> : null}
        {state.status !== "idle" ? (
          <p
            role={state.status === "error" ? "alert" : "status"}
            className={state.status === "error" ? "error" : "hint"}
          >
            {state.message}
            {state.stepUp ? (
              <>
                {" "}
                <StepUpLink href={stepUpHref}>Verifikasi sekarang</StepUpLink>.
              </>
            ) : null}
          </p>
        ) : null}
      </form>
    </div>
  );
}
