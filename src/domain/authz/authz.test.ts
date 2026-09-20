import { describe, expect, it } from "vitest";
import {
  assertCan,
  assertRecentStepUp,
  can,
  entityLabel,
  findMembership,
  membershipsNeedingMfa,
  resolveActiveEntity,
  safeNextPath,
} from "./access";
import { AuthzError, authzErrorMessage, parseAuthzCode } from "./errors";
import { isAal2, isRecentStepUp, latestAuthTimestamp, STEP_UP_WINDOW_MINUTES } from "./stepUp";
import { accessSnapshotSchema, loginInputSchema, otpCodeSchema } from "@/schemas/access";

const PT = "11111111-1111-4111-8111-111111111111";
const PERSONAL = "22222222-2222-4222-8222-222222222222";
const USER = "33333333-3333-4333-8333-333333333333";

function snapshot(overrides: Record<string, unknown> = {}) {
  return accessSnapshotSchema.parse({
    user_id: USER,
    active: true,
    display_name: "Demo",
    aal: "aal2",
    recent_step_up: true,
    memberships: [
      {
        membership_id: "44444444-4444-4444-8444-444444444444",
        entity_id: PT,
        entity_code: "demo_pt",
        entity_type: "company",
        entity_name: "Demo PT",
        role_key: "owner",
        mfa_required: true,
        mfa_satisfied: true,
        permissions: ["ledger.read", "ledger.post"],
      },
      {
        membership_id: "55555555-5555-4555-8555-555555555555",
        entity_id: PERSONAL,
        entity_code: "demo_personal",
        entity_type: "personal",
        entity_name: "Demo Personal",
        role_key: "staff",
        mfa_required: false,
        mfa_satisfied: false,
        permissions: ["ledger.read"],
      },
    ],
    ...overrides,
  });
}

describe("step-up window", () => {
  const now = Date.UTC(2026, 8, 20, 12, 0, 0);
  const at = (minutesAgo: number) => Math.floor(now / 1000) - minutesAgo * 60;

  it("uses the newest amr timestamp", () => {
    expect(latestAuthTimestamp([{ timestamp: 10 }, { timestamp: 30 }, { timestamp: 20 }])).toBe(30);
    expect(latestAuthTimestamp(undefined)).toBeNull();
    expect(latestAuthTimestamp("nope")).toBeNull();
    expect(latestAuthTimestamp([{ method: "password" }])).toBeNull();
  });

  it("accepts a login inside the 10-minute window and rejects an older one", () => {
    expect(STEP_UP_WINDOW_MINUTES).toBe(10);
    expect(isRecentStepUp({ amr: [{ timestamp: at(9) }] }, now)).toBe(true);
    expect(isRecentStepUp({ amr: [{ timestamp: at(11) }] }, now)).toBe(false);
    expect(isRecentStepUp({ amr: [{ timestamp: at(30) }, { timestamp: at(2) }] }, now)).toBe(true);
  });

  it("does not trust missing or far-future timestamps", () => {
    expect(isRecentStepUp({}, now)).toBe(false);
    expect(isRecentStepUp({ amr: [{ timestamp: at(-30) }] }, now)).toBe(false);
  });

  it("detects aal2", () => {
    expect(isAal2({ aal: "aal2" })).toBe(true);
    expect(isAal2({ aal: "aal1" })).toBe(false);
  });
});

describe("authorization errors", () => {
  it("maps database message prefixes to codes", () => {
    expect(parseAuthzCode("FORBIDDEN: no permission")).toBe("FORBIDDEN");
    expect(parseAuthzCode("STEP_UP_REQUIRED")).toBe("STEP_UP_REQUIRED");
    expect(parseAuthzCode("LAST_OWNER: cannot remove")).toBe("LAST_OWNER");
    expect(parseAuthzCode("relation does not exist")).toBeNull();
    expect(parseAuthzCode("FORBIDDENISH")).toBeNull();
    expect(parseAuthzCode(null)).toBeNull();
  });

  it("gives generic copy without database detail", () => {
    expect(authzErrorMessage("FORBIDDEN")).not.toMatch(/sql|policy|relation/i);
  });
});

