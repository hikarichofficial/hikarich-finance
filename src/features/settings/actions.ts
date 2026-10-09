"use server";

import { revalidatePath } from "next/cache";
import {
  DOCUMENT_NAME_STYLE_LABELS,
  documentNameStyle,
} from "@/domain/settings/documentNames";
import { redirect } from "next/navigation";
import { setFlash } from "@/lib/flash";
import { LOGO_MAX_UPLOAD_BYTES, LogoImageError, compressLogo } from "@/lib/logoImage";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { isFiscalYearLockedMessage } from "@/domain/settings/settings";
import { requirePermission } from "@/services/identity/access";
import {
  type InvoiceLayout,
  isDefaultLayout,
  parseInvoiceLayout,
} from "@/domain/sales/invoiceLayout";
import { IdentityError, type IdentityFailureKind } from "@/domain/settings/identityFailure";
import {
  createEntity,
  setEntityLogo,
  setInvoiceLayout,
  setDocumentNameStyle,
  setNegativeBalanceBlock,
  updateEntityIdentity,
  updateEntityTimeSettings,
} from "@/services/settings/settings";

/** Settings write (decision 248): the Entity's timezone and fiscal-year start. The RPC re-checks the
 * permission, step-up, reason, version and the fiscal-year lock. */

export interface TimeSettingsState {
  status: "idle" | "ok" | "error";
  message?: string;
  stepUp?: boolean;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function updateTimeSettingsAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  try {
    const { membership } = await requirePermission("system.entity_config", {
      entityCode: text(formData, "entity"),
    });
    await updateEntityTimeSettings({
      entity_id: membership.entity_id,
      timezone: text(formData, "timezone"),
      fiscal_year_start_month: Number(text(formData, "fiscal_year_start_month")),
      expected_version: Number(text(formData, "expected_version")),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      if (error.code === "CONFLICT" && isFiscalYearLockedMessage(error.message)) {
        return {
          status: "error",
          message: "Awal tahun buku tidak dapat diubah karena periode akuntansi sudah ada.",
        };
      }
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return {
      status: "error",
      message: "Pengaturan tidak dapat disimpan. Pastikan alasan diisi minimal 5 karakter.",
    };
  }
  revalidatePath("/admin/settings");
  return { status: "ok", message: "Zona waktu dan tahun buku disimpan." };
}

/** Settings write (decision 55, OWNER answer 4 October 2026): which account kinds (bank/cash/ewallet) may
 * never go negative. The RPC re-checks `system.entity_config` and a recent step-up; an empty selection
 * blocks none. */
export async function setNegativeBalanceBlockAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  const kinds = formData.getAll("kind").filter((v): v is string => typeof v === "string");
  try {
    const { membership } = await requirePermission("system.entity_config", {
      entityCode: text(formData, "entity"),
    });
    await setNegativeBalanceBlock({ entity_id: membership.entity_id, kinds: kinds as never });
  } catch (error) {
    if (error instanceof AuthzError) {
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return { status: "error", message: "Pengaturan tidak dapat disimpan." };
  }
  revalidatePath("/admin/settings");
  return {
    status: "ok",
    message:
      kinds.length === 0
        ? "Tidak ada jenis akun yang dikunci."
        : `Saldo ${kinds.join(", ")} tidak boleh minus.`,
  };
}

export async function setDocumentNameStyleAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  const style = documentNameStyle(text(formData, "name_style"));
  try {
    const { membership } = await requirePermission("system.entity_config", {
      entityCode: text(formData, "entity"),
    });
    await setDocumentNameStyle(membership.entity_id, style);
  } catch (error) {
    if (error instanceof AuthzError) {
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return { status: "error", message: "Pengaturan nama dokumen tidak dapat disimpan." };
  }
  revalidatePath("/admin/settings");
  return { status: "ok", message: `Dokumen memakai ${DOCUMENT_NAME_STYLE_LABELS[style]}.` };
}

const IDENTITY_FAILURE_TEXT: Record<IdentityFailureKind, string> = {
  conflict: "Data perusahaan sudah diubah di tempat lain. Muat ulang halaman ini lalu simpan lagi.",
  email: "Alamat email tidak valid. Perbaiki atau kosongkan, lalu simpan lagi.",
  too_long: "Ada isian yang terlalu panjang. Persingkat lalu simpan lagi.",
  legal_name: "Nama Resmi wajib diisi.",
  other:
    "Data perusahaan tidak dapat disimpan. Coba sekali lagi; bila terulang, beri tahu pengembang.",
};

/** The reason a company-data save was refused (decision 317); the database's own text is logged for the developer. */
function describeIdentityFailure(error: unknown): string {
  if (error instanceof IdentityError) {
    if (error.kind === "other") console.error("update_entity_identity refused:", error.detail);
    return IDENTITY_FAILURE_TEXT[error.kind];
  }
  console.error("update_entity_identity failed:", error);
  return IDENTITY_FAILURE_TEXT.other;
}

/** Settings write (decision 272): the Entity's names, address and contact details. The RPC re-checks the
 * permission, step-up and version. Issued documents keep the name they were issued with. */
export async function updateEntityIdentityAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  try {
    const { membership } = await requirePermission("system.entity_config", {
      entityCode: text(formData, "entity"),
    });
    await updateEntityIdentity({
      entity_id: membership.entity_id,
      legal_name: text(formData, "legal_name"),
      brand_name: text(formData, "brand_name"),
      address_line: text(formData, "address_line"),
      city: text(formData, "city"),
      province: text(formData, "province"),
      postal_code: text(formData, "postal_code"),
      contact_email: text(formData, "contact_email"),
      contact_phone: text(formData, "contact_phone"),
      website: text(formData, "website"),
      expected_version: Number(text(formData, "expected_version")),
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return { status: "error", message: describeIdentityFailure(error) };
  }
  revalidatePath("/", "layout");
  return { status: "ok", message: "Nama dan profil disimpan." };
}

/** Settings write (decision 307): upload or remove the company logo shown on invoices and receipts. */
export async function updateEntityLogoAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  let storedKb = 0;
  try {
    const { membership } = await requirePermission("system.entity_config", {
      entityCode: text(formData, "entity"),
    });
    if (text(formData, "remove") === "1") {
      await setEntityLogo(membership.entity_id, null);
    } else {
      const file = formData.get("logo");
      if (!(file instanceof File) || file.size === 0) {
        return { status: "error", message: "Pilih file logo (PNG, JPEG, atau WebP) lebih dulu." };
      }
      if (file.size > LOGO_MAX_UPLOAD_BYTES) {
        return { status: "error", message: "Ukuran file terlalu besar. Maksimal 4 MB." };
      }
      // The picture is shrunk to a small WebP before it is stored; the original is not kept.
      const compressed = await compressLogo(Buffer.from(await file.arrayBuffer()));
      await setEntityLogo(membership.entity_id, compressed.dataUrl);
      storedKb = Math.max(1, Math.round(compressed.bytes / 1024));
    }
  } catch (error) {
    if (error instanceof AuthzError) {
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    if (error instanceof LogoImageError) {
      return {
        status: "error",
        message: "File bukan gambar PNG, JPEG, atau WebP yang valid (maksimal 4 MB).",
      };
    }
    return { status: "error", message: "Logo tidak dapat disimpan. Coba gambar yang lebih kecil." };
  }
  revalidatePath("/", "layout");
  return {
    status: "ok",
    message:
      text(formData, "remove") === "1"
        ? "Logo dihapus."
        : `Logo disimpan dan diperkecil otomatis (${storedKb} KB). Invoice dan kuitansi menampilkan logo ini.`,
  };
}

/** Add an Entity (decision 276). `create_entity` decides who may; on success the person lands on the new
 * Entity's Settings, where the address and tax details are filled in next. */
export async function createEntityAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  const code = text(formData, "code").toLowerCase();
  try {
    await createEntity({
      code,
      entity_type: text(formData, "entity_type") === "personal" ? "personal" : "company",
      legal_name: text(formData, "legal_name"),
      brand_name: text(formData, "brand_name"),
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return {
      status: "error",
      message:
        "Entity tidak dapat dibuat. Kode: 2 sampai 31 huruf kecil, angka, - atau _, diawali huruf.",
    };
  }
  revalidatePath("/", "layout");
  await setFlash("Entity dibuat.");
  redirect(`/admin/settings?entity=${encodeURIComponent(code)}`);
}

/** Settings write (decision 310): save the arrangement of the invoice document. The standard arrangement is
 * stored as "none". It applies to invoices issued from now on; an invoice already issued keeps its own look. */
export async function saveInvoiceLayoutAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  let layout: InvoiceLayout;
  try {
    layout = parseInvoiceLayout(JSON.parse(text(formData, "layout")));
  } catch {
    return {
      status: "error",
      message: "Tampilan tidak terbaca. Muat ulang halaman lalu coba lagi.",
    };
  }
  try {
    const { membership } = await requirePermission("system.entity_config", {
      entityCode: text(formData, "entity"),
    });
    await setInvoiceLayout(membership.entity_id, isDefaultLayout(layout) ? null : layout);
  } catch (error) {
    if (error instanceof AuthzError) {
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return { status: "error", message: "Tampilan invoice tidak dapat disimpan. Coba lagi." };
  }
  revalidatePath("/", "layout");
  return {
    status: "ok",
    message: "Tampilan invoice disimpan. Berlaku untuk invoice yang diterbitkan berikutnya.",
  };
}
