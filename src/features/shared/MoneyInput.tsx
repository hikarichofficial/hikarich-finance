"use client";

import { useLayoutEffect, useRef, useState, type InputHTMLAttributes } from "react";
import { trimDecimalText } from "@/domain/money/format";
import { parseMoneyInput } from "@/domain/money/input";
import {
  canonicalFromTyping,
  caretAfterFormatting,
  formatMoneyTyping,
  plainMoneyText,
} from "@/domain/money/typing";

type Passthrough = Omit<
  InputHTMLAttributes<HTMLInputElement>,
  "type" | "inputMode" | "value" | "defaultValue" | "onChange" | "name"
>;

/**
 * An amount field that puts the thousands separators in by itself while the person types (OWNER, 5 October
 * 2026): "100000000" becomes "100.000.000", and a comma starts the decimals. It is a drop-in for the plain
 * `<input name="amount" inputMode="decimal">` the forms used before: with `name` it submits the plain decimal
 * text ("100000000", "1500.5") through a hidden field, so no server action or schema changes; the visible
 * field never carries a name. Uncontrolled with `defaultValue`, or controlled with `value` + `onValueChange`
 * (the line editors); the parent always gets the plain text, while the field itself remembers a decimal
 * mark that was just typed ("1.500," shows its comma until the next digit).
 */
export function MoneyInput({
  name,
  value,
  defaultValue,
  onValueChange,
  ...rest
}: Passthrough & {
  name?: string;
  value?: string;
  defaultValue?: string;
  onValueChange?: (plain: string) => void;
}) {
  const [inner, setInner] = useState(() => trimDecimalText(value ?? defaultValue ?? ""));
  // A controlled value that changed from outside (a suggestion filled it, the form was reset) wins over
  // what this field last typed.
  const canonical = value !== undefined && plainMoneyText(inner) !== value ? value : inner;
  const display = formatMoneyTyping(canonical);
  const ref = useRef<HTMLInputElement>(null);
  const caret = useRef<number | null>(null);

  useLayoutEffect(() => {
    if (caret.current !== null && ref.current && document.activeElement === ref.current) {
      ref.current.setSelectionRange(caret.current, caret.current);
    }
    caret.current = null;
  });

  function commit(next: string, rawBeforeCaret: string | null) {
    if (rawBeforeCaret !== null) {
      caret.current = caretAfterFormatting(rawBeforeCaret, formatMoneyTyping(next));
    }
    setInner(next);
    onValueChange?.(plainMoneyText(next));
  }

  return (
    <>
      <input
        {...rest}
        ref={ref}
        type="text"
        inputMode="decimal"
        autoComplete="off"
        value={display}
        onChange={(event) => {
          const target = event.target;
          commit(
            canonicalFromTyping(target.value),
            target.value.slice(0, target.selectionStart ?? target.value.length),
          );
        }}
        onPaste={(event) => {
          const parsed = parseMoneyInput(event.clipboardData.getData("text"));
          if (parsed === null) return;
          event.preventDefault();
          commit(canonicalFromTyping(parsed.replace(".", ",")), null);
        }}
      />
      {name ? <input type="hidden" name={name} value={plainMoneyText(canonical)} /> : null}
    </>
  );
}
