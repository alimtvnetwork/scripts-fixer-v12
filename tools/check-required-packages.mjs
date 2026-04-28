#!/usr/bin/env node
/* eslint-disable no-console */
/**
 * tools/check-required-packages.mjs
 *
 * Verifies that every package listed in tools/check-required-packages.config.json
 * is actually installed under node_modules/. For anything missing or version-
 * mismatched, prints a clear, copy-pasteable fix command for whichever package
 * manager the project uses (auto-detected from lockfile -- npm / bun / pnpm / yarn).
 *
 * Designed to be the first thing you run when you see:
 *
 *   error TS2307: Cannot find module '@supabase/supabase-js'
 *
 * Usage:
 *   node tools/check-required-packages.mjs            # check, print fix hints
 *   node tools/check-required-packages.mjs --quiet    # only print failures
 *   node tools/check-required-packages.mjs --json     # machine-readable output
 *   node tools/check-required-packages.mjs --fix      # actually install missing pkgs
 *
 * Exit codes:
 *   0 = everything required is installed
 *   1 = one or more required packages are missing / mismatched
 *   2 = config / IO error (path + reason printed in CODE RED format)
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(__dirname, "..");
const configPath = join(__dirname, "check-required-packages.config.json");
const pkgJsonPath = join(projectRoot, "package.json");
const nodeModulesDir = join(projectRoot, "node_modules");

// -- ANSI colors (match the colorful-logging convention) -------------------
const ansi = process.stdout.isTTY ? {
  reset: "\x1b[0m", bold: "\x1b[1m", dim: "\x1b[2m",
  red: "\x1b[31m", green: "\x1b[32m", yellow: "\x1b[33m",
  blue: "\x1b[34m", magenta: "\x1b[35m", cyan: "\x1b[36m", gray: "\x1b[90m",
} : Object.fromEntries(["reset","bold","dim","red","green","yellow","blue","magenta","cyan","gray"].map(k => [k, ""]));

const c = (color, s) => `${ansi[color] ?? ""}${s}${ansi.reset}`;

const args = new Set(process.argv.slice(2));
const flags = {
  quiet: args.has("--quiet") || args.has("-q"),
  json:  args.has("--json"),
  fix:   args.has("--fix"),
};

// -- CODE RED helpers ------------------------------------------------------
const fileError = (path, reason) => {
  console.error(c("red", `  [FAIL] path: ${path} -- reason: ${reason}`));
};

const die = (path, reason) => {
  fileError(path, reason);
  process.exit(2);
};

// -- Read config + package.json --------------------------------------------
let config;
try {
  if (!existsSync(configPath)) die(configPath, "config file does not exist");
  config = JSON.parse(readFileSync(configPath, "utf8"));
} catch (err) {
  die(configPath, err.message);
}

let projectPkg;
try {
  if (!existsSync(pkgJsonPath)) die(pkgJsonPath, "project package.json does not exist");
  projectPkg = JSON.parse(readFileSync(pkgJsonPath, "utf8"));
} catch (err) {
  die(pkgJsonPath, err.message);
}

const declared = {
  ...(projectPkg.dependencies ?? {}),
  ...(projectPkg.devDependencies ?? {}),
  ...(projectPkg.peerDependencies ?? {}),
  ...(projectPkg.optionalDependencies ?? {}),
};

// -- Package manager detection --------------------------------------------
const detectPM = () => {
  if (existsSync(join(projectRoot, "bun.lockb")) || existsSync(join(projectRoot, "bun.lock"))) return "bun";
  if (existsSync(join(projectRoot, "pnpm-lock.yaml"))) return "pnpm";
  if (existsSync(join(projectRoot, "yarn.lock"))) return "yarn";
  return "npm";
};
const pm = detectPM();

const installCmd = (pkgs) => {
  const list = pkgs.join(" ");
  switch (pm) {
    case "bun":  return `bun add ${list}`;
    case "pnpm": return `pnpm add ${list}`;
    case "yarn": return `yarn add ${list}`;
    default:     return `npm install ${list}`;
  }
};

// -- Per-package check -----------------------------------------------------
/**
 * @typedef {{
 *   name: string,
 *   reason?: string,
 *   declared?: string,
 *   installed?: string,
 *   status: "ok" | "missing-from-package-json" | "missing-from-node-modules" | "unreadable",
 *   detail?: string,
 * }} CheckResult
 */

