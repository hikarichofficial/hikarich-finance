import { describe, expect, it } from "vitest";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { needsStepUp } from "./stepUpState";

describe("needsStepUp", () => {
  it("opens the popup for the flag and for the database's re-verification copy", () => {
    expect(needsStepUp({ status: "error", message: "apa saja", stepUp: true })).toBe(true);
    const copy = describeAuthzError(new AuthzError("STEP_UP_REQUIRED"));
    expect(needsStepUp({ status: "error", message: copy })).toBe(true);
  });

  it("stays quiet for ordinary results and errors", () => {
    expect(needsStepUp({ status: "ok", message: "Tersimpan." })).toBe(false);
    expect(needsStepUp({ status: "error", message: "Anda tidak memiliki izin." })).toBe(false);
    expect(needsStepUp({ status: "idle" })).toBe(false);
    expect(needsStepUp(null)).toBe(false);
    expect(needsStepUp({ error: "Kode tidak sesuai." })).toBe(false);
  });
});
