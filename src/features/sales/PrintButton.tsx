"use client";

export function PrintButton({ label = "Cetak / simpan PDF" }: { label?: string }) {
  return (
    <button type="button" className="print-button" onClick={() => window.print()}>
      {label}
    </button>
  );
}
