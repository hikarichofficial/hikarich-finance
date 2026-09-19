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
};

export default nextConfig;
