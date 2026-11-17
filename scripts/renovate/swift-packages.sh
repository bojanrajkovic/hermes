#!/usr/bin/env bash
# Renovate runs this after a Swift package update. Renovate changes Package.swift only. This brings
# Package.resolved in line with it, and re-copies the scanner of a grammar whose version changed
# (PROBLEMS.md). It changes nothing when the versions already match. Run it from the repo root.
#
# It runs no Swift and no code from a package. `swift package resolve` would run the manifest of
# the version just brought in, and Renovate's worker holds a key that can write to every repo. So
# this asks each package's repository for the commit of the new tag, and fetches the scanner
# files at that commit. `make packages` is the exact version, with Swift. The Swift check workflow
# runs it and fails if this script's result differs, which happens when an update moves a package
# that Package.swift doesn't name.
set -euo pipefail

exec node --input-type=module - <<'EOF'
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const manifest = readFileSync("Package.swift", "utf8");
const resolved = JSON.parse(readFileSync("Package.resolved", "utf8"));

// The grammars whose scanner the app compiles from a copy, and the files each copy needs.
const scanners = {
  "tree-sitter-css": { "src/scanner.c": "css-scanner.c" },
  "tree-sitter-javascript": { "src/scanner.c": "javascript-scanner.c" },
  "tree-sitter-python": { "src/scanner.c": "python-scanner.c" },
  "tree-sitter-yaml": {
    "src/scanner.c": "yaml-scanner.c",
    "src/schema.core.c": "schema.core.c",
    "src/schema.json.c": "schema.json.c",
    "src/schema.legacy.c": "schema.legacy.c",
  },
};

function fail(message) {
  console.error(`swift-packages: ${message}`);
  process.exit(1);
}

/** Whether version `a` is older than `b`, comparing their dotted numbers. */
function older(a, b) {
  const [x, y] = [a, b].map((v) => v.split("-")[0].split(".").map(Number));
  for (let i = 0; i < Math.max(x.length, y.length); i += 1) {
    if ((x[i] ?? 0) !== (y[i] ?? 0)) {
      return (x[i] ?? 0) < (y[i] ?? 0);
    }
  }
  return false;
}

/** The commit a version's tag names. A tag may carry a `v`, and an annotated tag lists its commit as `^{}`. */
function commitOf(url, version) {
  const refs = [version, `v${version}`].flatMap((tag) => [`refs/tags/${tag}`, `refs/tags/${tag}^{}`]);
  const lines = execFileSync("git", ["ls-remote", url, ...refs], { encoding: "utf8" }).trim().split("\n");
  const found = lines.filter((line) => line !== "").map((line) => line.split("\t"));
  const commit = found.find(([, ref]) => ref.endsWith("^{}")) ?? found[0];
  if (commit === undefined) {
    fail(`${url} has no tag for ${version}`);
  }
  return commit[0];
}

const packages = manifest.matchAll(/\.package\(url: "([^"]+)", (exact|from): "([^"]+)"\)/g);
for (const [, url, requirement, version] of packages) {
  const identity = url.split("/").at(-1).replace(/\.git$/, "").toLowerCase();
  const pin = resolved.pins.find((candidate) => candidate.identity === identity);
  if (pin === undefined) {
    fail(`Package.resolved has no pin for ${identity}. Run \`make packages\`.`);
  }

  // A `from:` requirement only moves the pin when the pin is below it.
  const satisfied =
    requirement === "exact" ? pin.state.version === version : !older(pin.state.version, version);
  if (satisfied) {
    continue;
  }

  pin.state = { revision: commitOf(url, version), version };
  console.log(`swift-packages: ${identity} is now ${version} (${pin.state.revision})`);

  const repository = new URL(url).pathname.replace(/\.git$/, "");
  for (const [source, copy] of Object.entries(scanners[identity] ?? {})) {
    const file = `https://raw.githubusercontent.com${repository}/${pin.state.revision}/${source}`;
    const response = await fetch(file);
    if (!response.ok) {
      fail(`can't fetch ${file}: HTTP ${response.status}`);
    }
    writeFileSync(`Sources/TreeSitterScanners/${copy}`, Buffer.from(await response.arrayBuffer()));
    console.log(`swift-packages: copied ${source} to Sources/TreeSitterScanners/${copy}`);
  }
}

// SwiftPM stamps the file with the manifest's hash, and writes `"key" : value`.
resolved.originHash = createHash("sha256").update(manifest).digest("hex");
const text = JSON.stringify(resolved, null, 2).replace(/^(\s*"[^"]+"):/gm, "$1 :");
writeFileSync("Package.resolved", `${text}\n`);
EOF
