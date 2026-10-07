"use client";

import {
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type DragEvent,
  type KeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { StepUpLink } from "@/features/feedback/StepUp";
import { useActionState } from "@/features/feedback/useActionState";
import { InvoiceDocumentView } from "@/features/sales/InvoiceDocumentView";
import { alignmentGuides, type AlignmentGuide } from "@/domain/sales/invoiceGuides";
import {
  BLOCK_INFO,
  GRID_COLUMNS,
  LOGO_SIZE_LABEL,
  type BlockAlign,
  type DropTarget,
  type InvoiceBlockId,
  type InvoiceBlockSetting,
  type InvoiceLayout,
  type LogoSize,
  centerBlock,
  dropBlock,
  isDefaultLayout,
  laneRoom,
  pageMargins,
  parseInvoiceLayout,
  placementBounds,
  setPlacement,
  shiftRow,
  updateBlock,
} from "@/domain/sales/invoiceLayout";
import type { InvoiceDocument } from "@/schemas/sales";
import { saveInvoiceLayoutAction } from "./actions";
import { InvoiceIssuerFields, type IssuerDraft } from "./InvoiceIssuerFields";
import { idleTimeSettingsState } from "./actionsState";

/** The gap between two grid columns of the document, in pixels (`--doc-gap` in the stylesheet). */
const GAP = 12;

const ALIGN_LABEL: Record<BlockAlign, string> = { left: "Kiri", center: "Tengah", right: "Kanan" };

/** What the person is about to do with the dragged block, the box or line that shows it on the page, and the
 * smart guides of the place where the block would land. */
interface DropPreview {
  drop: DropTarget;
  kind: "line" | "box";
  box: CSSProperties;
  col: number;
  span: number;
  lines: GuideLine[];
}

/** A smart guide and where to draw it (pixels from the left edge of the page). */
interface GuideLine {
  guide: AlignmentGuide;
  left: number;
}

/** A grey stand-in so the preview shows where the logo goes when none is uploaded yet. */
const PLACEHOLDER_LOGO =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="180" height="72" viewBox="0 0 180 72">' +
      '<rect width="180" height="72" rx="8" fill="#ece8e1"/>' +
      '<text x="90" y="42" font-family="sans-serif" font-size="14" text-anchor="middle" fill="#8a8378">Logo</text></svg>',
  );

