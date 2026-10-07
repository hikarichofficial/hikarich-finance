"use client";

import { useState } from "react";

/**
 * "Cetak / simpan PDF" and "Unduh CSV" for the report on screen (decision 333). Both work on what the page
 * shows right now, so the file always matches the screen: the browser's print dialog saves a PDF, and the CSV
 * is built from the report's own tables (the text exactly as displayed). Nothing is sent to the server.
 */
function cellText(cell: Element): string {
  return (cell.textContent ?? "").replace(/\s+/g, " ").trim();
}

function csvField(value: string): string {
  return /[;"\r\n]/.test(value) ? `"${value.replace(/"/g, '""')}"` : value;
}

/** Excel with an Indonesian regional setting reads a semicolon as the column separator. */
export function tablesToCsv(tables: readonly HTMLTableElement[]): string {
  const lines: string[] = [];
  tables.forEach((table, index) => {
    if (index > 0) lines.push("");
    table.querySelectorAll("tr").forEach((row) => {
      const cells = Array.from(row.children).filter(
        (c) => c.tagName === "TH" || c.tagName === "TD",
      );
      if (cells.length === 0) return;
      const fields: string[] = [];
      cells.forEach((cell) => {
        fields.push(csvField(cellText(cell)));
        const span = Number((cell as HTMLTableCellElement).colSpan) || 1;
        for (let i = 1; i < span; i += 1) fields.push("");
      });
      lines.push(fields.join(";"));
    });
  });
  return lines.join("\r\n");
}

export function ReportExportButtons({ fileName }: { fileName: string }) {
  const [message, setMessage] = useState<string | null>(null);

  function downloadCsv() {
    const tables = Array.from(
      document.querySelectorAll<HTMLTableElement>("[data-report-root] table"),
    );
    if (tables.length === 0) {
      setMessage("Belum ada tabel untuk diunduh.");
      return;
    }
    const blob = new Blob(["﻿" + tablesToCsv(tables)], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `${fileName}.csv`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
    setMessage(null);
  }

  return (
    <div className="report-export no-print">
      <button type="button" className="btn-secondary" onClick={() => window.print()}>
        Cetak / simpan PDF
      </button>
      <button type="button" className="btn-secondary" onClick={downloadCsv}>
        Unduh CSV
      </button>
      {message ? (
        <p role="status" className="hint">
          {message}
        </p>
      ) : null}
    </div>
  );
}
