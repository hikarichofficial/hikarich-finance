/**
 * The SKU generator's pure rules (decision 324). The database composes the real SKU (one place, atomic with the
 * numbering); this module only mirrors that composition so the settings screen can show a live preview of a format
 * the Owner has not saved yet, and holds the labels and error copy. Nothing here calls the database.
 */

export const SKU_PARTS = ["brand", "type", "seq", "variant"] as const;
export type SkuPart = (typeof SKU_PARTS)[number];

export interface SkuComponent {
  readonly key: SkuPart;
  readonly enabled: boolean;
  readonly required: boolean;
}

export type EmptyHandling = "skip" | "placeholder";
export type NumberScope = "global" | "brand" | "brand_type";

export interface SkuFormat {
  readonly components: readonly SkuComponent[];
  readonly separator: string;
  readonly prefix: string;
  readonly suffix: string;
  readonly emptyHandling: EmptyHandling;
  readonly emptyPlaceholder: string;
  readonly digits: number;
}

export const SKU_PART_LABELS: Readonly<Record<SkuPart, string>> = {
  brand: "Kode 1 – Brand",
  type: "Kode 2 – Jenis Produk",
  seq: "Kode 3 – Nomor Produk",
  variant: "Kode 4 – Variant",
};

export const SKU_PART_HELP: Readonly<Record<SkuPart, string>> = {
  brand: "Kode brand dipakai sebagai bagian SKU, mis. KEA.",
  type: "Kode jenis produk, mis. EA untuk Expert Advisor.",
  seq: "Nomor produk dibuat otomatis dan tidak pernah dipakai ulang.",
  variant:
    "Kode variant (masa berlaku, paket, tier, dst.), mis. 1B. Boleh kosong untuk produk utama.",
};

export const SKU_SEPARATORS: readonly { value: string; label: string }[] = [
  { value: "-", label: "Strip ( - )" },
  { value: "/", label: "Garis miring ( / )" },
  { value: ".", label: "Titik ( . )" },
  { value: "_", label: "Garis bawah ( _ )" },
  { value: ":", label: "Titik dua ( : )" },
  { value: "", label: "Tanpa pemisah" },
];

export const SKU_SCOPE_LABELS: Readonly<Record<NumberScope, string>> = {
  global: "Global (001, 002, 003 untuk semua produk)",
  brand: "Per Brand (KEA-001, KKM-001)",
  brand_type: "Per Brand + Jenis Produk (KEA-EA-001, KEA-IND-001) – disarankan",
};

export const VARIANT_TYPE_LABELS: Readonly<Record<string, string>> = {
  validity: "Masa berlaku",
  package: "Paket",
  edition: "Edisi",
  tier: "Tier",
  custom: "Lainnya",
};

/** Same composition as `app_private.compose_sku`: a switched-off or empty part leaves no double separator. */
export function composeSku(
  format: SkuFormat,
  values: {
    brand?: string | null;
    type?: string | null;
    number?: number | null;
    variant?: string | null;
  },
  options: { base?: boolean } = {},
): { sku: string } | { error: SkuPart | "empty" } {
  const parts: string[] = [];
  if (format.prefix !== "") parts.push(format.prefix);
  for (const component of format.components) {
    if (!component.enabled) continue;
    let value: string | null | undefined;
    switch (component.key) {
      case "brand":
        value = values.brand;
        break;
      case "type":
        value = values.type;
        break;
      case "seq":
        value =
          values.number === null || values.number === undefined
            ? null
            : String(values.number).padStart(format.digits, "0");
        break;
      case "variant":
        value = values.variant;
        break;
    }
    if (value === null || value === undefined || value === "") {
      if (component.required && !(options.base && component.key === "variant")) {
        return { error: component.key };
      }
      if (format.emptyHandling === "placeholder") value = format.emptyPlaceholder;
      else continue;
    }
    parts.push(value);
  }
  if (format.suffix !== "") parts.push(format.suffix);
  if (parts.length === 0) return { error: "empty" };
  return { sku: parts.join(format.separator) };
}

/** Indonesian copy for what the SKU database functions refuse with (never shows database detail). */
export function describeSkuError(message: string, sqlState?: string): string {
  if (message.includes("SKU_OVERRIDE_FORBIDDEN")) {
    return "Hanya OWNER (atau peran yang diberi izin khusus) yang boleh mengisi atau mengubah SKU secara manual.";
  }
  if (message.includes("SKU_MASTER_IN_USE")) {
    return "Sudah pernah dipakai pada produk, jadi tidak boleh dihapus. Arsipkan saja.";
  }
  if (message.includes("SKU_MASTER_CONFLICT")) {
    return "Data sudah diubah orang lain. Muat ulang halaman lalu coba lagi.";
  }
  if (message.includes("SKU_STRUCTURE_LOCKED")) {
    return "Nomor produk dan variant tidak dapat diubah setelah dibuat.";
  }
  if (message.includes("SKU_PART_REQUIRED")) {
    return "Ada bagian SKU yang wajib diisi (Brand atau Jenis Produk) tetapi masih kosong.";
  }
  if (message.includes("SKU_NUMBER_EXHAUSTED")) {
    return "Nomor produk bentrok dengan SKU lain. Periksa pengaturan nomor lalu coba lagi.";
  }
  if (message.includes("SKU_PARENT_INVALID")) {
    return "Produk induk tidak valid untuk membuat variant.";
  }
  if (sqlState === "23505" || message.includes("duplicate key")) {
    if (message.includes("_code_uq")) return "Kode itu sudah dipakai oleh data aktif lain.";
    if (message.includes("parent_variant")) return "Variant itu sudah ada pada produk ini.";
    return "SKU itu sudah dipakai produk lain. SKU harus unik.";
  }
  if (sqlState === "23514") {
    return "Isian tidak valid. Kode hanya huruf besar dan angka (maks. 12), pemisah hanya satu atau dua tanda.";
  }
  if (sqlState === "42501") return "Anda tidak memiliki izin untuk tindakan ini.";
  return "Perubahan SKU tidak dapat disimpan.";
}
