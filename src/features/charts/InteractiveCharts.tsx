"use client";

import Link from "next/link";
import { useState } from "react";
import { compactNumber } from "@/domain/dashboard/chart";

/**
 * Interactive Dashboard / Tax charts: hover (or keyboard focus) a point or bar and the exact figure appears
 * in a tooltip; click and the chart opens the report behind that month. Pure presentation: the exact text
 * shown is formatted on the server from the database's decimal text and passed in as `display`; `value` is
 * only used to place the point or bar.
 */
export interface ChartPoint {
  key: string;
  /** Short axis label ("Okt"). */
  short: string;
  /** Full label for the tooltip ("Oktober 2026"). */
  label: string;
  value: number | null;
  /** Exact figure, already formatted ("Rp 12.500.000"). */
  display: string;
  /** One extra tooltip line, e.g. "+12% dari bulan lalu". */
  note?: string;
  href?: string;
  /** The month the page is showing; drawn stronger. */
  active?: boolean;
}

export type ChartTone = "accent" | "success" | "danger" | "info";

function tooltipSide(index: number, count: number): "start" | "end" | "mid" {
  if (count > 2 && index === 0) return "start";
  if (count > 2 && index === count - 1) return "end";
  return "mid";
}

function Tooltip({
  point,
  index,
  count,
  left,
  top,
}: {
  point: ChartPoint;
  index: number;
  count: number;
  left: number;
  top: number;
}) {
  return (
    <div
      className="chart-tooltip"
      data-side={tooltipSide(index, count)}
      style={{ left: `${left}%`, top: `${top}%` }}
      role="status"
    >
      <span className="chart-tooltip-label">{point.label}</span>
      <strong className="chart-tooltip-value">{point.display}</strong>
      {point.note ? <span className="chart-tooltip-note">{point.note}</span> : null}
      {point.href ? <span className="chart-tooltip-hint">Klik untuk membuka laporan</span> : null}
    </div>
  );
}

function Hit({
  point,
  className,
  style,
  onActive,
  onInactive,
  children,
}: {
  point: ChartPoint;
  className: string;
  style?: React.CSSProperties;
  onActive: () => void;
  onInactive: () => void;
  children?: React.ReactNode;
}) {
  const common = {
    className,
    style,
    onMouseEnter: onActive,
    onMouseLeave: onInactive,
    onFocus: onActive,
    onBlur: onInactive,
    "aria-label": `${point.label}: ${point.display}`,
  };
  return point.href ? (
    <Link href={point.href} {...common}>
      {children}
    </Link>
  ) : (
    <span {...common}>{children}</span>
  );
}

export function LineChart({
  points,
  tone = "accent",
  ariaLabel,
}: {
  points: ChartPoint[];
  tone?: ChartTone;
  ariaLabel: string;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const values = points.map((p) => p.value).filter((v): v is number => v !== null);
  const min = Math.min(...values, 0);
  const max = Math.max(...values, 0);
  const range = max - min || 1;
  const n = points.length;
  const xOf = (i: number) => (n > 1 ? ((i + 0.5) / n) * 100 : 50);
  const yOf = (v: number) => 6 + (1 - (v - min) / range) * 88;

  const plotted = points
    .map((p, i) => (p.value === null ? null : { i, x: xOf(i), y: yOf(p.value) }))
    .filter((p): p is { i: number; x: number; y: number } => p !== null);
  const line = plotted.map((p, k) => `${k === 0 ? "M" : "L"} ${p.x} ${p.y}`).join(" ");
  const zeroY = yOf(0);
  const area =
    plotted.length > 1
      ? `${line} L ${plotted[plotted.length - 1].x} ${zeroY} L ${plotted[0].x} ${zeroY} Z`
      : "";
  const ticks = [max, (max + min) / 2, min];

  return (
    <div className="chart" data-tone={tone} role="group" aria-label={ariaLabel}>
      <div className="chart-body">
        <div className="chart-axis" aria-hidden="true">
          {ticks.map((t, k) => (
            <span key={k} style={{ top: `${yOf(t)}%` }}>
              {compactNumber(t)}
            </span>
          ))}
        </div>
        <div className="chart-plot chart-plot-line">
          {ticks.map((t, k) => (
            <div key={k} className="chart-grid" style={{ top: `${yOf(t)}%` }} />
          ))}
          <svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
            {area ? <path className="chart-area" d={area} /> : null}
            {line ? (
              <path className="chart-line" d={line} vectorEffect="non-scaling-stroke" />
            ) : null}
          </svg>
          {points.map((p, i) => (
            <Hit
              key={p.key}
              point={p}
              className="chart-hit"
              style={{ left: `${(i / n) * 100}%`, width: `${100 / n}%` }}
              onActive={() => setHover(i)}
              onInactive={() => setHover((h) => (h === i ? null : h))}
            />
          ))}
          {plotted.map((p) => (
            <span
              key={p.i}
              className="chart-dot"
              data-hover={hover === p.i ? "true" : undefined}
              data-active={points[p.i].active ? "true" : undefined}
              style={{ left: `${p.x}%`, top: `${p.y}%` }}
            />
          ))}
          {hover !== null && points[hover].value !== null ? (
            <Tooltip
              point={points[hover]}
              index={hover}
              count={n}
              left={xOf(hover)}
              top={yOf(points[hover].value as number)}
            />
          ) : null}
        </div>
      </div>
      <div className="chart-labels">
        {points.map((p) => (
          <span key={p.key} data-active={p.active ? "true" : undefined}>
            {p.short}
          </span>
        ))}
      </div>
    </div>
  );
}

export function BarChart({
  points,
  tone = "accent",
  ariaLabel,
}: {
  points: ChartPoint[];
  tone?: ChartTone;
  ariaLabel: string;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const values = points.map((p) => Math.abs(p.value ?? 0));
  const max = Math.max(...values, 0) || 1;
  const n = points.length;
  const ticks = [max, max / 2, 0];

  return (
    <div className="chart" data-tone={tone} role="group" aria-label={ariaLabel}>
      <div className="chart-body">
        <div className="chart-axis" aria-hidden="true">
          {ticks.map((t, k) => (
            <span key={k} style={{ top: `${6 + (1 - t / max) * 88}%` }}>
              {compactNumber(t)}
            </span>
          ))}
        </div>
        <div className="chart-plot chart-plot-bars">
          {ticks.map((t, k) => (
            <div key={k} className="chart-grid" style={{ top: `${6 + (1 - t / max) * 88}%` }} />
          ))}
          {points.map((p, i) => {
            const height = (Math.abs(p.value ?? 0) / max) * 88;
            return (
              <Hit
                key={p.key}
                point={p}
                className="chart-column"
                style={{ left: `${(i / n) * 100}%`, width: `${100 / n}%` }}
                onActive={() => setHover(i)}
                onInactive={() => setHover((h) => (h === i ? null : h))}
              >
                <span
                  className="chart-bar"
                  data-hover={hover === i ? "true" : undefined}
                  data-active={p.active ? "true" : undefined}
                  style={{ height: `${p.value ? Math.max(height, 1.5) : 0}%` }}
                />
              </Hit>
            );
          })}
          {hover !== null ? (
            <Tooltip
              point={points[hover]}
              index={hover}
              count={n}
              left={((hover + 0.5) / n) * 100}
              top={6 + (1 - Math.abs(points[hover].value ?? 0) / max) * 88}
            />
          ) : null}
        </div>
      </div>
      <div className="chart-labels">
        {points.map((p) => (
          <span key={p.key} data-active={p.active ? "true" : undefined}>
            {p.short}
          </span>
        ))}
      </div>
    </div>
  );
}
