/**
 * Guessing the category of an expense from the words of a chat message, using (1) what the owner corrected before,
 * (2) a built-in vocabulary of everyday words and (3) the words of the category names themselves. It only ever
 * suggests categories that exist in the Entity's own list; the owner confirms the guess in the roadmap. Pure.
 * Decision 422.
 */

export interface CategoryOption {
  id: string;
  name: string;
  kind: "expense" | "asset";
  isParent: boolean;
}

export interface LearnedRule {
  keyword: string;
  categoryId: string | null;
  accountId: string | null;
  payeeName: string | null;
  hits: number;
}

export type Confidence = "high" | "medium" | "low";

export interface CategorySuggestion {
  id: string;
  name: string;
  score: number;
  confidence: Confidence;
  source: "learned" | "vocabulary" | "name" | "fallback";
}

interface VocabularyGroup {
  /** Words (or short phrases) people type. */
  words: readonly string[];
  /** Pieces of category names that fit, lower case. The first category whose name holds one of them wins. */
  names: readonly string[];
}

const EXPENSE_VOCABULARY: readonly VocabularyGroup[] = [
  {
    words: [
      "makan",
      "minum",
      "kopi",
      "sarapan",
      "lunch",
      "dinner",
      "snack",
      "jajan",
      "warteg",
      "resto",
      "restoran",
      "cafe",
      "kafe",
      "bakso",
      "nasi",
      "ayam",
      "boba",
      "starbucks",
      "mcd",
      "kfc",
      "gofood",
      "grabfood",
      "shopeefood",
      "traktir",
    ],
    names: ["makan", "minum", "konsumsi"],
  },
  {
    words: ["katering", "catering", "konsumsi acara", "snack box", "nasi box"],
    names: ["katering", "konsumsi"],
  },
  {
    words: [
      "bensin",
      "pertamax",
      "pertalite",
      "solar",
      "bbm",
      "parkir",
      "tol",
      "etoll",
      "e-toll",
      "grab",
      "gojek",
      "gocar",
      "goride",
      "maxim",
      "ojol",
      "ojek",
      "taksi",
      "taxi",
      "kereta",
      "krl",
      "mrt",
      "lrt",
      "transjakarta",
      "pesawat",
      "tiket",
      "travel",
      "bandara",
    ],
    names: ["transportasi", "perjalanan"],
  },
  {
    words: [
      "iklan",
      "ads",
      "meta ads",
      "fb ads",
      "facebook ads",
      "google ads",
      "tiktok ads",
      "instagram ads",
      "boost",
      "promosi",
      "kampanye",
      "campaign",
      "sponsor",
    ],
    names: ["pemasaran", "iklan", "biaya usaha"],
  },
  {
    words: ["influencer", "endorse", "endorsement", "kol", "brand ambassador", "kontrak besar"],
    names: ["influencer", "pemasaran"],
  },
  {
    words: [
      "konten",
      "video",
      "editor",
      "thumbnail",
      "desain",
      "desainer",
      "fotografer",
      "voiceover",
      "musik",
      "footage",
    ],
    names: ["produksi konten", "biaya usaha"],
  },
  {
    words: ["royalti", "hak cipta", "copyright"],
    names: ["royalti"],
  },
  {
    words: [
      "software",
      "langganan",
      "subscription",
      "subscribe",
      "canva",
      "chatgpt",
      "claude",
      "notion",
      "figma",
      "zoom",
      "slack",
      "adobe",
      "lisensi",
      "license",
      "tradingview",
      "saas",
      "netflix",
      "spotify",
      "youtube premium",
      "icloud",
      "google workspace",
      "gsuite",
    ],
    names: ["software", "langganan"],
  },
  {
    words: [
      "hosting",
      "domain",
      "vps",
      "server",
      "cloud",
      "aws",
      "vercel",
      "supabase",
      "cloudflare",
      "godaddy",
      "niagahoster",
      "hostinger",
      "namecheap",
    ],
    names: ["hosting", "domain", "cloud", "software", "langganan"],
  },
  {
    words: [
      "pulsa",
      "paket data",
      "kuota",
      "internet",
      "wifi",
      "indihome",
      "telkomsel",
      "xl",
      "axis",
      "indosat",
      "biznet",
      "first media",
    ],
    names: ["komunikasi", "internet"],
  },
  {
    words: [
      "admin bank",
      "biaya admin",
      "biaya transfer",
      "adm bank",
      "provisi",
      "biaya bulanan rekening",
      "biaya kartu",
    ],
    names: ["biaya bank"],
  },
  {
    words: [
      "midtrans",
      "xendit",
      "doku",
      "payment gateway",
      "gateway",
      "fee pembayaran",
      "biaya pembayaran",
    ],
    names: ["payment gateway", "biaya bank"],
  },
  {
    words: [
      "ongkir",
      "ekspedisi",
      "kirim",
      "pengiriman",
      "jne",
      "jnt",
      "j&t",
      "sicepat",
      "anteraja",
      "kurir",
      "resi",
      "paxel",
    ],
    names: ["ekspedisi", "pengiriman"],
  },
  {
    words: ["gaji", "honor", "upah", "thr", "tunjangan", "lembur"],
    names: ["gaji", "tunjangan"],
  },
  {
    words: ["freelance", "freelancer", "jasa", "profesional", "talent"],
    names: ["jasa profesional", "jasa", "biaya usaha"],
  },
  {
    words: ["konsultan", "konsultasi", "mentor", "coaching"],
    names: ["konsultan", "jasa"],
  },
  {
    words: ["notaris", "akuntan", "pengacara", "legal", "hukum", "advokat"],
    names: ["hukum", "notaris"],
  },
  {
    words: ["servis", "service", "perbaikan", "maintenance", "teknisi", "tukang", "reparasi"],
    names: ["teknik", "pemeliharaan"],
  },
  {
    words: ["renovasi", "bangunan", "kontraktor", "pengecatan"],
    names: ["konstruksi", "renovasi"],
  },
  {
    words: ["cleaning", "kebersihan", "satpam", "security", "petugas"],
    names: ["kebersihan"],
  },
  {
    words: ["sewa", "kontrak tempat", "coworking", "co-working", "kos", "kost", "kontrakan"],
    names: ["sewa", "hunian"],
  },
  {
    words: [
      "atk",
      "kertas",
      "pulpen",
      "tinta",
      "map",
      "amplop",
      "isolasi",
      "stapler",
      "materai",
      "perlengkapan",
      "peralatan kecil",
    ],
    names: ["perlengkapan", "kantor"],
  },
  {
    words: ["listrik", "pln", "token listrik", "air", "pdam", "gas", "galon"],
    names: ["utilitas", "kantor", "hunian"],
  },
  {
    words: ["pajak", "pph", "ppn", "pbb", "npwp", "izin", "perizinan", "pnbp", "bpjs"],
    names: ["pajak", "perizinan"],
  },
  {
    words: ["asuransi", "premi"],
    names: ["asuransi"],
  },
  {
    words: ["dokter", "obat", "apotek", "rumah sakit", "klinik", "vitamin", "lab", "rs"],
    names: ["kesehatan"],
  },
  {
    words: [
      "kursus",
      "kelas",
      "buku",
      "seminar",
      "webinar",
      "pelatihan",
      "sekolah",
      "spp",
      "kuliah",
      "workshop",
      "bootcamp",
    ],
    names: ["pendidikan", "pengembangan"],
  },
  {
    words: [
      "hadiah",
      "kado",
      "donasi",
      "zakat",
      "sedekah",
      "infaq",
      "arisan",
      "ortu",
      "orang tua",
      "keluarga",
      "bantuan",
    ],
    names: ["keluarga", "hadiah", "bantuan"],
  },
  {
    words: [
      "belanja",
      "baju",
      "sepatu",
      "shopee",
      "tokopedia",
      "lazada",
      "fashion",
      "skincare",
      "hobi",
      "game",
      "nonton",
      "bioskop",
      "salon",
      "barbershop",
      "cukur",
    ],
    names: ["belanja", "gaya hidup"],
  },
  {
    words: [
      "indomaret",
      "alfamart",
      "supermarket",
      "minimarket",
      "sembako",
      "pasar",
      "sabun",
      "deterjen",
    ],
    names: ["kebutuhan harian", "perlengkapan", "kantor"],
  },
  {
    words: ["representasi", "jamuan", "entertain", "entertainment", "meeting klien", "makan klien"],
    names: ["representasi", "makan"],
  },
];

