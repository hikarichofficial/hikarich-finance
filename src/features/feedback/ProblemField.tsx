"use client";

import { useState, type ReactNode } from "react";

/** Counts the answers a form has received: a new refusal gets a new number, so a field the person already fixed
 * is painted red again if the next refusal is about it. */
export function useAnswerSerial(state: unknown): number {
  const [seen, setSeen] = useState(state);
  const [serial, setSerial] = useState(0);
  if (seen !== state) {
    setSeen(state);
    setSerial(serial + 1);
  }
  return serial;
}

/**
 * A form field (label + input) the last refusal was about (OWNER, 8 October 2026): red border and red wash with
 * what to do under it, until the person touches it. `serial` (from `useAnswerSerial`) restarts "touched" for
 * every new refusal.
 */
export function ProblemField({
  active,
  hint,
  serial,
  children,
}: {
  active: boolean;
  hint: string;
  serial: number;
  children: ReactNode;
}) {
  return (
    <ProblemFieldInner key={serial} active={active} hint={hint}>
      {children}
    </ProblemFieldInner>
  );
}

function ProblemFieldInner({
  active,
  hint,
  children,
}: {
  active: boolean;
  hint: string;
  children: ReactNode;
}) {
  const [touched, setTouched] = useState(false);
  const show = active && !touched;
  return (
    <div
      className={show ? "field-problem" : "field-wrap"}
      onInput={() => setTouched(true)}
      onFocus={() => setTouched(true)}
    >
      {children}
      {show ? <p className="field-problem-hint">{hint}</p> : null}
    </div>
  );
}
