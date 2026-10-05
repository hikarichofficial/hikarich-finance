import { readFile } from "node:fs/promises";
import path from "node:path";
import { NextResponse } from "next/server";
import { GUIDE_IMAGE_NAME } from "@/domain/guide/guides";
import { requireAccess } from "@/services/identity/access";

/**
 * Screenshots for the user guide (decision 299). They are real screenshots of the application and may
 * show real data, so they are NOT placed in `public/`: this handler serves them only to a signed-in person
 * (`requireAccess` redirects everyone else to the login), and only by plain file name -- never a path.
 */
export async function GET(_request: Request, { params }: { params: Promise<{ file: string }> }) {
  await requireAccess();
  const { file: name } = await params;
  const file = `${name}.jpg`;
  if (!GUIDE_IMAGE_NAME.test(file)) {
    return new NextResponse("Gambar tidak ditemukan.", { status: 404 });
  }
  try {
    const bytes = await readFile(
      path.join(process.cwd(), "src", "content", "guide", "images", file),
    );
    return new NextResponse(new Uint8Array(bytes), {
      headers: {
        "Content-Type": "image/jpeg",
        "Cache-Control": "private, max-age=3600",
      },
    });
  } catch {
    return new NextResponse("Gambar tidak ditemukan.", { status: 404 });
  }
}