/**
 * The invoice layout editor (decisions 310, 318): the real invoice document drawn from sample data on a grid of
 * twelve columns. Every block can be dragged anywhere (above or below a row, or into a row at the column the
 * pointer is over), resized from its left and right edges, or placed with the numbers in the side panel; it snaps
 * to the columns so blocks never overlap. A ruler and guide lines (the columns, the page centre, the selected
 * block) show whether left and right are even. Nothing is stored until "Simpan Tampilan"; saving needs a recent
 * step-up and applies to invoices issued from then on.
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
  const [preview, setPreview] = useState<DropPreview | null>(null);
  const [guides, setGuides] = useState(true);
  const [state, action, pending] = useActionState(saveInvoiceLayoutAction, idleTimeSettingsState);
  const [resizing, setResizing] = useState(false);
  const [resizeLines, setResizeLines] = useState<GuideLine[]>([]);
  const wrapRef = useRef<HTMLDivElement>(null);

  const dirty =
    JSON.stringify(parseInvoiceLayout(layout)) !== JSON.stringify(parseInvoiceLayout(saved));
  const current = layout.blocks.find((block) => block.key === selected)!;
  const info = BLOCK_INFO[selected];
  const hidden = layout.blocks.filter((block) => !block.show);
  const serialized = useMemo(() => JSON.stringify(layout), [layout]);
  const bounds = placementBounds(layout, selected);
  const margins = pageMargins(layout, selected);

  /** Where the document's rows are on screen, and the width of one column. */
  function metrics() {
    const wrap = wrapRef.current;
    const rowsEl = wrap?.querySelector<HTMLElement>(".doc-rows");
    if (!wrap || !rowsEl) return null;
    const wrapBox = wrap.getBoundingClientRect();
    const rowsBox = rowsEl.getBoundingClientRect();
    const column = (rowsBox.width - GAP * (GRID_COLUMNS - 1)) / GRID_COLUMNS;
    return { wrapBox, rowsBox, rowsEl, column, pitch: column + GAP };
  }

  /** The grid column (1-24) under a horizontal pointer position. */
  function columnAt(clientX: number): number {
    const m = metrics();
    if (!m) return 1;
    const at = Math.floor((clientX - m.rowsBox.left + GAP / 2) / m.pitch) + 1;
    return Math.max(1, Math.min(GRID_COLUMNS, at));
  }

  /** The smart guides of a block at its place in a layout, with where to draw each line. */
  function guideLines(source: InvoiceLayout, id: InvoiceBlockId): GuideLine[] {
    const m = metrics();
    if (!m) return [];
    const origin = m.rowsBox.left - m.wrapBox.left;
    return alignmentGuides(source, id).map((guide) => ({
      guide,
      left:
        origin +
        guide.at * m.pitch -
        (guide.edge === "right" ? GAP : guide.edge === "center" ? GAP / 2 : 0),
    }));
  }

  /** Works out what dropping at this pointer position would do, and where to draw it. */
  function locate(clientX: number, clientY: number, id: InvoiceBlockId): DropPreview | null {
    const m = metrics();
    if (!m) return null;
    const rowEls = Array.from(m.rowsEl.querySelectorAll<HTMLElement>(".doc-row"));
    if (rowEls.length === 0) return null;
    let best: { el: HTMLElement; distance: number } | null = null;
    for (const el of rowEls) {
      const box = el.getBoundingClientRect();
      const distance =
        clientY < box.top ? box.top - clientY : clientY > box.bottom ? clientY - box.bottom : 0;
      if (!best || distance < best.distance) best = { el, distance };
    }
    const rowEl = best!.el;
    const box = rowEl.getBoundingClientRect();
    const rowId = Number(rowEl.dataset.rowId);
    const keys = (rowEl.dataset.blocks ?? "").split(" ");
    const column = columnAt(clientX);
    const left = m.rowsBox.left - m.wrapBox.left;
    const columnBox = (col: number, span: number): CSSProperties => ({
      left: left + (col - 1) * m.pitch,
      width: span * m.column + (span - 1) * GAP,
      top: box.top - m.wrapBox.top,
      height: box.height,
    });
    const lineBox = (y: number, from: number, width: number): CSSProperties => ({
      left: from,
      width,
      top: y - m.wrapBox.top - 2,
      height: 4,
    });
    const finish = (
      drop: DropTarget,
      kind: "line" | "box",
      boxStyle: CSSProperties,
    ): DropPreview => {
      const after = dropBlock(layout, id, drop);
      const moved = after.blocks.find((entry) => entry.key === id)!;
      return {
        drop,
        kind,
        box: boxStyle,
        col: moved.col,
        span: moved.span,
        lines: guideLines(after, id),
      };
    };
    const rowDrop = (at: "before" | "after") =>
      finish(
        { mode: "row", at, row: rowId, col: column },
        "line",
        lineBox(at === "before" ? box.top - 6 : box.bottom + 6, left, m.rowsBox.width),
      );

    // The item table takes a whole row; so does a block dragged over the row that holds it.
    if (BLOCK_INFO[id].fixedWidth || keys.includes("lines")) {
      return rowDrop(clientY < box.top + box.height / 2 ? "before" : "after");
    }
    const edge = Math.min(12, box.height * 0.25);
    if (clientY < box.top + edge) return rowDrop("before");
    if (clientY > box.bottom - edge) return rowDrop("after");

    const lanes = Array.from(rowEl.querySelectorAll<HTMLElement>(".doc-lane"));
    const lane = lanes.find((el) => {
      const first = Number(el.dataset.col);
      return column >= first && column <= first + Number(el.dataset.span) - 1;
    });
    if (lane) {
      const cells = Array.from(lane.querySelectorAll<HTMLElement>(".doc-cell")).filter(
        (el) => el.dataset.block !== id,
      );
      if (cells.length > 0) {
        // Stack above the first block whose middle is below the pointer, else under the last one.
        const next = cells.find((el) => {
          const cell = el.getBoundingClientRect();
          return clientY < cell.top + cell.height / 2;
        });
        const target = (next ?? cells[cells.length - 1])!;
        const at = next ? "before" : "after";
        const cell = target.getBoundingClientRect();
        const laneBox = lane.getBoundingClientRect();
        return finish(
          { mode: "stack", at, target: target.dataset.block as InvoiceBlockId },
          "line",
          lineBox(
            at === "before" ? cell.top - 5 : cell.bottom + 5,
            laneBox.left - m.wrapBox.left,
            laneBox.width,
          ),
        );
      }
    }
    // Empty columns (or the block's own lane): a lane of its own, where there is room.
    const room = laneRoom(layout, id, rowId, column);
    if (!room) return rowDrop("after");
    return finish({ mode: "lane", row: rowId, col: column }, "box", columnBox(room.col, room.span));
  }

  function onAreaDragOver(event: DragEvent<HTMLElement>) {
    if (!dragging) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    const next = locate(event.clientX, event.clientY, dragging);
    if (JSON.stringify(next) !== JSON.stringify(preview)) setPreview(next);
  }

  function onAreaDrop(event: DragEvent<HTMLElement>) {
    if (!dragging) return;
    event.preventDefault();
    const result = locate(event.clientX, event.clientY, dragging);
    if (result) {
      const id = dragging;
      setLayout((previous) => dropBlock(previous, id, result.drop));
      setSelected(id);
    }
    setDragging(null);
    setPreview(null);
  }

  /** Drags the left or right edge of the selected block's lane; it snaps to whole columns. */
  function startResize(edge: "left" | "right", event: ReactPointerEvent<HTMLElement>) {
    event.preventDefault();
    event.stopPropagation();
    const id = selected;
    let latest = layout;
    setResizing(true);
    const move = (pointer: PointerEvent) => {
      const column = columnAt(pointer.clientX);
      const me = latest.blocks.find((entry) => entry.key === id);
      if (!me) return;
      const limits = placementBounds(latest, id);
      const end = me.col + me.span - 1;
      if (edge === "left") {
        const col = Math.max(limits.min, Math.min(column, end));
        latest = setPlacement(latest, id, { col, span: end - col + 1 });
      } else {
        const last = Math.max(me.col, Math.min(column, limits.max));
        latest = setPlacement(latest, id, { span: last - me.col + 1 });
      }
      setLayout(latest);
      setResizeLines(guideLines(latest, id));
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      setResizing(false);
      setResizeLines([]);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  }

  /** The same edge change from the keyboard: the arrow keys move the focused edge one column. */
  function nudgeEdge(edge: "left" | "right", event: KeyboardEvent<HTMLElement>) {
    const step = event.key === "ArrowLeft" ? -1 : event.key === "ArrowRight" ? 1 : 0;
    if (step === 0) return;
    event.preventDefault();
    event.stopPropagation();
    setLayout((previous) => {
      const me = previous.blocks.find((entry) => entry.key === selected);
      if (!me) return previous;
      return edge === "left"
        ? setPlacement(previous, selected, { col: me.col + step, span: me.span - step })
        : setPlacement(previous, selected, { span: me.span + step });
    });
  }

  function wrap(setting: InvoiceBlockSetting, node: ReactNode): ReactNode {
    const id = setting.key;
    const resizable = selected === id && !BLOCK_INFO[id].fixedWidth;
    return (
      <div
        className="lay-block"
        data-selected={selected === id ? "true" : undefined}
        data-dragging={dragging === id ? "true" : undefined}
        data-block={id}
        draggable
        tabIndex={0}
        role="button"
        aria-label={`${BLOCK_INFO[id].label}. Seret untuk memindahkan, tekan Enter untuk memilih.`}
        onClick={() => setSelected(id)}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            setSelected(id);
          }
        }}
        onDragStart={(event) => {
          setDragging(id);
          setSelected(id);
          event.dataTransfer.effectAllowed = "move";
          event.dataTransfer.setData("text/plain", id);
        }}
        onDragEnd={() => {
          setDragging(null);
          setPreview(null);
        }}
      >
        <span className="lay-tag">
          {BLOCK_INFO[id].label} · kolom {setting.col}–{setting.col + setting.span - 1}
        </span>
        {node}
        {resizable ? (
          <>
            <button
              type="button"
              className="lay-handle"
              data-edge="left"
              title="Tarik untuk mengubah lebar (atau tekan panah kiri/kanan)"
              aria-label={`Ubah tepi kiri ${BLOCK_INFO[id].label}`}
              onMouseDown={(event) => event.preventDefault()}
              onPointerDown={(event) => startResize("left", event)}
              onKeyDown={(event) => nudgeEdge("left", event)}
            />
            <button
              type="button"
              className="lay-handle"
              data-edge="right"
              title="Tarik untuk mengubah lebar (atau tekan panah kiri/kanan)"
              aria-label={`Ubah tepi kanan ${BLOCK_INFO[id].label}`}
              onMouseDown={(event) => event.preventDefault()}
              onPointerDown={(event) => startResize("right", event)}
              onKeyDown={(event) => nudgeEdge("right", event)}
            />
          </>
        ) : null}
      </div>
    );
  }

  function change(next: Partial<Pick<InvoiceBlockSetting, "show" | "align">>) {
    setLayout((previous) => updateBlock(previous, selected, next));
  }

  function place(next: { col?: number; span?: number }) {
    setLayout((previous) => setPlacement(previous, selected, next));
  }

  const columns = Array.from({ length: GRID_COLUMNS }, (_, index) => index + 1);
  const balanced = margins.left === margins.right;
  const activeLines: GuideLine[] = guides
    ? preview
      ? preview.lines
      : resizing
        ? resizeLines
        : []
    : [];
  const shown = preview ?? (resizing ? { col: current.col, span: current.span } : null);
  const statusText =
    activeLines.length > 0
      ? activeLines.map(({ guide }) => guide.label).join(" · ")
      : shown
        ? `Jarak kiri ${shown.col - 1} kolom · kanan ${GRID_COLUMNS - (shown.col + shown.span - 1)} kolom`
        : "Seret bagian ke posisi baru; garis bantu muncul saat posisinya pas.";
  const mates = layout.blocks.filter(
    (block) =>
      block.show &&
      block.key !== selected &&
      block.row === current.row &&
      block.col === current.col &&
      block.span === current.span,
  );

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
          bagian mana pun: lepas di ruang kosong untuk menaruhnya di kolom itu, di bawah atau di
          atas bagian lain untuk menumpuknya (misalnya tepat di bawah nama PT), atau di garis tepi
          atas dan bawah baris untuk membuat baris baru. Tarik tepi kiri/kanan bagian yang dipilih
          untuk mengubah lebarnya. Garis merah muncul saat posisinya pas di tengah halaman, di tepi,
          atau sejajar dengan bagian lain. Semua menempel ke 24 kolom sehingga selalu rapi.
        </p>
        <label className="lay-guides-toggle">
          <input
            type="checkbox"
            checked={guides}
            onChange={(event) => setGuides(event.target.checked)}
          />{" "}
          Tampilkan penggaris dan garis bantu
        </label>
        <p
          className="lay-status"
          role="status"
          aria-live="polite"
          data-snapped={activeLines.length > 0 ? "true" : undefined}
        >
          {statusText}
        </p>
        <div
          className="lay-area"
          onDragOver={onAreaDragOver}
          onDrop={onAreaDrop}
          onDragLeave={(event) => {
            if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setPreview(null);
          }}
        >
          {guides ? (
            <div className="lay-ruler" aria-hidden="true">
              <div className="lay-ruler-cols">
                {columns.map((column) => (
                  <span
                    key={column}
                    data-active={
                      column >= current.col && column <= current.col + current.span - 1
                        ? "true"
                        : undefined
                    }
                  >
                    {column}
                  </span>
                ))}
              </div>
              <div className="lay-ruler-pct">
                {[0, 25, 50, 75, 100].map((percent) => (
                  <span key={percent} style={{ left: `${percent}%` }}>
                    {percent}%
                  </span>
                ))}
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
                <div className="lay-grid-cols">
                  {columns.map((column) => (
                    <span key={column} style={{ gridColumn: column }} />
                  ))}
                  <span
                    className="lay-band"
                    style={{ gridColumn: `${current.col} / span ${current.span}` }}
                  />
                </div>
                <span className="lay-center" />
              </div>
            ) : null}
            {preview ? (
              <div className="lay-drop" data-kind={preview.kind} style={preview.box} />
            ) : null}
            {activeLines.map(({ guide, left }) => (
              <div key={`${guide.edge}:${guide.at}`} className="lay-guide" style={{ left }}>
                <span>{guide.label}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      <form action={action} className="record-form lay-panel">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="layout" value={serialized} />

        <h3 className="dashboard-section-title">Bagian terpilih</h3>
        <p>
          <strong>{info.label}</strong>
          <br />
          <span className="hint">{info.hint}</span>
        </p>

        <fieldset className="lay-group">
          <legend>Posisi di halaman (24 kolom)</legend>
          {info.fixedWidth ? (
            <p className="hint">
              Tabel item selalu selebar halaman dan berada di barisnya sendiri; pindahkan naik atau
              turun saja.
            </p>
          ) : (
            <>
              <div className="lay-stepper">
                <span>Mulai kolom</span>
                <button
                  type="button"
                  aria-label="Mulai satu kolom lebih ke kiri"
                  disabled={current.col <= bounds.min}
                  onClick={() => place({ col: current.col - 1 })}
                >
                  −
                </button>
                <output>{current.col}</output>
                <button
                  type="button"
                  aria-label="Mulai satu kolom lebih ke kanan"
                  disabled={current.col + current.span - 1 >= bounds.max}
                  onClick={() => place({ col: current.col + 1 })}
                >
                  +
                </button>
              </div>
              <div className="lay-stepper">
                <span>Lebar (kolom)</span>
                <button
                  type="button"
                  aria-label="Lebar satu kolom lebih sempit"
                  disabled={current.span <= 1}
                  onClick={() => place({ span: current.span - 1 })}
                >
                  −
                </button>
                <output>{current.span}</output>
                <button
                  type="button"
                  aria-label="Lebar satu kolom lebih lebar"
                  disabled={current.col + current.span - 1 >= bounds.max}
                  onClick={() => place({ span: current.span + 1 })}
                >
                  +
                </button>
              </div>
              <div className="lay-segment">
                <button type="button" onClick={() => setLayout(centerBlock(layout, selected))}>
                  Tengahkan
                </button>
                <button type="button" onClick={() => place({ col: 1, span: GRID_COLUMNS })}>
                  Selebar halaman
                </button>
              </div>
            </>
          )}
          {mates.length > 0 ? (
            <p className="hint">
              Satu kolom dengan {mates.map((block) => BLOCK_INFO[block.key].label).join(", ")}:
              lebar dan posisi kolom berlaku untuk semuanya. Seret keluar untuk memisahkan.
            </p>
          ) : null}
          <p className="hint" data-balanced={balanced ? "true" : "false"}>
            Kolom {current.col}–{current.col + current.span - 1}. Ruang kosong di kiri{" "}
            {margins.left} kolom, di kanan {margins.right} kolom
            {balanced ? " — seimbang." : "."}
          </p>
        </fieldset>

        <fieldset className="lay-group">
          <legend>Perataan teks</legend>
          <div className="lay-segment">
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
        </fieldset>

        <fieldset className="lay-group">
          <legend>Urutan (layar sentuh)</legend>
          <div className="lay-segment">
            <button type="button" onClick={() => setLayout(shiftRow(layout, selected, "up"))}>
              Naik
            </button>
            <button type="button" onClick={() => setLayout(shiftRow(layout, selected, "down"))}>
              Turun
            </button>
          </div>
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

        <fieldset className="lay-group">
          <legend>Ukuran logo</legend>
          <div className="lay-segment">
            {(["sm", "md", "lg"] as const satisfies readonly LogoSize[]).map((value) => (
              <button
                key={value}
                type="button"
                aria-pressed={(layout.logo_size ?? "md") === value}
                onClick={() => setLayout({ ...layout, logo_size: value })}
              >
                {LOGO_SIZE_LABEL[value]}
              </button>
            ))}
          </div>
          {!logo ? (
            <p className="hint">Belum ada logo. Unggah di Pengaturan → Logo Perusahaan.</p>
          ) : null}
        </fieldset>

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
