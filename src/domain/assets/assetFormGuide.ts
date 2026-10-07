/**
 * Help for the fixed-asset forms (decision 343): the figures the person would otherwise have to know, worked out
 * from the kind of asset, and plain-language guidance when the database refuses a form. Display and form help only;
 * the database validates and computes every plan itself.
 */
import { findFiscalClass, type FiscalClass } from "./fiscalClasses";

/** The shortest remaining life given to a used asset, so a very old asset never gets a zero or tiny life. */
export const MIN_USED_LIFE_MONTHS = 12;

/**
 * The remaining useful life, for the financial statements, of an asset bought used: the life of its group less its
 * age (whole years from the year of manufacture to the year it was put in service), never below one year. The tax
 * (fiscal) schedule is not shortened: the tax rules give a used asset the full life of its group.
 */
export function usedAssetLifeMonths(
  classLifeMonths: number,
  manufactureYear: number,
  serviceDate: string,
): number {
  const serviceYear = Number(serviceDate.slice(0, 4));
  if (!Number.isInteger(serviceYear) || !Number.isInteger(manufactureYear)) return classLifeMonths;
  const ageMonths = Math.max(0, (serviceYear - manufactureYear) * 12);
  return Math.max(MIN_USED_LIFE_MONTHS, classLifeMonths - ageMonths);
}

/**
 * Months from the in-service month through the cut-over month, both included: how many months of depreciation the
 * asset has already lived when the app starts recording it (the same count the database uses).
 */
export function elapsedMonths(serviceDate: string, cutoverDate: string): number | null {
  const [sy, sm] = serviceDate.split("-").map(Number);
  const [cy, cm] = cutoverDate.split("-").map(Number);
  if (!sy || !sm || !cy || !cm) return null;
  const months = (cy - sy) * 12 + (cm - sm) + 1;
  return months >= 1 ? months : null;
}

/**
 * Depreciation already taken by the cut-over date, straight line: the monthly amount times the months lived, never
 * more than the cost less the residual. `null` when the figures are not usable. A suggestion for the form only.
 */
export function suggestedAccumulated(
  cost: string,
  residual: string,
  lifeMonths: string,
  serviceDate: string,
  cutoverDate: string,
): number | null {
  const c = Number(cost);
  const r = residual.trim() === "" ? 0 : Number(residual);
  const life = Number(lifeMonths);
  const elapsed = elapsedMonths(serviceDate, cutoverDate);
  if (!Number.isFinite(c) || !Number.isFinite(r) || !Number.isInteger(life) || life <= 0)
    return null;
  if (elapsed === null || c <= 0 || r < 0 || r >= c) return null;
  const base = c - r;
  return Math.min(base, Math.round((base / life) * elapsed));
}

/**
 * The fixed-asset account a kind of asset normally goes on, by the code of the default chart: a hint for the fiscal
 * group (the name of the asset is checked first). `notDepreciated` for land and assets still under construction.
 */
const ACCOUNT_CODE_DEFAULTS: Readonly<
  Record<string, { classKey: string | null; notDepreciated?: boolean }>
> = {
  "1501": { classKey: "land", notDepreciated: true },
  "1502": { classKey: "building_permanent" },
  "1503": { classKey: "building_non_permanent" },
  "1504": { classKey: "building_non_permanent" },
  "1505": { classKey: "building_non_permanent" },
  "1510": { classKey: "group_1" },
  "1511": { classKey: "group_1" },
  "1512": { classKey: "group_1" },
  "1513": { classKey: "group_2" },
  "1514": { classKey: "group_1" },
  "1515": { classKey: "group_1" },
  "1516": { classKey: "group_2" },
  "1520": { classKey: "group_1" },
  "1531": { classKey: "group_2" },
  "1532": { classKey: "group_1" },
  "1533": { classKey: "group_3" },
  "1534": { classKey: "group_3" },
  "1540": { classKey: null, notDepreciated: true },
  "1550": { classKey: null },
  "1560": { classKey: "group_1" },
  "1570": { classKey: null, notDepreciated: true },
};

