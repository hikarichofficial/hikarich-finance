import type { MetadataRoute } from "next";

/**
 * "Add to Home Screen" support (decision 421): Android (Chrome) and iPhone/iPad (Safari) open the site as a
 * full-screen app with its own icon. This only describes the app; there is deliberately no service worker,
 * so nothing from the finance data is ever stored on the device by the app itself.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "Hikarich Finance",
    short_name: "Hikarich",
    description: "Sistem keuangan PT Hikarich Kitana Digital dan Personal Entity.",
    lang: "id",
    start_url: "/",
    scope: "/",
    display: "standalone",
    background_color: "#f7f2ec",
    theme_color: "#f7f2ec",
    icons: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any" },
      {
        src: "/icons/icon-maskable-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "maskable",
      },
    ],
  };
}
