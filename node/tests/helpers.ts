// What the package's tests share: where node/BUCK (:package_test) stages the
// fixtures, a scratch directory, and the check of an error's exact class.
//
// The staged directory is the package's: src/ and tests/ at their paths,
// package.json and dist/ beside them, and
//   fake/<name>/libkomira.so            stand-ins built from tests/fake_libkomira.c
//   fixtures/                           cpuinfo files, VARIANTS manifests, choices.tsv, Parquet
//   node_modules/@komira-ai/komira-linux-x64-gnu/
//                                       the platform package: package.json,
//                                       komira_addon.node and native/, the
//                                       self-contained libkomira directory

import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";

import type { Host } from "../src/cpu.ts";

/** The staged package directory. */
export const ROOT = path.dirname(import.meta.dirname);

/** A staged fixture. */
export function fixture(name: string): string {
  return path.join(ROOT, "fixtures", name);
}

/** The directory of a stand-in library: `fake/<name>`, holding libkomira.so. */
export function fake(name: string): string {
  return path.join(ROOT, "fake", name);
}

/** The platform package npm would install on the test's host. */
export const PLATFORM_DIR = path.join(ROOT, "node_modules", "@komira-ai", "komira-linux-x64-gnu");

/** The Node addon, the platform package's. */
export const ADDON_FILE = path.join(PLATFORM_DIR, "komira_addon.node");

/** The x86-64-v3 cpuinfo, the CPU of the hosts below. */
export const V3_CPUINFO = fixture("cpuinfo_x86_64_v3.txt");

/** Linux on x64 with glibc and an x86-64-v3 CPU. */
export const LINUX_X64: Host = { system: "linux", machine: "x64", glibc: true, cpuinfo: V3_CPUINFO };

/** A new empty directory under the test's own temporary directory. */
export function scratch(): string {
  return mkdtempSync(path.join(tmpdir(), "komira-node-"));
}

/** Whether a Node addon has been opened in this process. */
export function addonOpened(): boolean {
  return Object.keys(createRequire(import.meta.url).cache).some((f) => f.endsWith(".node"));
}

/** The constructor of an error class. */
type ErrorClass = abstract new (...args: never[]) => Error;

/** The message of the error `f` throws, which must be exactly of class `cls`. */
export function refused(f: () => unknown, cls: ErrorClass): string {
  try {
    f();
  } catch (e) {
    assert.equal((e as Error).constructor, cls, `${String(e)} is not a ${cls.name}`);
    return (e as Error).message;
  }
  assert.fail(`nothing was refused; a ${cls.name} was expected`);
}

/** The message of the rejection of `p`, which must be exactly of class `cls`. */
export async function rejected(p: Promise<unknown>, cls: ErrorClass): Promise<string> {
  try {
    await p;
  } catch (e) {
    assert.equal((e as Error).constructor, cls, `${String(e)} is not a ${cls.name}`);
    return (e as Error).message;
  }
  assert.fail(`nothing was rejected; a ${cls.name} was expected`);
}