export function accountDefault(code: string | null | undefined): {
  fiscalClass: FiscalClass | null;
  notDepreciated: boolean;
} | null {
  const hit = code ? ACCOUNT_CODE_DEFAULTS[code] : undefined;
  if (!hit) return null;
  return {
    fiscalClass: hit.classKey ? findFiscalClass(hit.classKey) : null,
    notDepreciated: hit.notDepreciated === true,
  };
}

export interface AssetFieldGuide {
  /** The `name` of the form field to mark in red. */
  field: string;
  /** What to do about it, in plain Indonesian. */
  fix: string;
}

const GUIDES: readonly { test: RegExp; guide: AssetFieldGuide }[] = [
  {
    test: /useful life of .* is used up but a value above the residual remains/,
    guide: {
      field: "accumulated",
      fix: "Umur manfaat aset ini sudah habis tetapi nilainya belum nol. Isi “Penyusutan yang Sudah Dicatat” sebesar harga perolehan dikurangi nilai sisa (tombol Isi otomatis), atau perbesar umur manfaat.",
    },
  },
  {
    test: /the life, residual or accumulated depreciation of .* does not fit its cost/,
    guide: {
      field: "accumulated",
      fix: "Penyusutan yang sudah dicatat ditambah nilai sisa tidak boleh lebih besar dari harga perolehan, dan umur manfaat harus 1 sampai 1200 bulan. Periksa ketiganya.",
    },
  },
  {
    test: /fiscal class of .* is unknown or does not allow that method|that fiscal class allows straight-line only/,
    guide: {
      field: "fiscal_method",
      fix: "Bangunan hanya boleh memakai garis lurus untuk pajak. Pilih “Garis lurus” pada Metode Penyusutan Fiskal, atau ganti Jenis Aset.",
    },
  },
  {
    test: /needs acquisition <= in-service <= cut-over <= today/,
    guide: {
      field: "in_service_date",
      fix: "Urutan tanggal harus: Tanggal Beli, lalu Mulai Dipakai, lalu Tanggal Mulai Dicatat, dan tidak boleh melewati hari ini. Perbaiki tanggal yang urutannya terbalik.",
    },
  },
  {
    test: /in-service date is not before the acquisition/,
    guide: {
      field: "in_service_date",
      fix: "Mulai Dipakai tidak boleh sebelum tanggal beli dan tidak boleh di masa depan.",
    },
  },
  {
    test: /no longer accepts postings; choose an in-service date from an open period/,
    guide: {
      field: "in_service_date",
      fix: "Periode pembukuan bulan itu sudah ditutup. Pilih tanggal mulai dipakai pada periode yang masih terbuka.",
    },
  },
  {
    test: /date is missing or outside the accepted range/,
    guide: {
      field: "acquisition_date",
      fix: "Tanggal harus antara 1 Januari 2000 dan satu tahun ke depan. Periksa tanggal beli.",
    },
  },
  {
    test: /cost account of .* is not a fixed-asset account/,
    guide: {
      field: "cost_account",
      fix: "Pilih salah satu akun aset tetap dari daftar.",
    },
  },
  {
    test: /is not depreciated, so it has no life, residual or accumulated depreciation/,
    guide: {
      field: "method",
      fix: "Aset yang tidak disusutkan (mis. tanah) tidak punya umur manfaat, nilai sisa, atau penyusutan. Kosongkan ketiganya, atau pilih metode penyusutan.",
    },
  },
  {
    test: /the method of .* is not allowed for this Entity|personal assets are tracked at cost/,
    guide: {
      field: "method",
      fix: "Entity pribadi mencatat aset sebesar harga perolehan tanpa penyusutan. Pilih “Tidak disusutkan”.",
    },
  },
  {
    test: /the useful life is 1 to 1200 months/,
    guide: { field: "life_months", fix: "Umur manfaat harus antara 1 dan 1200 bulan." },
  },
  {
    test: /the residual value cannot exceed the cost/,
    guide: { field: "residual", fix: "Nilai sisa tidak boleh lebih besar dari harga perolehan." },
  },
  {
    test: /was bought used, so its year of manufacture is needed|an asset bought used needs its year of manufacture/,
    guide: {
      field: "manufacture_year",
      fix: "Aset bekas perlu tahun pembuatannya. Isi tahun saat barang itu keluar dari pabrik atau dealer, atau pilih “Baru”.",
    },
  },
  {
    test: /year of manufacture .* is before 1900 or after the year it was bought|year of manufacture is before 1900/,
    guide: {
      field: "manufacture_year",
      fix: "Tahun pembuatan tidak boleh setelah tahun pembelian. Periksa angkanya.",
    },
  },
  {
    test: /year of manufacture .* is not a number/,
    guide: { field: "manufacture_year", fix: "Tahun pembuatan harus berupa angka, mis. 2019." },
  },
  {
    test: /FX memo .* does not convert anywhere near its base cost/,
    guide: {
      field: "fx_rate",
      fix: "Harga dalam mata uang asing dikali kurs jauh berbeda dari harga perolehan. Periksa kurs atau jumlahnya.",
    },
  },
];

