import { describe, expect, it } from "vitest";
import {
  COMPONENT_PRESETS,
  componentCode,
  findPreset,
  uniqueComponentCode,
} from "./compensationPresets";

const SERVER_CODE = /^[a-z][a-z0-9_]{1,40}$/;

describe("componentCode", () => {
  it("turns a name into a lower-case underscore code", () => {
    expect(componentCode("Tunjangan Transport")).toBe("tunjangan_transport");
    expect(componentCode("  Bonus / Insentif ")).toBe("bonus_insentif");
    expect(componentCode("Potongan Pinjaman Karyawan")).toBe("potongan_pinjaman_karyawan");
  });

  it("drops accents and symbols", () => {
    expect(componentCode("Tunjangan Kesehatan (Ékstra)")).toBe("tunjangan_kesehatan_ekstra");
  });

  it("gives no code for empty text and a safe code for text without letters", () => {
    expect(componentCode("   ")).toBe("");
    expect(componentCode("!!!")).toBe("komponen");
  });

  it("never starts with a digit and is never shorter than two characters", () => {
    expect(componentCode("13th Salary")).toBe("k_13th_salary");
    expect(componentCode("7")).toBe("k_7");
    expect(componentCode("a")).toBe("a_k");
  });

  it("stays inside the server's pattern and length, whatever is typed", () => {
    const long = componentCode("Tunjangan ".repeat(20));
    expect(long.length).toBeLessThanOrEqual(41);
    expect(long).toMatch(SERVER_CODE);
    for (const preset of COMPONENT_PRESETS) {
      expect(componentCode(preset.label)).toMatch(SERVER_CODE);
    }
  });

  it("gives every preset its own code", () => {
    const codes = COMPONENT_PRESETS.map((preset) => componentCode(preset.label));
    expect(new Set(codes).size).toBe(codes.length);
  });
});

describe("uniqueComponentCode", () => {
  it("keeps a free code and numbers a taken one", () => {
    expect(uniqueComponentCode("bonus", new Set())).toBe("bonus");
    expect(uniqueComponentCode("bonus", new Set(["bonus"]))).toBe("bonus_2");
    expect(uniqueComponentCode("bonus", new Set(["bonus", "bonus_2"]))).toBe("bonus_3");
  });

  it("keeps a numbered long code inside the server length", () => {
    const base = componentCode("Tunjangan ".repeat(20));
    const next = uniqueComponentCode(base, new Set([base]));
    expect(next.length).toBeLessThanOrEqual(41);
    expect(next).toMatch(SERVER_CODE);
    expect(next).not.toBe(base);
  });

  it("leaves an empty code alone", () => {
    expect(uniqueComponentCode("", new Set(["x"]))).toBe("");
  });
});

describe("findPreset", () => {
  it("matches a preset name ignoring case and spacing", () => {
    expect(findPreset("gaji  pokok")?.bpjsBase).toBe(true);
    expect(findPreset("TUNJANGAN TRANSPORT")?.bpjsBase).toBe(false);
  });

  it("returns null for a free-typed or empty name", () => {
    expect(findPreset("Tunjangan Sepeda")).toBeNull();
    expect(findPreset("")).toBeNull();
  });

  it("keeps deductions out of the PPh 21 base and the BPJS base", () => {
    for (const preset of COMPONENT_PRESETS.filter((p) => p.kind === "deduction")) {
      expect(preset.taxable).toBe(false);
      expect(preset.bpjsBase).toBe(false);
    }
  });
});
