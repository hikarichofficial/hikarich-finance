"use client";

import { useMemo, useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { VARIANT_TYPE_LABELS } from "@/domain/products/sku";
import type { SkuMasterKind, SkuMasterRow } from "@/schemas/sku";
import { saveSkuMasterAction, skuMasterStateAction } from "./skuActions";
import { idleSkuActionState } from "./skuActionsState";

const COPY: Readonly<
  Record<SkuMasterKind, { title: string; one: string; help: string; codeHelp: string }>
> = {
  brand: {
    title: "Kode 1 – Brand",
    one: "Brand",
    help: "Kode brand dipakai sebagai bagian pertama SKU, mis. Kamar EA = KEA.",
    codeHelp: "Huruf besar dan angka, maksimal 12. Harus unik di antara brand yang aktif.",
  },
  type: {
    title: "Kode 2 – Jenis Produk",
    one: "Jenis Produk",
    help: "Jenis produk, mis. Expert Advisor = EA. Daftar ini bebas Anda ubah dan tambah.",
    codeHelp: "Huruf besar dan angka, maksimal 12. Harus unik di antara jenis yang aktif.",
  },
  variant: {
    title: "Kode 4 – Variant",
    one: "Variant",
    help: "Bisa masa berlaku, paket, edisi, tier, atau apa pun. Setiap variant punya SKU, harga, dan status sendiri.",
    codeHelp:
      "Huruf besar dan angka, maksimal 12, mis. 1B atau BSC. Harus unik di antara variant aktif.",
  },
};

function statusOf(row: SkuMasterRow): { text: string; tone: string } {
  if (row.archived_at) return { text: "Diarsipkan", tone: "neutral" };
  return row.is_active ? { text: "Aktif", tone: "success" } : { text: "Nonaktif", tone: "warning" };
}

function StateButton({
  kind,
  entity,
  id,
  action,
  label,
  danger,
}: {
  kind: SkuMasterKind;
  entity: string | undefined;
  id: string;
  action: "activate" | "deactivate" | "archive" | "restore" | "delete";
  label: string;
  danger?: boolean;
}) {
  const [state, run, pending] = useActionState(skuMasterStateAction, idleSkuActionState);
  const form = usePreservingForm(run, state);
  return (
    <form {...form} className="sku-state-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="kind" value={kind} />
      <input type="hidden" name="id" value={id} />
      <input type="hidden" name="action" value={action} />
      <button
        type="submit"
        className={danger ? "btn-secondary btn-danger" : "btn-secondary"}
        disabled={pending}
      >
        {pending ? "…" : label}
      </button>
      {state.status === "error" ? (
        <span role="alert" className="error">
          {state.message}
        </span>
      ) : null}
    </form>
  );
}

function MasterForm({
  kind,
  entity,
  row,
  nextSort,
}: {
  kind: SkuMasterKind;
  entity: string | undefined;
  row: SkuMasterRow | null;
  nextSort: number;
}) {
  const [state, run, pending] = useActionState(saveSkuMasterAction, idleSkuActionState);
  const form = usePreservingForm(run, state);
  const copy = COPY[kind];
  return (
    <form {...form} className="record-form sku-master-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="kind" value={kind} />
      <input type="hidden" name="id" value={row?.id ?? ""} />
      <input type="hidden" name="version" value={row?.version ?? ""} />
      <label>
        Nama {copy.one}
        <input name="name" required maxLength={120} defaultValue={row?.name ?? ""} />
      </label>
      <label>
        Kode
        <input
          name="code"
          required
          maxLength={12}
          pattern="[A-Za-z0-9]{1,12}"
          style={{ textTransform: "uppercase" }}
          defaultValue={row?.code ?? ""}
        />
        <span className="hint">{copy.codeHelp}</span>
      </label>
      {kind === "variant" ? (
        <>
          <label>
            Jenis variant
            <select name="variant_type" defaultValue={row?.variant_type ?? "validity"}>
              {Object.entries(VARIANT_TYPE_LABELS).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Masa berlaku (hari, opsional)
            <input
              name="validity_days"
              type="number"
              min={1}
              defaultValue={row?.validity_days ?? ""}
              placeholder="mis. 30"
            />
          </label>
        </>
      ) : null}
      <label>
        Deskripsi (opsional)
        <input name="description" maxLength={500} defaultValue={row?.description ?? ""} />
      </label>
      <label>
        Urutan tampil
        <input name="sort_order" type="number" defaultValue={row?.sort_order ?? nextSort} />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : row ? "Simpan Perubahan" : `Tambah ${copy.one}`}
      </button>
    </form>
  );
}

/** Brands, product types and variants share one manager: add, edit, activate/deactivate, archive/restore, and
 * delete only what was never used (decision 324). Codes can be changed any time; existing SKUs keep theirs. */
export function SkuMasterManager({
  kind,
  rows,
  usedIds,
  entity,
}: {
  kind: SkuMasterKind;
  rows: readonly SkuMasterRow[];
  usedIds: readonly string[];
  entity: string | undefined;
}) {
  const copy = COPY[kind];
  const [query, setQuery] = useState("");
  const used = useMemo(() => new Set(usedIds), [usedIds]);
  const visible = rows.filter((row) => {
    const q = query.trim().toLowerCase();
    return q === "" || row.name.toLowerCase().includes(q) || row.code.toLowerCase().includes(q);
  });
  const nextSort = rows.reduce((max, row) => Math.max(max, row.sort_order), 0) + 10;

  return (
    <div className="sku-master">
      <p className="hint">{copy.help}</p>
      <details className="account-edit">
        <summary className="btn-primary">Tambah {copy.one}</summary>
        <MasterForm kind={kind} entity={entity} row={null} nextSort={nextSort} />
      </details>
      <input
        type="search"
        className="sku-search"
        placeholder={`Cari ${copy.one.toLowerCase()}…`}
        aria-label={`Cari ${copy.one}`}
        value={query}
        onChange={(event) => setQuery(event.target.value)}
      />
      {visible.length === 0 ? (
        <p className="hint">Tidak ada data.</p>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nama</th>
              <th scope="col">Kode</th>
              {kind === "variant" ? <th scope="col">Jenis</th> : null}
              <th scope="col">Status</th>
              <th scope="col">Dipakai</th>
              <th scope="col">Aksi</th>
            </tr>
          </thead>
          <tbody>
            {visible.map((row) => {
              const status = statusOf(row);
              const inUse = used.has(row.id);
              return (
                <tr key={row.id}>
                  <td>
                    <strong>{row.name}</strong>
                    {row.description ? <p className="hint">{row.description}</p> : null}
                  </td>
                  <td data-label="Kode">
                    <code>{row.code}</code>
                  </td>
                  {kind === "variant" ? (
                    <td data-label="Jenis">
                      {VARIANT_TYPE_LABELS[row.variant_type ?? "custom"] ?? "Lainnya"}
                      {row.validity_days ? ` · ${row.validity_days} hari` : ""}
                    </td>
                  ) : null}
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${status.tone}`}>
                      {status.text}
                    </span>
                  </td>
                  <td data-label="Dipakai">{inUse ? "Ya" : "Belum"}</td>
                  <td data-label="Aksi">
                    <div className="sku-actions">
                      <details className="account-edit">
                        <summary className="btn-secondary">Ubah</summary>
                        <MasterForm kind={kind} entity={entity} row={row} nextSort={nextSort} />
                      </details>
                      {row.archived_at ? (
                        <StateButton
                          kind={kind}
                          entity={entity}
                          id={row.id}
                          action="restore"
                          label="Pulihkan"
                        />
                      ) : (
                        <>
                          <StateButton
                            kind={kind}
                            entity={entity}
                            id={row.id}
                            action={row.is_active ? "deactivate" : "activate"}
                            label={row.is_active ? "Nonaktifkan" : "Aktifkan"}
                          />
                          <StateButton
                            kind={kind}
                            entity={entity}
                            id={row.id}
                            action="archive"
                            label="Arsipkan"
                          />
                        </>
                      )}
                      {!inUse ? (
                        <StateButton
                          kind={kind}
                          entity={entity}
                          id={row.id}
                          action="delete"
                          label="Hapus"
                          danger
                        />
                      ) : null}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      <p className="hint">
        Yang sudah pernah dipakai tidak bisa dihapus, hanya diarsipkan, supaya riwayat tetap aman.
        Mengubah kode hanya berlaku untuk SKU baru.
      </p>
    </div>
  );
}
