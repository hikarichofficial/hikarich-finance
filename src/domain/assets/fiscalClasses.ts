/**
 * The fiscal depreciation groups (UU PPh Pasal 11, PMK 72/2023), as the rule master `FISCAL_DEP_CLASSES`
 * holds them. This is display and form help only: it suggests the useful life and shows the yearly rate;
 * the database validates the key and computes every plan itself.
 */
export interface FiscalClass {
  key: string;
  label: string;
  /** Everyday examples, so the person can pick a group without knowing the regulation. */
  examples: string;
  /** Useful life in months; `null` for land, which is not depreciated. */
  lifeMonths: number | null;
  /** Yearly rate as a percentage, straight line. */
  straightLineRate: number | null;
  /** Yearly rate as a percentage, declining balance; buildings may only use straight line. */
  decliningBalanceRate: number | null;
}

export const FISCAL_CLASSES: readonly FiscalClass[] = [
  {
    key: "group_1",
    label: "Kelompok 1 (4 tahun)",
    examples: "komputer, laptop, printer, mebel kayu, alat kantor, sepeda motor",
    lifeMonths: 48,
    straightLineRate: 25,
    decliningBalanceRate: 50,
  },
  {
    key: "group_2",
    label: "Kelompok 2 (8 tahun)",
    examples: "mebel logam, AC, mobil, truk ringan",
    lifeMonths: 96,
    straightLineRate: 12.5,
    decliningBalanceRate: 25,
  },
  {
    key: "group_3",
    label: "Kelompok 3 (16 tahun)",
    examples: "mesin produksi tertentu",
    lifeMonths: 192,
    straightLineRate: 6.25,
    decliningBalanceRate: 12.5,
  },
  {
    key: "group_4",
    label: "Kelompok 4 (20 tahun)",
    examples: "alat berat konstruksi",
    lifeMonths: 240,
    straightLineRate: 5,
    decliningBalanceRate: 10,
  },
  {
    key: "building_permanent",
    label: "Bangunan permanen (20 tahun)",
    examples: "gedung, ruko",
    lifeMonths: 240,
    straightLineRate: 5,
    decliningBalanceRate: null,
  },
  {
    key: "building_non_permanent",
    label: "Bangunan tidak permanen (10 tahun)",
    examples: "bangunan sementara",
    lifeMonths: 120,
    straightLineRate: 10,
    decliningBalanceRate: null,
  },
  {
    key: "land",
    label: "Tanah (tidak disusutkan)",
    examples: "tanah",
    lifeMonths: null,
    straightLineRate: null,
    decliningBalanceRate: null,
  },
];

export function findFiscalClass(key: string | null | undefined): FiscalClass | null {
  return FISCAL_CLASSES.find((item) => item.key === key) ?? null;
}

export function fiscalClassLabel(key: string | null | undefined): string {
  return findFiscalClass(key)?.label ?? key ?? "—";
}

/**
 * Straight-line depreciation per month, for the hint under the form: (cost − residual) ÷ months. Returns
 * `null` when the inputs are not usable numbers. A hint only -- the posted plan is the database's.
 */
export function monthlyStraightLine(cost: string, residual: string, months: string): number | null {
  const c = Number(cost);
  const r = residual.trim() === "" ? 0 : Number(residual);
  const m = Number(months);
  if (!Number.isFinite(c) || !Number.isFinite(r) || !Number.isInteger(m) || m <= 0) return null;
  if (c <= 0 || r < 0 || r > c) return null;
  return (c - r) / m;
}

/**
 * Words in an asset's name that point at a fiscal group, so the person does not have to know the
 * regulation. Checked in order; the first rule with a matching word wins, which is why the more specific
 * words (a metal cabinet, a building) come before the general ones (a cabinet). A suggestion only: the
 * form shows it and the person can change it.
 */
const NAME_RULES: readonly { key: string; words: readonly string[] }[] = [
  { key: "land", words: ["tanah", "lahan", "kavling"] },
  {
    key: "building_non_permanent",
    words: ["bangunan sementara", "tidak permanen", "non permanen", "semi permanen", "bedeng"],
  },
  {
    key: "building_permanent",
    words: ["gedung", "bangunan", "ruko", "rukan", "kios"],
  },
  {
    key: "group_2",
    words: [
      "mobil",
      "truk",
      "pickup",
      "pick up",
      "bus",
      "minibus",
      "ac ",
      "air conditioner",
      "pendingin",
      "kipas",
      "besi",
      "logam",
      "baja",
      "stainless",
      "aluminium",
      "brankas",
      "filing cabinet",
      "genset",
      "generator",
      "kulkas",
      "lemari es",
    ],
  },
  {
    key: "group_1",
    words: [
      "komputer",
      "computer",
      "pc ",
      "laptop",
      "tablet",
      "ipad",
      "iphone",
      "smartphone",
      "handphone",
      "hp",
      "ponsel",
      "telepon",
      "notebook",
      "macbook",
      "imac",
      "monitor",
      "printer",
      "scanner",
      "pemindai",
      "fotokopi",
      "proyektor",
      "projector",
      "server",
      "router",
      "modem",
      "ups",
      "kamera",
      "camera",
      "televisi",
      "tv ",
      "speaker",
      "mesin kasir",
      "mesin hitung",
      "mesin tik",
      "kalkulator",
      "meja",
      "kursi",
      "lemari",
      "rak",
      "sofa",
      "kayu",
      "rotan",
      "motor",
      "sepeda",
      "dispenser",
      "kompor",
    ],
  },
];

/**
 * The fiscal group an asset's name suggests, or `null` when no word is recognised (the person then
 * chooses). Matching is on whole words of the lower-cased name, so "motor" does not match "promotor".
 */
export function suggestFiscalClass(name: string): FiscalClass | null {
  const text = ` ${name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim()} `;
  if (text.trim() === "") return null;
  for (const rule of NAME_RULES) {
    for (const word of rule.words) {
      if (text.includes(` ${word.trim()} `)) return findFiscalClass(rule.key);
    }
  }
  return null;
}

/** The last day of the month before `today` (`YYYY-MM-DD`), the cut-off automatic posting uses. */
export function previousMonthEnd(today: string): string {
  const [year, month] = today.split("-").map(Number);
  const end = new Date(Date.UTC(year ?? 1970, (month ?? 1) - 1, 0));
  return end.toISOString().slice(0, 10);
}
