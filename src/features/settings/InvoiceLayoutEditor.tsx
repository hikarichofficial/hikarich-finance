"use client";

import { useMemo, useState, type DragEvent, type ReactNode } from "react";
import { StepUpLink } from "@/features/feedback/StepUp";
import { useActionState } from "@/features/feedback/useActionState";
import { InvoiceDocumentView } from "@/features/sales/InvoiceDocumentView";
import {
  BLOCK_INFO,
  LOGO_SIZE_LABEL,
  type BlockAlign,
  type BlockWidth,
  type InvoiceBlockId,
  type InvoiceBlockSetting,
  type InvoiceLayout,
  type LogoSize,
  isDefaultLayout,
  moveBlock,
  parseInvoiceLayout,
  updateBlock,
} from "@/domain/sales/invoiceLayout";
import type { InvoiceDocument } from "@/schemas/sales";
import { saveInvoiceLayoutAction } from "./actions";
import { InvoiceIssuerFields, type IssuerDraft } from "./InvoiceIssuerFields";
import { idleTimeSettingsState } from "./actionsState";

type DropSide = "left" | "right" | "top" | "bottom";

const ALIGN_LABEL: Record<BlockAlign, string> = { left: "Kiri", center: "Tengah", right: "Kanan" };
const WIDTH_LABEL: Record<BlockWidth, string> = {
  fit: "Sesuai isi",
  half: "Setengah",
  full: "Penuh",
};

/** A grey stand-in so the preview shows where the logo goes when none is uploaded yet. */
const PLACEHOLDER_LOGO =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="180" height="72" viewBox="0 0 180 72">' +
      '<rect width="180" height="72" rx="8" fill="#ece8e1"/>' +
      '<text x="90" y="42" font-family="sans-serif" font-size="14" text-anchor="middle" fill="#8a8378">Logo</text></svg>',
  );

/**
 * The invoice layout editor (decision 310): the real invoice document drawn from sample data, every block of
 * which can be dragged (above or below another block, or to the left or right of it to share a row), plus a
 * side panel for the selected block (alignment, width, up/down for touch screens, hide) and the logo size.
 * Nothing is stored until "Simpan Tampilan"; saving needs a recent step-up and applies to invoices issued from
 * then on.
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
  const [drop, setDrop] = useState<{ id: InvoiceBlockId; side: DropSide } | null>(null);
  const [state, action, pending] = useActionState(saveInvoiceLayoutAction, idleTimeSettingsState);

  const dirty =
    JSON.stringify(parseInvoiceLayout(layout)) !== JSON.stringify(parseInvoiceLayout(saved));
  const current = layout.blocks.find((block) => block.key === selected)!;
  const info = BLOCK_INFO[selected];
  const index = layout.blocks.findIndex((block) => block.key === selected);
  const hidden = layout.blocks.filter((block) => !block.show);
  const serialized = useMemo(() => JSON.stringify(layout), [layout]);

  function dropOn(target: InvoiceBlockId, side: DropSide) {
    if (!dragging || dragging === target) return;
    const targetIndexBefore = layout.blocks.findIndex((block) => block.key === target);
    const draggedIndex = layout.blocks.findIndex((block) => block.key === dragging);
    // The index of the target once the dragged block has been taken out of the list.
    const targetIndex = targetIndexBefore - (draggedIndex < targetIndexBefore ? 1 : 0);
    const after = side === "right" || side === "bottom";
    let next = moveBlock(layout, dragging, targetIndex + (after ? 1 : 0));
    if (side === "left" || side === "right") {
      // Sharing a row needs both blocks to be narrower than the row (the item table and totals cannot be):
      // a logo takes only its own width so the name can sit right beside it, the others take half.
      next = updateBlock(next, dragging, { width: dragging === "logo" ? "fit" : "half" });
      next = updateBlock(next, target, { width: target === "logo" ? "fit" : "half" });
    }
    setLayout(next);
    setSelected(dragging);
  }

  function sideOf(event: DragEvent<HTMLElement>, target: InvoiceBlockId): DropSide {
    const rect = event.currentTarget.getBoundingClientRect();
    const x = (event.clientX - rect.left) / Math.max(1, rect.width);
    const y = (event.clientY - rect.top) / Math.max(1, rect.height);
    const canShare = !BLOCK_INFO[target].fixedWidth && !BLOCK_INFO[dragging!].fixedWidth;
    if (canShare && x < 0.25) return "left";
    if (canShare && x > 0.75) return "right";
    return y < 0.5 ? "top" : "bottom";
  }

  function wrap(setting: InvoiceBlockSetting, node: ReactNode): ReactNode {
    const id = setting.key;
    const over = drop?.id === id ? drop.side : undefined;
    return (
      <div
        className="lay-block"
        data-selected={selected === id ? "true" : undefined}
        data-dragging={dragging === id ? "true" : undefined}
        data-drop={over}
        data-width={setting.width}
        data-align={setting.align}
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
          setDrop(null);
        }}
        onDragOver={(event) => {
          if (!dragging || dragging === id) return;
          event.preventDefault();
          event.dataTransfer.dropEffect = "move";
          const side = sideOf(event, id);
          if (drop?.id !== id || drop.side !== side) setDrop({ id, side });
        }}
        onDragLeave={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDrop(null);
        }}
        onDrop={(event) => {
          event.preventDefault();
          if (drop) dropOn(id, drop.side);
          setDragging(null);
          setDrop(null);
        }}
      >
        <span className="lay-tag">{BLOCK_INFO[id].label}</span>
        {node}
      </div>
    );
  }

  function change(next: Partial<Pick<InvoiceBlockSetting, "show" | "align" | "width">>) {
    setLayout((previous) => updateBlock(previous, selected, next));
  }

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
          bagian mana pun: lepas di atas atau bawah bagian lain untuk menukar urutan, atau di tepi
          kiri/kanan untuk menaruhnya sebaris. Klik bagian untuk mengatur perataan dan lebarnya.
        </p>
        <InvoiceDocumentView
          doc={liveSample}
          logo={logo ?? PLACEHOLDER_LOGO}
          layout={layout}
          wrapBlock={wrap}
        />
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
          <legend>Perataan</legend>
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
          <legend>Lebar</legend>
          <div className="lay-segment">
            {(["fit", "half", "full"] as const).map((value) => (
              <button
                key={value}
                type="button"
                aria-pressed={current.width === value}
                disabled={info.fixedWidth}
                onClick={() => change({ width: value })}
              >
                {WIDTH_LABEL[value]}
              </button>
            ))}
          </div>
          {info.fixedWidth ? (
            <p className="hint">
              Bagian ini selalu selebar halaman (tabel) atau selebar kotak total.
            </p>
          ) : null}
        </fieldset>

        <fieldset className="lay-group">
          <legend>Urutan (untuk layar sentuh)</legend>
          <div className="lay-segment">
            <button
              type="button"
              disabled={index <= 0}
              onClick={() => setLayout(moveBlock(layout, selected, index - 1))}
            >
              Naik
            </button>
            <button
              type="button"
              disabled={index >= layout.blocks.length - 1}
              onClick={() => setLayout(moveBlock(layout, selected, index + 1))}
            >
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
