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
  experimental: {
    serverActions: {
      // Backup restore sends the backup file's text through a Server Action (decision 247). The browser
      // refuses files over 4 MB first (RESTORE_FILE_MAX_BYTES); Vercel's own request ceiling is 4.5 MB.
      bodySizeLimit: "5mb",
    },
  },
};

export default nextConfig;
