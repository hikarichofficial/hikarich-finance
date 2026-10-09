/**
 * Salary component presets and the automatic component code (OWNER, 9 October 2026: the form used to ask for a
 * code by hand, which nobody should have to do). Pure helpers; the server contract (`employee_set_compensation`:
 * a code of `^[a-z][a-z0-9_]{1,40}$`, a kind, a label, flags) is unchanged.
 *
 * The flag defaults follow the usual Indonesian payroll reading and are only a starting point the person can
 * change on the row: fixed allowances (jabatan, keluarga) count towards the BPJS wage base, irregular ones
 * (transport, makan, lembur, bonus) do not; every earning counts for PPh 21; a deduction such as a loan
 * repayment does NOT lower the PPh 21 base.
 */

export type ComponentKind = "earning" | "deduction";

export interface ComponentPreset {
  readonly label: string;
  readonly kind: ComponentKind;
  /**
   * For an earning: it counts towards the PPh 21 base. For a deduction: it lowers that base, which only an
   * unpaid absence does -- a loan instalment or kasbon comes off take-home pay alone (decision 381).
   */
  readonly taxable: boolean;
  readonly bpjsBase: boolean;
  /** One short line shown under the chip's name so a person can tell similar components apart. */
  readonly hint: string;
}

export const COMPONENT_PRESETS: readonly ComponentPreset[] = [
  {
    label: "Gaji Pokok",
    kind: "earning",
    taxable: true,
    bpjsBase: true,
    hint: "Gaji tetap bulanan",
  },
  {
    label: "Tunjangan Jabatan",
    kind: "earning",
    taxable: true,
    bpjsBase: true,
    hint: "Tunjangan tetap",
  },
  {
    label: "Tunjangan Keluarga",
    kind: "earning",
    taxable: true,
    bpjsBase: true,
    hint: "Tunjangan tetap",
  },
  {
    label: "Tunjangan Transport",
    kind: "earning",
    taxable: true,
    bpjsBase: false,
    hint: "Tidak tetap",
  },
  {
    label: "Tunjangan Makan",
    kind: "earning",
    taxable: true,
    bpjsBase: false,
    hint: "Tidak tetap",
  },
  {
    label: "Tunjangan Komunikasi",
    kind: "earning",
    taxable: true,
    bpjsBase: false,
    hint: "Pulsa / internet",
  },
  {
    label: "Uang Lembur",
    kind: "earning",
    taxable: true,
    bpjsBase: false,
    hint: "Rata-rata bulanan",
  },
  {
    label: "Bonus / Insentif",
    kind: "earning",
    taxable: true,
    bpjsBase: false,
    hint: "Rutin tiap bulan",
  },
  {
    label: "Tunjangan Lainnya",
    kind: "earning",
    taxable: true,
    bpjsBase: false,
    hint: "Penghasilan tambahan lain",
  },
  {
    label: "Potongan Pinjaman Karyawan",
    kind: "deduction",
    taxable: false,
    bpjsBase: false,
    hint: "Cicilan pinjaman ke perusahaan",
  },
  {
    label: "Potongan Kasbon",
    kind: "deduction",
    taxable: false,
    bpjsBase: false,
    hint: "Pengembalian kasbon",
  },
  {
    label: "Potongan Absensi",
    kind: "deduction",
    // Unpaid days really are less income, so this one does lower the PPh 21 base (decision 381).
    taxable: true,
    bpjsBase: false,
    hint: "Tidak masuk / terlambat",
  },
  {
    label: "Potongan Lainnya",
    kind: "deduction",
    taxable: false,
    bpjsBase: false,
    hint: "Potongan lain",
  },
] as const;

const MAX_CODE_LENGTH = 41;

/**
 * Lower-case, accent-free, underscore-separated code from a component name, always inside the server's
 * `^[a-z][a-z0-9_]{1,40}$`. "Tunjangan Transport" -> "tunjangan_transport". Empty text gives "" (no code yet);
 * text with no usable letters or digits gives "komponen".
 */
export function componentCode(label: string): string {
  const trimmed = label.trim();
  if (trimmed === "") return "";
  let code = trimmed
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  if (code === "") code = "komponen";
  if (!/^[a-z]/.test(code)) code = `k_${code}`;
  if (code.length < 2) code = `${code}_k`;
  code = code.slice(0, MAX_CODE_LENGTH).replace(/_+$/g, "");
  if (code.length < 2) code = `${code}_k`;
  return code;
}

/** The first free code: "bonus", then "bonus_2", "bonus_3" ... never longer than the server allows. */
export function uniqueComponentCode(base: string, taken: ReadonlySet<string>): string {
  if (base === "" || !taken.has(base)) return base;
  for (let n = 2; n < 1000; n += 1) {
    const suffix = `_${n}`;
    const candidate = `${base.slice(0, MAX_CODE_LENGTH - suffix.length).replace(/_+$/g, "")}${suffix}`;
    if (!taken.has(candidate)) return candidate;
  }
  return base;
}

/** The preset whose name equals the typed text (case and spacing ignored), or null for a free-typed name. */
export function findPreset(label: string): ComponentPreset | null {
  const wanted = label.trim().replace(/\s+/g, " ").toLowerCase();
  if (wanted === "") return null;
  return COMPONENT_PRESETS.find((preset) => preset.label.toLowerCase() === wanted) ?? null;
}
