/** Plain module (no "use client") so server pages can read the labels; see categories/kindLabels.ts. */
export const MARKETPLACE_PLATFORM_LABELS: Readonly<Record<string, string>> = {
  shopee: "Shopee",
  tokopedia: "Tokopedia",
  lazada: "Lazada",
  blibli: "Blibli",
  tiktok_shop: "TikTok Shop",
  bukalapak: "Bukalapak",
  other: "Lainnya",
};
