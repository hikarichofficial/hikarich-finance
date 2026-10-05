import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";
import jsxA11y from "eslint-plugin-jsx-a11y";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // eslint-config-next's own core-web-vitals bundles jsx-a11y but enables only 6 of its rules (alt-text,
  // the aria-* pair and the role-* pair). Phase 14 (Step 15 §17, "Accessibility... testing") adds the full
  // upstream "recommended" set (34 rules: label-has-associated-control, anchor-is-valid, heading-has-
  // content, html-has-lang, no-noninteractive-element-interactions and more) as a permanent, automated
  // check on every future change, not a one-off manual pass. Only `rules` is spread, not the whole flat
  // config object: `nextVitals` already registers the `jsx-a11y` plugin itself, and flat config refuses to
  // register the same plugin name twice even with the identical underlying plugin.
  { rules: jsxA11y.flatConfigs.recommended.rules },
  // `MoneyInput` renders the real <input> itself, so a <label> around it is labelled exactly as it was around
  // the plain input it replaced (the rule cannot see inside a component unless told).
  {
    rules: {
      "jsx-a11y/label-has-associated-control": [
        "error",
        { controlComponents: ["MoneyInput"], depth: 3 },
      ],
    },
  },
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
  ]),
]);

export default eslintConfig;
