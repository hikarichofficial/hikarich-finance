import { readFile } from "node:fs/promises";
import path from "node:path";
import { NextResponse } from "next/server";
import { FLOW_ID } from "@/domain/guide/flows";
import { requireAccess } from "@/services/identity/access";

/**
 * Flow diagrams of the user guide (decision 300), drawn as SVG files. They are served only to a signed-in
 * person (`requireAccess`), and only by plain id -- never a path -- the same way the guide screenshots are.
 */
export async function GET(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  await requireAccess();
  const { id } = await params;
  if (!FLOW_ID.test(id)) {
    return new NextResponse("Diagram tidak ditemukan.", { status: 404 });
  }
  try {
    const bytes = await readFile(
      path.join(process.cwd(), "src", "content", "guide", "diagrams", `${id}.svg`),
    );
    return new NextResponse(new Uint8Array(bytes), {
      headers: {
        "Content-Type": "image/svg+xml; charset=utf-8",
        "Cache-Control": "private, max-age=3600",
        // An SVG opened directly could carry script; these files are ours, but the header keeps it inert.
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch {
    return new NextResponse("Diagram tidak ditemukan.", { status: 404 });
  }
}