const ASSET_VOCABULARY: readonly VocabularyGroup[] = [
  {
    words: [
      "laptop",
      "macbook",
      "komputer",
      "pc",
      "tablet",
      "ipad",
      "notebook",
      "imac",
      "mac mini",
      "desktop",
    ],
    names: ["laptop", "komputer", "elektronik"],
  },
  {
    words: [
      "iphone",
      "hp",
      "handphone",
      "smartphone",
      "samsung",
      "android",
      "xiaomi",
      "oppo",
      "vivo",
      "pixel",
      "gadget",
      "airpods",
      "smartwatch",
    ],
    names: ["smartphone", "gadget", "elektronik"],
  },
  {
    words: ["printer", "scanner", "monitor", "keyboard", "mouse", "webcam", "headset", "periferal"],
    names: ["printer", "periferal", "elektronik"],
  },
  {
    words: [
      "kamera",
      "lensa",
      "mic",
      "mikrofon",
      "tripod",
      "lighting",
      "lampu studio",
      "studio",
      "gimbal",
      "drone",
    ],
    names: ["kamera", "studio", "elektronik"],
  },
  {
    words: ["server", "harddisk", "hdd", "ssd", "nas", "penyimpanan"],
    names: ["server", "penyimpanan", "elektronik"],
  },
  {
    words: ["router", "cctv", "telepon", "access point"],
    names: ["telepon", "router", "cctv", "elektronik"],
  },
  { words: ["mesin", "produksi", "cetak"], names: ["mesin", "produksi"] },
  {
    words: ["ac", "genset", "kulkas", "dispenser", "stabilizer"],
    names: ["ac", "genset", "listrik", "perabot"],
  },
  {
    words: ["meja", "kursi", "lemari", "furnitur", "furniture", "sofa", "rak", "kasur"],
    names: ["furnitur", "meja", "perabot"],
  },
  { words: ["mobil", "avanza", "innova", "brio", "xpander"], names: ["mobil", "kendaraan"] },
  { words: ["motor", "vario", "beat", "nmax", "pcx", "scoopy"], names: ["motor", "kendaraan"] },
  { words: ["tanah", "kavling"], names: ["tanah", "properti"] },
  { words: ["ruko", "rumah", "gedung", "bangunan"], names: ["bangunan", "properti"] },
];

