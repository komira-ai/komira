// The check the docs are held to (shown.ts), on documents written here: a
// block equal to the file passes wherever it is, and every way a block can
// differ is refused with the whole message, naming the line.

import assert from "node:assert/strict";
import { test } from "node:test";

import { abiVersionOf, docShowsBlock, fencedBlocks, fill, type Shown } from "./shown.ts";

const SHOWN: Shown = { doc: "docs/page.md", fence: "js", source: "examples/q.mjs" };
const HEAD = "docs/page.md shows no ```js block equal to examples/q.mjs: ";
const FILE = "const a = 1;\n\nconsole.log(a);\n";

/** A document of `body` lines, as text with a line feed after each. */
function doc(...body: string[]): string {
  return body.map((line) => line + "\n").join("");
}

test("a block equal to the file passes, after other text and other fences, and with no final line feed", () => {
  const equal = ["```js", "const a = 1;", "", "console.log(a);", "```"];
  assert.equal(docShowsBlock(SHOWN, doc("# Page", "```sh", "npm install x", "```", ...equal, "after"), FILE), null);
  assert.equal(docShowsBlock(SHOWN, doc(...equal).slice(0, -1), FILE), null);
  // The second ```js block is the equal one.
  assert.equal(docShowsBlock(SHOWN, doc("```js", "other", "```", ...equal), FILE), null);
});

test("a block with one line different is refused naming that line and both texts", () => {
  assert.equal(
    docShowsBlock(SHOWN, doc("```js", "const a = 1;", "", "console.log(b);", "```"), FILE),
    `${HEAD}line 3 of the closest block reads 'console.log(b);', examples/q.mjs's reads 'console.log(a);'`,
  );
  // A trailing space is a difference.
  assert.equal(
    docShowsBlock(SHOWN, doc("```js", "const a = 1; ", "", "console.log(a);", "```"), FILE),
    `${HEAD}line 1 of the closest block reads 'const a = 1; ', examples/q.mjs's reads 'const a = 1;'`,
  );
});

test("a block with a line more, or a line less, is refused at the first line they do not share", () => {
  assert.equal(
    docShowsBlock(SHOWN, doc("```js", "const a = 1;", "", "console.log(a);", "extra", "```"), FILE),
    `${HEAD}line 4 of the closest block reads 'extra', examples/q.mjs's reads '(examples/q.mjs ends)'`,
  );
  assert.equal(
    docShowsBlock(SHOWN, doc("```js", "const a = 1;", "", "```"), FILE),
    `${HEAD}line 3 of the closest block reads '(the block ends)', examples/q.mjs's reads 'console.log(a);'`,
  );
});

test("a block that is never closed is refused, even when its lines are the file's", () => {
  assert.equal(
    docShowsBlock(SHOWN, doc("```js", "const a = 1;", "", "console.log(a);"), FILE),
    `${HEAD}line 4 of the closest block reads '(docs/page.md ends)', examples/q.mjs's reads '(examples/q.mjs ends)'`,
  );
});

test("of several blocks, the one that agrees for the most lines is named", () => {
  const near = ["```js", "const a = 1;", "", "console.log(c);", "```"];
  const far = ["```js", "let x;", "```"];
  const want = `${HEAD}line 3 of the closest block reads 'console.log(c);', examples/q.mjs's reads 'console.log(a);'`;
  assert.equal(docShowsBlock(SHOWN, doc(...far, ...near, ...far), FILE), want);
  assert.equal(docShowsBlock(SHOWN, doc(...near, ...far), FILE), want);
});

test("a document with no line that is exactly the fence is refused: none, another fence, CRLF line ends", () => {
  const none = `${HEAD}docs/page.md has no line that is exactly \`\`\`js`;
  assert.equal(docShowsBlock(SHOWN, "", FILE), none);
  assert.equal(docShowsBlock(SHOWN, doc("```javascript", "const a = 1;", "", "console.log(a);", "```"), FILE), none);
  assert.equal(docShowsBlock(SHOWN, "```js\r\nconst a = 1;\r\n\r\nconsole.log(a);\r\n```\r\n", FILE), none);
});

test("a file that does not end with a line feed is refused, an empty one included", () => {
  const want = `${HEAD}examples/q.mjs does not end with a line feed`;
  assert.equal(docShowsBlock(SHOWN, doc("```js", "x", "```"), "x"), want);
  assert.equal(docShowsBlock(SHOWN, doc("```js", "```"), ""), want);
});

test("a file of one empty line is a block of one empty line, not an empty block", () => {
  assert.equal(docShowsBlock(SHOWN, doc("```js", "", "```"), "\n"), null);
  assert.equal(
    docShowsBlock(SHOWN, doc("```js", "```"), "\n"),
    `${HEAD}line 1 of the closest block reads '(the block ends)', examples/q.mjs's reads ''`,
  );
});

test("fencedBlocks: each block's lines and whether it is closed, a fence inside a block being one of its lines", () => {
  assert.deepEqual(fencedBlocks(doc("```sh", "a", "```", "text", "```sh", "```js", "b", "```", "```sh", "c"), "sh"), [
    { lines: ["a"], closed: true },
    { lines: ["```js", "b"], closed: true },
    { lines: ["c"], closed: false },
  ]);
  assert.deepEqual(fencedBlocks(doc("no fence"), "sh"), []);
});

test("fill puts in each value wherever its placeholder stands, and leaves the others as written", () => {
  assert.equal(
    fill("<version>\n<abi_version> <cwd>/x <version>\n", { version: "0.1.9", abi_version: "1009" }),
    "0.1.9\n1009 <cwd>/x 0.1.9\n",
  );
  assert.equal(fill("<cwd>", {}), "<cwd>");
});

test("abiVersionOf reads major * 1000 + minor from the table's first line, and refuses any other first line", () => {
  assert.equal(abiVersionOf("t.tsv", "version\t1.9\nfn\tkomira_abi_version\n"), 1009);
  assert.equal(abiVersionOf("t.tsv", "version\t2.123"), 2123);
  for (const first of ["", "version 1.9", "version\t1", "version\t1.x", "version\t1.9\textra", "release\t1.9", "version\t1.1000"]) {
    assert.throws(
      () => abiVersionOf("t.tsv", `${first}\nmore\n`),
      new Error(`the first line of t.tsv is '${first}', not \`version<TAB><major>.<minor>\``),
    );
  }
});
