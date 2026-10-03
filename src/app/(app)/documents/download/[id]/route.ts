import { NextResponse } from "next/server";
import { getDocumentDownloadGrant } from "@/services/documents/documents";
import { signedDocumentUrl } from "@/services/documents/storage";

/**
 * Download of an evidence file (Step 06 §5, Step 13 §16, decisions 142/275). `get_document_download_grant`
 * re-checks the signed-in person's permission on every request; only then is a signed URL, valid for one
 * minute, minted and followed. The storage path itself is never shown.
 */
export async function GET(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const grant = await getDocumentDownloadGrant({ document_id: id }).catch(() => null);
  if (!grant) {
    return new NextResponse("Berkas tidak ditemukan atau Anda tidak berhak membukanya.", {
      status: 404,
    });
  }
  const url = grant.storage_path
    ? await signedDocumentUrl(grant.storage_path, grant.file_name)
    : null;
  if (!url) {
    return new NextResponse("Berkas ini belum tersimpan.", { status: 404 });
  }
  return NextResponse.redirect(url, { status: 303, headers: { "Cache-Control": "no-store" } });
}
