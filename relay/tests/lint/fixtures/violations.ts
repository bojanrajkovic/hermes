// One deliberate violation per rule tests/lint/lint.test.ts checks. `pnpm lint` skips this directory.

// consistent-type-definitions
interface Shape {
  a: number;
}

// method-signature-style
type WithMethod = { run(x: number): void };

// no-restricted-syntax: inline return type
export function inlineReturn(): { a: number } {
  return { a: 1 };
}

// explicit-function-return-type
export function noReturnType() {
  return 1;
}

// max-params
export function tooMany(a: number, b: number, c: number, d: number, e: number): number {
  return a + b + c + d + e;
}

// strict-boolean-expressions (allowNumber: false)
export function truthyNumber(n: number): string {
  if (n) {
    return "yes";
  }

  return "no";
}

// strict-boolean-expressions (allowNullableString: false)
export function truthyString(s: string | undefined): boolean {
  return s ? true : false;
}

// require-unicode-regexp (requireFlag v)
export const re = /abc/u;

// no-unsafe-type-assertion
export const narrowed = JSON.parse("1") as unknown as Shape;
export function widen(x: string | number): number {
  return x as number;
}

// require-array-sort-compare (ignoreStringArrays: false)
export const sorted = ["b", "a"].sort();

// init-declarations
export function uninit(): number {
  let x: number;
  x = 1;
  return x;
}

// prefer-destructuring (object)
export function noDestructure(o: { value: number }): number {
  const value = o.value;
  return value;
}

// return-await (always)
export async function noAwait(): Promise<number> {
  return Promise.resolve(1);
}

// promise-function-async
export function returnsPromise(): Promise<number> {
  return Promise.resolve(1);
}

// switch-exhaustiveness-check
export function notExhaustive(k: "a" | "b"): number {
  switch (k) {
    case "a":
      return 1;
  }

  return 0;
}

// no-floating-promises (strictTypeChecked)
export function floating(): void {
  void 0;
  Promise.resolve(1);
}

// no-unnecessary-condition (strictTypeChecked)
export function alwaysTrue(s: string): number {
  if (s !== undefined) {
    return 1;
  }

  return 0;
}

// curly
export function noCurly(n: number): number {
  if (n > 1) return 1;

  return 0;
}

// @stylistic/padding-line-between-statements
export function noPadding(n: number): number {
  const m = n + 1;
  if (m > 2) {
    return 1;
  }
  return m;
}

// no-unused-vars (recommended)
const unused = 1;

// prefer-nullish-coalescing (stylisticTypeChecked)
export function orDefault(s: string | undefined): string {
  return s || "x";
}

// no-unused-vars, which in Oxlint skips `_` names unless given options
const _unusedToo = 1;
