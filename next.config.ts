import type { NextConfig } from "next";
import { parseServerEnv } from "./src/lib/env";

// Fail safely at dev start / build when critical configuration is missing or
// unsafe (Step 14 §15). Set SKIP_ENV_VALIDATION=1 only for tooling that cannot
// supply environment values (never for deployments).
if (process.env.SKIP_ENV_VALIDATION !== "1") {
  parseServerEnv(process.env);
}

const nextConfig: NextConfig = {
  poweredByHeader: false,
  reactStrictMode: true,
  // The guide screenshots are read from disk by an auth-checked route handler (decision 299), so the
  // serverless bundle of that route must carry them.
  outputFileTracingIncludes: {
    "/guide/image/[file]": ["./src/content/guide/images/**/*"],
    "/guide/diagram/[id]": ["./src/content/guide/diagrams/**/*"],
  },
  experimental: {
    // Back/forward and repeat visits reuse the page the browser already has for a short time instead of asking
    // the server again (OWNER, 7 October 2026: going back to a menu felt slow). Saving anything (a Server Action
    // that revalidates) clears this cache, so a page never shows data older than the person's own changes.
    staleTimes: { dynamic: 120, static: 300 },
    serverActions: {
      // Backup restore sends the backup file's text through a Server Action (decision 247). The browser
      // refuses files over 4 MB first (RESTORE_FILE_MAX_BYTES); Vercel's own request ceiling is 4.5 MB.
      bodySizeLimit: "5mb",
    },
  },
};

export default nextConfig;