const STOPWORDS = new Set([
  "bayar",
  "beli",
  "untuk",
  "tadi",
  "dan",
  "yang",
  "biaya",
  "buat",
  "ke",
  "di",
  "dari",
  "pakai",
  "pake",
  "via",
  "saya",
  "aku",
  "gue",
  "gw",
  "sudah",
  "udah",
  "lagi",
  "sama",
  "dengan",
  "sebesar",
  "senilai",
  "total",
  "rp",
  "pt",
  "pribadi",
  "kemarin",
  "hari",
  "ini",
  "sekitar",
  "ya",
  "nih",
  "dong",
  "tolong",
  "catat",
  "pengeluaran",
]);

/** Lower case, accents and punctuation gone, single spaces. */
export function normalizeText(text: string): string {
  return text
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9&+\s-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function tokens(text: string): string[] {
  return normalizeText(text)
    .split(/[\s&+-]+/)
    .filter((t) => t.length > 0);
}

/** A single word must be a whole token; a phrase must appear as a run of tokens. */
export function containsWord(text: string, word: string): boolean {
  const haystack = ` ${normalizeText(text).replace(/[&+-]/g, " ").replace(/\s+/g, " ")} `;
  const needle = normalizeText(word).replace(/[&+-]/g, " ").replace(/\s+/g, " ");
  return needle.length > 0 && haystack.includes(` ${needle} `);
}

function nameHas(name: string, piece: string): boolean {
  return normalizeText(name).includes(piece);
}

/**
 * The word that identifies a purchase for later (a merchant or the item): the payee when there is one, else the
 * first word of the description that says something.
 */
export function learningKeyword(
  description: string,
  payee: string | null | undefined,
): string | null {
  const p = payee ? normalizeText(payee) : "";
  if (p.length >= 2 && p.length <= 80) return p;
  for (const t of tokens(description)) {
    if (t.length >= 3 && !STOPWORDS.has(t) && !/^\d+$/.test(t)) return t;
  }
  return null;
}

function confidenceFor(source: CategorySuggestion["source"]): Confidence {
  if (source === "learned") return "high";
  if (source === "fallback") return "low";
  return "medium";
}

/**
 * Suggestions for one line, best first. Parent categories rank below their children; a "...Lainnya" category is
 * offered last as a low-confidence fallback so the owner always has something to confirm or change.
 */
export function suggestCategories(
  text: string,
  kind: "expense" | "asset",
  categories: readonly CategoryOption[],
  rules: readonly LearnedRule[],
): CategorySuggestion[] {
  const pool = categories.filter((c) => c.kind === kind);
  const scores = new Map<string, { score: number; source: CategorySuggestion["source"] }>();
  const bump = (id: string, score: number, source: CategorySuggestion["source"]) => {
    const current = scores.get(id);
    if (!current || score > current.score) scores.set(id, { score, source });
  };

  for (const rule of rules) {
    if (!rule.categoryId || !containsWord(text, rule.keyword)) continue;
    const category = pool.find((c) => c.id === rule.categoryId);
    if (category) bump(category.id, 100 + Math.min(rule.hits, 20), "learned");
  }

  const vocabulary = kind === "asset" ? ASSET_VOCABULARY : EXPENSE_VOCABULARY;
  for (const group of vocabulary) {
    const hits = group.words.filter((w) => containsWord(text, w)).length;
    if (hits === 0) continue;
    for (const piece of group.names) {
      const category =
        pool.find((c) => !c.isParent && nameHas(c.name, piece)) ??
        pool.find((c) => nameHas(c.name, piece));
      if (category) {
        // The earlier pieces of a group fit better than the later ones.
        const rank = group.names.indexOf(piece);
        bump(category.id, 60 + Math.min(hits - 1, 3) * 5 - rank * 3, "vocabulary");
        break;
      }
    }
  }

  const textTokens = new Set(tokens(text).filter((t) => t.length >= 4 && !STOPWORDS.has(t)));
  for (const category of pool) {
    const overlap = tokens(category.name).filter((t) => t.length >= 4 && textTokens.has(t)).length;
    if (overlap > 0) bump(category.id, 40 + overlap * 5, "name");
  }

  const result: CategorySuggestion[] = [];
  for (const category of pool) {
    const hit = scores.get(category.id);
    if (!hit) continue;
    result.push({
      id: category.id,
      name: category.name,
      score: hit.score - (category.isParent ? 10 : 0),
      confidence: confidenceFor(hit.source),
      source: hit.source,
    });
  }
  result.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));

  if (result.length === 0) {
    const fallback = pool.find((c) => !c.isParent && nameHas(c.name, "lainnya"));
    if (fallback) {
      result.push({
        id: fallback.id,
        name: fallback.name,
        score: 5,
        confidence: "low",
        source: "fallback",
      });
    }
  }
  return result;
}

