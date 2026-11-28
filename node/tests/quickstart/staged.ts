// What the quickstart's tests share: where node/BUCK (:quickstart_test and
// :quickstart_integration) stages the files they read.
//
// The staged directory is the package's (tests/helpers.ts), and in it
//   package.json                     the manifest, whose `name` is the install line's and the import's
//   README.md                        node/README.md
//   install_node.md                  docs/install_node.md
//   examples/quickstart.mjs          the first program
//   examples/quickstart.expected     what it prints, with <version>, <abi_version> and <cwd>
//   fixtures/komira.tsv              the ABI table (src/so/abi/komira.tsv)

import { readFileSync } from "node:fs";
import path from "node:path";

import { abiVersionOf } from "./shown.ts";

/** The staged package directory. */
export const ROOT = path.dirname(path.dirname(import.meta.dirname));

/** The text of the staged file `name`. */
export function staged(name: string): string {
  return readFileSync(path.join(ROOT, name), "utf8");
}

/** The package's manifest. */
export const MANIFEST = JSON.parse(staged("package.json")) as { name: string; version: string };

/** The example's path in the staged directory. */
export const EXAMPLE = "examples/quickstart.mjs";

/** The expected output's path in the staged directory. */
export const EXPECTED = "examples/quickstart.expected";

/** The ABI version of the ABI table, as the example prints it. */
export function abiVersion(): string {
  return String(abiVersionOf("src/so/abi/komira.tsv", staged("fixtures/komira.tsv")));
}
