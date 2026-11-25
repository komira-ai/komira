// Where the native files are: the platform package (docs/design/typescript_package.md,
// "The packages" and "How the package finds libkomira"). npm installs, of the
// main package's optional dependencies, only the one whose `os`, `cpu` and
// `libc` match the host; this module names that package and finds the
// directory it was installed in with require.resolve. No environment variable,
// no search of the working directory and no global path is read.

import { createRequire } from "node:module";
import path from "node:path";

import type { Host } from "./cpu.ts";
import { LibraryLoadError } from "./errors.ts";

/**
 * The npm name of this package. A placeholder until the name is decided:
 * docs/design/typescript_package.md, decisions D1 and D4.
 */
export const PACKAGE = "@komira-ai/komira";

/** The platform package's Node addon, at its top. */
export const ADDON = "komira_addon.node";

/**
 * The platform package's copy of the self-contained native directory:
 * libkomira, its native owners and the Mojo runtime libraries, laid out as
 * the directory lays them out.
 */
export const NATIVE = "native";

/**
 * The platform packages, by `<system>-<machine>[-<libc>]` as `process.platform`
 * and `process.arch` spell the host. These are the release platforms
 * linux-x86_64, linux-arm64 and macos-arm64.
 */
const PLATFORM_PACKAGES: Readonly<Record<string, string>> = {
  "linux-x64-gnu": `${PACKAGE}-linux-x64-gnu`,
  "linux-arm64-gnu": `${PACKAGE}-linux-arm64-gnu`,
  "darwin-arm64": `${PACKAGE}-darwin-arm64`,
};

/** Every platform package's name, in the order of the table above. */
export const PLATFORM_PACKAGE_NAMES: readonly string[] = Object.values(PLATFORM_PACKAGES);

/**
 * The name of the platform package that holds libkomira for `host`, or a
 * LibraryLoadError saying there is none.
 */
export function platformPackage(host: Host): string {
  const libc = host.system === "linux" ? (host.glibc ? "-gnu" : "-other") : "";
  const name = PLATFORM_PACKAGES[`${host.system}-${host.machine}${libc}`];
  if (name === undefined) {
    const what = libc === "-other" ? `${host.system} ${host.machine} without glibc` : `${host.system} ${host.machine}`;
    throw new LibraryLoadError(
      `komira has no native package for ${what}: its packages are for Linux on x64 and arm64 with glibc, ` +
        `and for macOS on arm64`,
    );
  }
  return name;
}

/**
 * The directory the platform package `name` is installed in, resolved as a
 * dependency of the module at `from` (this module, unless a test passes
 * another). A package that is not installed is a LibraryLoadError that says
 * how to install it; any other failure to resolve it is one with the
 * resolver's message.
 */
export function platformPackageDir(name: string, from: string | URL = import.meta.url): string {
  let manifest: string;
  try {
    manifest = createRequire(from).resolve(`${name}/package.json`);
  } catch (e) {
    // The resolver throws an Error with a `code`.
    if ((e as { code?: unknown }).code === "MODULE_NOT_FOUND") {
      throw new LibraryLoadError(
        `the package ${name}, which holds libkomira for this platform, is not installed. npm installs it ` +
          `with ${PACKAGE} unless optional dependencies are left out (--omit=optional or --no-optional): ` +
          `install ${PACKAGE} again without that option`,
      );
    }
    throw new LibraryLoadError(`cannot resolve the package ${name}: ${(e as Error).message}`);
  }
  return path.dirname(manifest);
}

/**
 * The host this process runs on: `process.platform`, `process.arch`, whether
 * Node runs on glibc (its own diagnostic report names the glibc it found at
 * run time; asked on Linux only), and /proc/cpuinfo.
 */
export function defaultHost(): Host {
  return {
    system: process.platform,
    machine: process.arch,
    glibc: process.platform === "linux" && runsOnGlibc(),
    cpuinfo: "/proc/cpuinfo",
  };
}

/** Whether Node's diagnostic report names a glibc it runs on. */
function runsOnGlibc(): boolean {
  const report = process.report.getReport() as { header: { glibcVersionRuntime?: unknown } };
  return typeof report.header.glibcVersionRuntime === "string";
}
