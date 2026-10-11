import { NextResponse } from "next/server";
import { getDocumentDownloadGrant } from "@/services/documents/documents";
import { signedDocumentUrl } from "@/services/documents/storage";

/**
 * Inline view of an evidence file for the preview popup (decision 408). The same permission re-check as the
 * download route (`get_document_download_grant`); the bytes are fetched on the server from a short-lived signed
 * URL and returned from this site's own address with `inline`, so the popup can show them in a frame of this
 * site and the browser can print them. The storage path and the signed URL are never shown to the browser.
 */
const MAX_PREVIEW_BYTES = 12 * 1024 * 1024;

export async function GET(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const grant = await getDocumentDownloadGrant({ document_id: id }).catch(() => null);
  if (!grant) {
    return new NextResponse("Berkas tidak ditemukan atau Anda tidak berhak membukanya.", {
      status: 404,
    });
  }
  const url = grant.storage_path
    ? await signedDocumentUrl(grant.storage_path, grant.file_name, false)
    : null;
  if (!url) {
    return new NextResponse("Berkas ini belum tersimpan.", { status: 404 });
  }
  const upstream = await fetch(url, { cache: "no-store" });
  if (!upstream.ok) {
    return new NextResponse("Berkas tidak dapat dimuat.", { status: 502 });
  }
  const bytes = await upstream.arrayBuffer();
  if (bytes.byteLength > MAX_PREVIEW_BYTES) {
    return new NextResponse("Berkas terlalu besar untuk ditampilkan; gunakan Unduh.", {
      status: 413,
    });
  }
  return new NextResponse(bytes, {
    status: 200,
    headers: {
      "Content-Type": grant.mime_type,
      "Content-Disposition": `inline; filename*=UTF-8''${encodeURIComponent(grant.file_name)}`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "SAMEORIGIN",
    },
  });
}
