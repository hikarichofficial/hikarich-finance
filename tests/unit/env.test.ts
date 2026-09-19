import { describe, expect, it } from "vitest";
import { EnvironmentConfigError, parsePublicEnv, parseServerEnv } from "@/lib/env";
import { PRODUCTION_SUPABASE_PROJECT_REF } from "@/lib/env/constants";
import { evaluateEnvironmentGuard, supabaseProjectRef } from "@/lib/env/guard";

const KEY = "sb_publishable_placeholder_0000000000";

const devEnv = {
  APP_ENV: "development",
  APP_URL: "http://localhost:3000",
  NEXT_PUBLIC_SUPABASE_URL: "https://akdrofeisjiofndxnhkt.supabase.co",
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: KEY,
};

const prodEnv = {
  APP_ENV: "production",
  APP_URL: "https://finance.hikarich.com",
  NEXT_PUBLIC_SUPABASE_URL: `https://${PRODUCTION_SUPABASE_PROJECT_REF}.supabase.co`,
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: KEY,
};

describe("environment contract (Step 14 §15)", () => {
  it("accepts a valid development configuration", () => {
    const env = parseServerEnv(devEnv);
    expect(env.APP_ENV).toBe("development");
    expect(env.SUPABASE_SERVICE_ROLE_KEY).toBeUndefined();
  });

  it("accepts a valid production configuration", () => {
    expect(parseServerEnv(prodEnv).APP_ENV).toBe("production");
  });

  it("fails safely when required variables are missing", () => {
    expect(() => parseServerEnv({})).toThrow(EnvironmentConfigError);
  });

  it("reports variable names, never values", () => {
    try {
      parseServerEnv({ ...devEnv, APP_URL: "not-a-url-SECRETVALUE" });
      expect.unreachable();
    } catch (error) {
      expect(error).toBeInstanceOf(EnvironmentConfigError);
      expect((error as Error).message).toContain("APP_URL");
      expect((error as Error).message).not.toContain("SECRETVALUE");
    }
  });

  it("rejects an unknown APP_ENV", () => {
    expect(() => parseServerEnv({ ...devEnv, APP_ENV: "staging" })).toThrow(EnvironmentConfigError);
  });

  it("parses the browser-safe subset without server variables", () => {
    const env = parsePublicEnv({
      NEXT_PUBLIC_SUPABASE_URL: devEnv.NEXT_PUBLIC_SUPABASE_URL,
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: KEY,
    });
    expect(Object.keys(env).sort()).toEqual([
      "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
      "NEXT_PUBLIC_SUPABASE_URL",
    ]);
  });
});

describe("Preview / Development must never reach Production data (Step 14 §3, §18)", () => {
  it.each(["development", "preview"] as const)(
    "rejects APP_ENV=%s pointing at the production Supabase project",
    (appEnv) => {
      expect(() =>
        parseServerEnv({ ...prodEnv, APP_ENV: appEnv, APP_URL: "http://localhost:3000" }),
      ).toThrow(/must not use the production Supabase project/);
    },
  );

  it("rejects APP_ENV=production pointing at a non-production project", () => {
    expect(() =>
      parseServerEnv({ ...prodEnv, NEXT_PUBLIC_SUPABASE_URL: devEnv.NEXT_PUBLIC_SUPABASE_URL }),
    ).toThrow(/must use the production Supabase project/);
  });

  it("rejects a Vercel preview build that claims to be production", () => {
    expect(() => parseServerEnv({ ...prodEnv, VERCEL_ENV: "preview" })).toThrow(
      /does not match APP_ENV/,
    );
  });

  it("allows a local Supabase stack for development", () => {
    const env = parseServerEnv({ ...devEnv, NEXT_PUBLIC_SUPABASE_URL: "http://127.0.0.1:54321" });
    expect(env.APP_ENV).toBe("development");
  });

  it("does not treat lookalike hosts as the production project", () => {
    expect(
      supabaseProjectRef(`https://${PRODUCTION_SUPABASE_PROJECT_REF}.supabase.co.evil.test`),
    ).toBeNull();
    expect(supabaseProjectRef("not a url")).toBeNull();
  });
});

describe("secret exposure guard (Step 14 §14)", () => {
  it("flags service-role style secrets exposed via NEXT_PUBLIC_ names", () => {
    const violations = evaluateEnvironmentGuard({
      appEnv: "development",
      supabaseUrl: devEnv.NEXT_PUBLIC_SUPABASE_URL,
      publicVariableNames: ["NEXT_PUBLIC_SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY"],
    });
    expect(violations).toHaveLength(1);
    expect(violations[0]).toContain("NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY");
  });

  it("passes the normal public variable names", () => {
    expect(
      evaluateEnvironmentGuard({
        appEnv: "development",
        supabaseUrl: devEnv.NEXT_PUBLIC_SUPABASE_URL,
        publicVariableNames: ["NEXT_PUBLIC_SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"],
      }),
    ).toEqual([]);
  });
});
