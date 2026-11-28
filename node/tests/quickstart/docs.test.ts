// The install page (docs/install_node.md) and the package's README
// (node/README.md) show the quickstart and what it prints, read from the
// files themselves: each one's ```js block is examples/quickstart.mjs byte for
// byte, and its ```text block is examples/quickstart.expected with
// <abi_version> the version of the ABI table, <version> and <cwd> left as
// written (the docs explain them). The package name the docs install and the
// example imports is package.json's `name`. A change to one file without the
// others fails here, naming the first line that differs.

import assert from "node:assert/strict";
import { test } from "node:test";

import { docShowsBlock, fencedBlocks, fill } from "./shown.ts";
import { EXAMPLE, EXPECTED, MANIFEST, abiVersion, staged } from "./staged.ts";

const DOCS = [
  { doc: "docs/install_node.md", file: "install_node.md" },
  { doc: "node/README.md", file: "README.md" },
];

for (const { doc, file } of DOCS) {
  test(`${doc}'s js block is the quickstart byte for byte`, () => {
    const why = docShowsBlock({ doc, fence: "js", source: `node/${EXAMPLE}` }, staged(file), staged(EXAMPLE));
    assert.equal(why, null);
  });

  test(`${doc}'s text block is what the quickstart prints, with the ABI version put in`, () => {
    const want = fill(staged(EXPECTED), { abi_version: abiVersion() });
    const why = docShowsBlock({ doc, fence: "text", source: `node/${EXPECTED}` }, staged(file), want);
    assert.equal(why, null);
  });

  test(`${doc} installs the package by package.json's name, in a sh block`, () => {
    const lines = fencedBlocks(staged(file), "sh").flatMap((b) => b.lines);
    assert.ok(lines.includes(`npm install ${MANIFEST.name}`), `${doc} has no sh line 'npm install ${MANIFEST.name}'`);
  });
}

test("the quickstart imports the package by package.json's name", () => {
  const lines = staged(EXAMPLE).split("\n");
  assert.ok(lines.includes(`import * as km from "${MANIFEST.name}";`), `node/${EXAMPLE} does not import ${MANIFEST.name} as km`);
});

test("the expected output has each placeholder the docs explain", () => {
  const text = staged(EXPECTED);
  for (const placeholder of ["<version>", "<abi_version>", "<cwd>"]) {
    assert.ok(text.includes(placeholder), `node/${EXPECTED} has no ${placeholder}`);
  }
});