/** The field to mark and what to do, for a refusal the database gave (its original English text), or `null`. */
export function guideAssetError(rawMessage: string | null | undefined): AssetFieldGuide | null {
  if (!rawMessage) return null;
  return GUIDES.find((entry) => entry.test.test(rawMessage))?.guide ?? null;
}

export interface OpeningFormValues {
  cost: string;
  residual: string;
  accumulated: string;
  acquisitionDate: string;
  serviceDate: string;
  cutoverDate: string;
}

/**
 * Mistakes that can be seen before saving, by field name, so the field turns red as the person types and the way
 * out is already written there. The database still checks everything.
 */
export function openingFormProblems(v: OpeningFormValues): Record<string, string> {
  const out: Record<string, string> = {};
  if (v.acquisitionDate && v.serviceDate && v.serviceDate < v.acquisitionDate) {
    out.in_service_date = "Mulai Dipakai tidak boleh sebelum Tanggal Beli.";
  }
  if (v.serviceDate && v.cutoverDate && v.cutoverDate < v.serviceDate) {
    out.cutover_date = "Tanggal Mulai Dicatat tidak boleh sebelum Mulai Dipakai.";
  }
  const cost = Number(v.cost);
  const accumulated = v.accumulated.trim() === "" ? 0 : Number(v.accumulated);
  const residual = v.residual.trim() === "" ? 0 : Number(v.residual);
  if (
    Number.isFinite(cost) &&
    cost > 0 &&
    Number.isFinite(accumulated) &&
    Number.isFinite(residual)
  ) {
    if (residual > cost) out.residual = "Nilai sisa tidak boleh lebih besar dari harga perolehan.";
    else if (accumulated > cost - residual) {
      out.accumulated =
        "Penyusutan yang sudah dicatat tidak boleh lebih besar dari harga perolehan dikurangi nilai sisa.";
    }
  }
  return out;
}

/** What is wrong with the "Baru / Bekas" and "Tahun Pembuatan" pair, in plain Indonesian, or `undefined`. */
export function originProblem(
  condition: "new" | "used",
  year: string,
  serviceDate: string,
): string | undefined {
  const trimmed = year.trim();
  if (trimmed === "") {
    return condition === "used"
      ? "Aset bekas perlu tahun pembuatannya. Isi tahunnya, atau pilih “Baru”."
      : undefined;
  }
  const n = Number(trimmed);
  if (!Number.isInteger(n) || n < 1900 || n > 2100)
    return "Tahun pembuatan harus 4 angka, mis. 2019.";
  const serviceYear = Number(serviceDate.slice(0, 4));
  if (Number.isInteger(serviceYear) && serviceYear > 0 && n > serviceYear) {
    return "Tahun pembuatan tidak boleh setelah tahun mulai dipakai.";
  }
  return undefined;
}