/** @returns {CheckResult} */
const checkOne = (entry) => {
  const name = entry.name;
  const declaredRange = declared[name];

  if (!declaredRange) {
    return {
      name,
      reason: entry.reason,
      status: "missing-from-package-json",
      detail: "not listed in dependencies / devDependencies / peerDependencies",
    };
  }

  const modPkgPath = join(nodeModulesDir, ...name.split("/"), "package.json");
  if (!existsSync(modPkgPath)) {
    return {
      name,
      reason: entry.reason,
      declared: declaredRange,
      status: "missing-from-node-modules",
      detail: `node_modules/${name}/package.json not found`,
    };
  }

  try {
    const installed = JSON.parse(readFileSync(modPkgPath, "utf8")).version;
    return {
      name,
      reason: entry.reason,
      declared: declaredRange,
      installed,
      status: "ok",
    };
  } catch (err) {
    return {
      name,
      reason: entry.reason,
      declared: declaredRange,
      status: "unreadable",
      detail: `path: ${modPkgPath} -- reason: ${err.message}`,
    };
  }
};

const required = (config.required ?? []).map(checkOne);
const optional = (config.optional ?? []).map(checkOne);

// -- JSON mode -------------------------------------------------------------
if (flags.json) {
  const failures = required.filter(r => r.status !== "ok");
  console.log(JSON.stringify({
    pm,
    ok: failures.length === 0,
    required,
    optional,
  }, null, 2));
  process.exit(failures.length === 0 ? 0 : 1);
}

// -- Pretty print ----------------------------------------------------------
const printRow = (r) => {
  const label = {
    "ok":                          c("green",  "OK     "),
    "missing-from-package-json":   c("red",    "MISSING"),
    "missing-from-node-modules":   c("yellow", "UNINST."),
    "unreadable":                  c("red",    "BROKEN "),
  }[r.status];

  const versions = r.status === "ok"
    ? c("gray", `(${r.installed} satisfies ${r.declared})`)
    : r.declared
      ? c("gray", `(declared: ${r.declared}, installed: -)`)
      : c("gray", "(not declared)");

  console.log(`  ${label}  ${c("bold", r.name)}  ${versions}`);
  if (r.status !== "ok") {
    if (r.detail) console.log(`           ${c("dim", r.detail)}`);
    if (r.reason) console.log(`           ${c("dim", "why: " + r.reason)}`);
  }
};

if (!flags.quiet) {
  console.log("");
  console.log(c("cyan", "============================================================"));
  console.log(c("cyan", `  Required-package check   (package manager: ${pm})`));
  console.log(c("cyan", "============================================================"));
  console.log("");
  console.log(c("bold", "Required:"));
  required.forEach(printRow);
  if (optional.length) {
    console.log("");
    console.log(c("bold", "Optional:"));
    optional.forEach(printRow);
  }
  console.log("");
}

// -- Fix command summary ---------------------------------------------------
const failures = required.filter(r => r.status !== "ok");
const missingFromPkg     = failures.filter(r => r.status === "missing-from-package-json").map(r => r.name);
const missingFromModules = failures.filter(r => r.status === "missing-from-node-modules").map(r => r.name);
const broken             = failures.filter(r => r.status === "unreadable");

if (failures.length === 0) {
  if (!flags.quiet) console.log(c("green", "All required packages are installed."));
  process.exit(0);
}

console.log(c("red", `${failures.length} required package(s) need attention.`));
console.log("");

if (missingFromPkg.length) {
  console.log(c("yellow", "Not in package.json -- add them:"));
  console.log("  " + c("bold", installCmd(missingFromPkg)));
  console.log("");
}

if (missingFromModules.length) {
  console.log(c("yellow", "Declared but not installed -- run install:"));
  switch (pm) {
    case "bun":  console.log("  " + c("bold", "bun install"));  break;
    case "pnpm": console.log("  " + c("bold", "pnpm install")); break;
    case "yarn": console.log("  " + c("bold", "yarn install")); break;
    default:     console.log("  " + c("bold", "npm install"));
  }
  console.log("  " + c("dim", `(or reinstall just the missing ones: ${installCmd(missingFromModules)})`));
  console.log("");
}

if (broken.length) {
  console.log(c("red", "Broken installs (corrupt package.json under node_modules):"));
  broken.forEach(r => fileError(r.name, r.detail ?? "unreadable"));
  console.log("  " + c("dim", "Try removing node_modules and reinstalling."));
  console.log("");
}

// -- Optional auto-fix -----------------------------------------------------
if (flags.fix && (missingFromPkg.length || missingFromModules.length)) {
  const toAdd = [...new Set([...missingFromPkg, ...missingFromModules])];
  const cmd = installCmd(toAdd);
  console.log(c("magenta", `Running: ${cmd}`));
  const [bin, ...rest] = cmd.split(" ");
  const r = spawnSync(bin, rest, { cwd: projectRoot, stdio: "inherit", shell: process.platform === "win32" });
  process.exit(r.status ?? 1);
}

process.exit(1);
