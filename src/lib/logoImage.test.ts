import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { LOGO_MAX_UPLOAD_BYTES, LogoImageError, compressLogo } from "./logoImage";

async function noisyPng(width: number, height: number): Promise<Buffer> {
  const raw = Buffer.alloc(width * height * 3);
  for (let i = 0; i < raw.length; i += 1) raw[i] = (i * 2654435761) % 251;
  return sharp(raw, { raw: { width, height, channels: 3 } })
    .png({ compressionLevel: 0 })
    .toBuffer();
}

describe("compressLogo", () => {
  it("shrinks a large picture to a small WebP that fits 600x240", async () => {
    const original = await noisyPng(1200, 600);
    expect(original.length).toBeGreaterThan(1_000_000);
    const result = await compressLogo(original);
    expect(result.dataUrl.startsWith("data:image/webp;base64,")).toBe(true);
    expect(result.width).toBeLessThanOrEqual(600);
    expect(result.height).toBeLessThanOrEqual(240);
    expect(result.bytes).toBeLessThanOrEqual(60_000);
    expect(result.dataUrl.length).toBeLessThan(400_000);
  });

  it("never enlarges a small logo and keeps transparency", async () => {
    const original = await sharp({
      create: {
        width: 120,
        height: 60,
        channels: 4,
        background: { r: 10, g: 20, b: 30, alpha: 0 },
      },
    })
      .png()
      .toBuffer();
    const result = await compressLogo(original);
    expect(result.width).toBe(120);
    expect(result.height).toBe(60);
    const decoded = await sharp(Buffer.from(result.dataUrl.split(",")[1]!, "base64")).metadata();
    expect(decoded.hasAlpha).toBe(true);
  });

  it("refuses an SVG, plain text and an empty or oversized file", async () => {
    const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>');
    await expect(compressLogo(svg)).rejects.toBeInstanceOf(LogoImageError);
    await expect(compressLogo(Buffer.from("bukan gambar"))).rejects.toBeInstanceOf(LogoImageError);
    await expect(compressLogo(Buffer.alloc(0))).rejects.toBeInstanceOf(LogoImageError);
    await expect(compressLogo(Buffer.alloc(LOGO_MAX_UPLOAD_BYTES + 1))).rejects.toBeInstanceOf(
      LogoImageError,
    );
  });
});