/** True when the words describe a durable item (laptop, phone, vehicle...) that may belong in fixed assets. */
export function looksLikeAsset(text: string): boolean {
  return ASSET_VOCABULARY.some((group) => group.words.some((w) => containsWord(text, w)));
}

/** Purchases below this are not offered as assets unless the owner asks (the owner decides in the roadmap). */
export const ASSET_QUESTION_THRESHOLD = 1_000_000;

/** All categories of a kind for a picker: suggestions first, then the rest by name. */
export function orderForPicker(
  categories: readonly CategoryOption[],
  kind: "expense" | "asset",
  suggestions: readonly CategorySuggestion[],
): CategoryOption[] {
  const pool = categories.filter((c) => c.kind === kind);
  const first = suggestions
    .map((s) => pool.find((c) => c.id === s.id))
    .filter((c): c is CategoryOption => Boolean(c));
  const seen = new Set(first.map((c) => c.id));
  const rest = pool.filter((c) => !seen.has(c.id)).sort((a, b) => a.name.localeCompare(b.name));
  return [...first, ...rest];
}

/** Picks the category whose name best matches words the owner typed ("transport", "ganti makan"). */
export function matchCategoryByName(
  typed: string,
  categories: readonly CategoryOption[],
  kind: "expense" | "asset",
): CategoryOption | null {
  const want = normalizeText(typed);
  if (want.length < 3) return null;
  const pool = categories.filter((c) => c.kind === kind);
  const exact = pool.find((c) => normalizeText(c.name) === want);
  if (exact) return exact;
  const wantTokens = tokens(want).filter((t) => t.length >= 3);
  let best: { category: CategoryOption; score: number } | null = null;
  for (const category of pool) {
    const nameNorm = normalizeText(category.name);
    let score = 0;
    for (const t of wantTokens) if (nameNorm.includes(t)) score += t.length;
    if (nameNorm.includes(want)) score += 10;
    if (category.isParent) score -= 1;
    if (score > 0 && (!best || score > best.score)) best = { category, score };
  }
  return best?.category ?? null;
}
