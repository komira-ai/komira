// The package's version: the `version` of its own package.json, which the
// package rule stamps, so the code holds no second copy of it.

import { createRequire } from "node:module";

import { KomiraError } from "./errors.ts";
import { PACKAGE } from "./platform.ts";

/** The `version` of a parsed package.json, or a KomiraError when it has none. */
export function packageVersion(manifest: unknown): string {
  const v = typeof manifest === "object" && manifest !== null ? (manifest as { version?: unknown }).version : undefined;
  if (typeof v !== "string") {
    throw new KomiraError(`the package.json of ${PACKAGE} has no version`);
  }
  return v;
}

/** The version of this package. */
export const version: string = packageVersion(createRequire(import.meta.url)("../package.json"));