describe("access helpers", () => {
  it("keeps PT and Personal separate", () => {
    const access = snapshot();
    expect(can(access, PT, "ledger.post")).toBe(true);
    expect(can(access, PERSONAL, "ledger.post")).toBe(false);
    expect(can(access, "99999999-9999-4999-8999-999999999999", "ledger.read")).toBe(false);
    expect(findMembership(access, PERSONAL)?.role_key).toBe("staff");
  });

  it("gives an inactive user no capabilities at all", () => {
    const access = snapshot({ active: false });
    expect(can(access, PT, "ledger.read")).toBe(false);
    expect(resolveActiveEntity(access)).toBeNull();
  });

  it("assertCan throws FORBIDDEN", () => {
    const access = snapshot();
    expect(() => assertCan(access, PERSONAL, "ledger.post")).toThrow(AuthzError);
    expect(() => assertCan(access, PT, "ledger.post")).not.toThrow();
  });

  it("assertRecentStepUp throws STEP_UP_REQUIRED", () => {
    expect(() => assertRecentStepUp(snapshot({ recent_step_up: false }))).toThrow(AuthzError);
    expect(() => assertRecentStepUp(snapshot())).not.toThrow();
  });

  it("flags memberships whose MFA requirement is unmet", () => {
    const access = snapshot();
    access.memberships[0]!.mfa_satisfied = false;
    expect(membershipsNeedingMfa(access).map((m) => m.entity_id)).toEqual([PT]);
  });

  it("resolves the requested Entity only when usable, else the first usable one", () => {
    const access = snapshot();
    expect(resolveActiveEntity(access, "demo_personal")?.entity_id).toBe(PERSONAL);
    expect(resolveActiveEntity(access, "unknown")?.entity_id).toBe(PT);
    access.memberships[0]!.mfa_satisfied = false;
    expect(resolveActiveEntity(access, "demo_pt")?.entity_id).toBe(PERSONAL);
  });
});

describe("entityLabel", () => {
  it("labels company, personal and other Entities", () => {
    expect(entityLabel({ entity_type: "company", entity_name: "X" })).toBe("PT");
    expect(entityLabel({ entity_type: "personal", entity_name: "X" })).toBe("Personal");
    expect(entityLabel({ entity_type: "other", entity_name: "Foundation" })).toBe("Foundation");
  });
});

describe("safeNextPath", () => {
  it("accepts same-site relative paths", () => {
    expect(safeNextPath("/reports?x=1")).toBe("/reports?x=1");
    expect(safeNextPath("/")).toBe("/");
  });

  it("rejects open-redirect attempts", () => {
    for (const bad of [
      "//evil.example",
      "https://evil.example",
      "/\\evil.example",
      "javascript:alert(1)",
      "/ok path",
      "",
      undefined,
      null,
      42,
    ]) {
      expect(safeNextPath(bad, "/fallback")).toBe("/fallback");
    }
  });
});

describe("input schemas", () => {
  it("normalises and validates login input", () => {
    expect(loginInputSchema.parse({ email: "  A@Example.com ", password: "x" }).email).toBe(
      "a@example.com",
    );
    expect(loginInputSchema.safeParse({ email: "not-an-email", password: "x" }).success).toBe(
      false,
    );
    expect(loginInputSchema.safeParse({ email: "a@example.com", password: "" }).success).toBe(
      false,
    );
  });

  it("requires exactly six digits for OTP", () => {
    expect(otpCodeSchema.safeParse("123456").success).toBe(true);
    expect(otpCodeSchema.safeParse(" 123456 ").success).toBe(true);
    for (const bad of ["12345", "1234567", "abcdef", "12 456"]) {
      expect(otpCodeSchema.safeParse(bad).success).toBe(false);
    }
  });

  it("rejects malformed access snapshots", () => {
    expect(accessSnapshotSchema.safeParse({ user_id: "x" }).success).toBe(false);
  });
});
