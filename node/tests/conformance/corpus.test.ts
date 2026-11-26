// corpus.ts: the corpus reader, the lists and the runner, fed a stand-in
// session whose answers and refusals each test picks. The real engine's run
// of a corpus is wrong_answer.test.ts and sql_conformance.test.ts.

import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { Float16, Int32, Table, Utf8, makeData, makeVector, vectorFromArray } from "apache-arrow";

import { KomiraError, UnsupportedOperation } from "../../src/errors.ts";
import { scratch } from "../helpers.ts";
import {
  CorpusError,
  assertHeld,
  difference,
  newReport,
  parseCase,
  parseList,
  readCorpus,
  runCorpus,
  strayLines,
  type Corpus,
  type Lists,
  type SqlSession,
} from "./corpus.ts";

/** The message of the CorpusError `f` throws. */
function corpusError(f: () => unknown): string {
  try {
    f();
  } catch (e) {
    assert.ok(e instanceof CorpusError, String(e));
    return e.message;
  }
  assert.fail("nothing was refused; a CorpusError was expected");
}

/** A directory of `files` ({name: text}) under a new scratch directory. */
function dirOf(files: Record<string, string>): string {
  const dir = path.join(scratch(), "d");
  mkdirSync(dir);
  for (const [name, text] of Object.entries(files)) {
    writeFileSync(path.join(dir, name), text);
  }
  return dir;
}

test("a case's first line names its row order, and its query is every other line but comments, joined", () => {
  assert.deepEqual(parseCase("c/a", "-- order: query\n-- a comment\nSELECT k\n  FROM t   \n\n  -- indented\nORDER BY k\n"), {
    order: "query",
    query: "SELECT k FROM t ORDER BY k",
  });
  assert.deepEqual(parseCase("c/b", "-- order: rows\nSELECT 1"), { order: "rows", query: "SELECT 1" });
  // The comment marker inside a literal is the query's, not a comment line.
  assert.equal(parseCase("c/l", "-- order: rows\nSELECT 'x -- y' AS s\n").query, "SELECT 'x -- y' AS s");
});

test("a case whose first line names no row order, or with no query, is refused by name", () => {
  assert.equal(corpusError(() => parseCase("c/a", "SELECT 1\n")), 'c/a: the first line must be "-- order: query" or "-- order: rows"');
  assert.equal(corpusError(() => parseCase("c/a", "-- order: rows \nSELECT 1\n")), 'c/a: the first line must be "-- order: query" or "-- order: rows"');
  assert.equal(corpusError(() => parseCase("c/b", "-- order: query\n-- only comments\n\n")), "c/b: no query after the comment lines");
});

test("a corpus is its cases in name order with their answers, and its tables by file name", () => {
  const cases = dirOf({
    "b.sql": "-- order: rows\nSELECT 2\n",
    "b.tsv": "2\n2\n",
    "a.sql": "-- order: query\nSELECT 1\n",
    "a.tsv": "1\n1\n",
    "tables.sql": "CREATE TABLE T (k BIGINT);\n",
  });
  const tables = dirOf({ "T.parquet": "", "U.parquet": "" });
  const corpus = readCorpus("c", cases, tables);
  assert.equal(corpus.name, "c");
  assert.deepEqual(corpus.cases, [
    { name: "a", order: "query", query: "SELECT 1", answer: "1\n1\n" },
    { name: "b", order: "rows", query: "SELECT 2", answer: "2\n2\n" },
  ]);
  assert.deepEqual(corpus.tables, [
    { name: "T", file: path.join(tables, "T.parquet") },
    { name: "U", file: path.join(tables, "U.parquet") },
  ]);
});

test("a case with no answer, an answer with no case, another file and a missing table are each refused", () => {
  const cases = dirOf({ "a.sql": "-- order: rows\nSELECT 1\n", "b.tsv": "x\n", "notes.txt": "" });
  const tables = dirOf({ "readme.md": "" });
  assert.equal(
    corpusError(() => readCorpus("c", cases, tables)),
    [
      "c/notes.txt: not a case (<case>.sql), an answer (<case>.tsv) or tables.sql",
      "c/a: a case with no answer (a.tsv)",
      "c/b: an answer with no case (b.sql)",
      `c: no <table>.parquet in ${tables}`,
    ].join("\n"),
  );
  const none = dirOf({ "tables.sql": "" });
  assert.equal(corpusError(() => readCorpus("c", none, dirOf({ "T.parquet": "" }))), `c: no case in ${none}`);
});

test("a list is <corpus>/<case> TAB its text per line, comments aside", () => {
  assert.deepEqual(parseList("refusals.tsv", ""), new Map());
  assert.deepEqual(
    parseList("refusals.tsv", "# a comment\nc/a\tparse: no\n# another\nc2/b_1\tbind: x\ty\n"),
    new Map([
      ["c/a", "parse: no"],
      ["c2/b_1", "bind: x\ty"],
    ]),
  );
});

test("a list line of another shape, a case listed twice and a last line with no LF are refused", () => {
  assert.equal(
    corpusError(() => parseList("differences.tsv", "c/a\tx\nc/a\ty\nno tab\nc/b\t\nc a\tx\n\nc/z\tz")),
    [
      "differences.tsv: the last line does not end in LF",
      "differences.tsv line 2: c/a is listed twice",
      'differences.tsv line 3: not "<corpus>/<case>" TAB a non-empty text',
      'differences.tsv line 4: not "<corpus>/<case>" TAB a non-empty text',
      'differences.tsv line 5: not "<corpus>/<case>" TAB a non-empty text',
      'differences.tsv line 6: not "<corpus>/<case>" TAB a non-empty text',
    ].join("\n"),
  );
});

test("a difference names the header and the first row line that differ, apart", () => {
  assert.equal(difference("k\n1\n", "k\n1\n"), null);
  assert.equal(difference("k\texpr\n1\t2\n", "k\t(a + 1)\n1\t2\n"), 'header: got "k\\texpr", want "k\\t(a + 1)"');
  assert.equal(difference("k\n1\n3\n", "k\n1\n2\n"), 'line 3: got "3", want "2"');
  assert.equal(difference("x\n1\n", "k\n2\n"), 'header: got "x", want "k"; line 2: got "1", want "2"');
  assert.equal(difference("k\n1\n", "k\n1\n2\n"), 'line 3: got "", want "2"');
  assert.equal(difference("k\n1\n\n", "k\n1\n"), 'line 4: got "", want no line');
  assert.equal(difference("k\n1", "k\n1\n"), 'line 3: got no line, want ""');
});

/** The one-column answer `k` holding `values`. */
function answer(values: number[]): Table {
  return new Table({ k: vectorFromArray(values, new Int32()) });
}

/** An engine refusal as the package raises it: status -3, the engine's code and step. */
function refusal(message: string): KomiraError {
  return new UnsupportedOperation(message, { status: -3, code: "SQL_NOT_SUPPORTED", step: "parse" });
}

/** A stand-in session: each query's answer or error, and the tables registered, in order. */
function session(behaviour: Record<string, Table | Error>): SqlSession & { registered: string[] } {
  const registered: string[] = [];
  return {
    registered,
    async registerParquet(name, file) {
      registered.push(`${name}=${file}`);
    },
    async sql(query) {
      const b = behaviour[query];
      if (b === undefined) {
        throw new Error(`the stand-in answers no query ${query}`);
      }
      if (b instanceof Error) {
        throw b;
      }
      return { toArrow: async () => b };
    },
  };
}

/** A corpus of `cases` ({name: query}), each answered `k\n1\n`, over the tables T and U. */
function corpusOf(cases: Record<string, string>): Corpus {
  return {
    name: "c",
    cases: Object.entries(cases).map(([name, query]) => ({ name, order: "query", query, answer: "k\n1\n" })),
    tables: [
      { name: "T", file: "/t/T.parquet" },
      { name: "U", file: "/t/U.parquet" },
    ],
  };
}

const NONE: Lists = { refusals: new Map(), differences: new Map() };
const WRONG = 'line 2: got "2", want "1"';

test("a case answered as DuckDB, refused as listed, or differing as listed is held, its tables registered first", async () => {
  const s = session({ q1: answer([1]), q2: refusal("parse: no"), q3: answer([2]) });
  const report = newReport();
  const lists: Lists = { refusals: new Map([["c/b", "parse: no"]]), differences: new Map([["c/c", WRONG]]) };
  await runCorpus(s, corpusOf({ a: "q1", b: "q2", c: "q3" }), lists, report);
  assert.deepEqual(s.registered, ["T=/t/T.parquet", "U=/t/U.parquet"]);
  assert.deepEqual(report, { answered: ["c/a"], refused: ["c/b"], differs: ["c/c"], problems: [], changes: [] });
  assert.doesNotThrow(() => assertHeld(report));
});

test("an outcome no list holds is a problem, with the line to add", async () => {
  const report = newReport();
  await runCorpus(session({ q1: refusal("bind: no"), q2: answer([2]) }), corpusOf({ a: "q1", b: "q2" }), NONE, report);
  assert.deepEqual(report.problems, [
    "c/a: refused: bind: no; no list holds it",
    `c/b: the answer differs from DuckDB's: ${WRONG}; no list holds it`,
  ]);
  assert.deepEqual(report.changes, [
    { file: "refusals.tsv", op: "+", line: "c/a\tbind: no" },
    { file: "differences.tsv", op: "+", line: `c/b\t${WRONG}` },
  ]);
});

test("a listed case that answers as DuckDB is a problem, with the line to remove", async () => {
  const report = newReport();
  const lists: Lists = { refusals: new Map([["c/a", "parse: no"]]), differences: new Map([["c/b", WRONG]]) };
  await runCorpus(session({ q: answer([1]) }), corpusOf({ a: "q", b: "q" }), lists, report);
  assert.deepEqual(report.problems, [
    'c/a: answered as DuckDB; refusals.tsv lists "parse: no"',
    `c/b: answered as DuckDB; differences.tsv lists ${JSON.stringify(WRONG)}`,
  ]);
  assert.deepEqual(report.changes, [
    { file: "refusals.tsv", op: "-", line: "c/a\tparse: no" },
    { file: "differences.tsv", op: "-", line: `c/b\t${WRONG}` },
  ]);
});

test("a case refused or differing otherwise than listed, or in the other list, is a problem with both changes", async () => {
  const report = newReport();
  const lists: Lists = {
    refusals: new Map([
      ["c/a", "parse: old"],
      ["c/c", "parse: no"],
      ["c/d", "parse: no"],
    ]),
    differences: new Map([
      ["c/b", 'line 2: got "3", want "1"'],
      ["c/d", WRONG],
      ["c/e", WRONG],
    ]),
  };
  const s = session({ refused: refusal("parse: no"), wrong: answer([2]) });
  await runCorpus(s, corpusOf({ a: "refused", b: "wrong", c: "wrong", d: "refused", e: "refused" }), lists, report);
  assert.deepEqual(report.problems, [
    'c/a: refused: parse: no; refusals.tsv lists "parse: old"',
    `c/b: the answer differs from DuckDB's: ${WRONG}; differences.tsv lists "line 2: got \\"3\\", want \\"1\\""`,
    `c/c: the answer differs from DuckDB's: ${WRONG}; refusals.tsv lists "parse: no"`,
    `c/d: refused: parse: no; refusals.tsv lists "parse: no", differences.tsv lists ${JSON.stringify(WRONG)}`,
    `c/e: refused: parse: no; differences.tsv lists ${JSON.stringify(WRONG)}`,
  ]);
  assert.deepEqual(report.changes, [
    { file: "refusals.tsv", op: "-", line: "c/a\tparse: old" },
    { file: "refusals.tsv", op: "+", line: "c/a\tparse: no" },
    { file: "differences.tsv", op: "-", line: 'c/b\tline 2: got "3", want "1"' },
    { file: "differences.tsv", op: "+", line: `c/b\t${WRONG}` },
    { file: "refusals.tsv", op: "-", line: "c/c\tparse: no" },
    { file: "differences.tsv", op: "+", line: `c/c\t${WRONG}` },
    { file: "differences.tsv", op: "-", line: `c/d\t${WRONG}` },
    { file: "differences.tsv", op: "-", line: `c/e\t${WRONG}` },
    { file: "refusals.tsv", op: "+", line: "c/e\tparse: no" },
  ]);
});

test("an error that is no engine refusal, and an answer that cannot be written, are problems that change no list", async () => {
  const report = newReport();
  const half = new Table({ h: makeVector(makeData({ type: new Float16(), length: 1, data: new Uint16Array([0]) })) });
  const s = session({
    state: new KomiraError("the result was already read"),
    type: new TypeError("not a function"),
    half,
  });
  await runCorpus(s, corpusOf({ a: "state", b: "type", c: "half" }), NONE, report);
  assert.deepEqual(report.problems, [
    "c/a: the run failed: the result was already read",
    "c/b: the run failed: not a function",
    'c/c: the answer cannot be written: column "h": no spelling for the Arrow type Float16',
  ]);
  assert.deepEqual(report.changes, []);
});

test("a thrown value that is not an Error is a run failure, by its text", async () => {
  const report = newReport();
  const s: SqlSession = {
    registerParquet: async () => {},
    sql: async () => {
      throw "a string";
    },
  };
  await runCorpus(s, corpusOf({ a: "q" }), NONE, report);
  assert.deepEqual(report.problems, ["c/a: the run failed: a string"]);
});

test("a list line naming no case of its corpus, or no corpus, is a problem with the line to remove", async () => {
  const report = newReport();
  const lists: Lists = {
    refusals: new Map([
      ["c/gone", "parse: no"],
      ["other/a", "parse: no"],
    ]),
    differences: new Map([
      ["c/also_gone", WRONG],
      ["lost/b", WRONG],
    ]),
  };
  await runCorpus(session({ q: answer([1]) }), corpusOf({ a: "q" }), lists, report);
  strayLines(lists, ["c", "other"], report);
  assert.deepEqual(report.problems, [
    "c/gone: listed in refusals.tsv, and the corpus has no such case",
    "c/also_gone: listed in differences.tsv, and the corpus has no such case",
    "lost/b: listed in differences.tsv, and there is no corpus lost",
  ]);
  assert.deepEqual(report.changes, [
    { file: "refusals.tsv", op: "-", line: "c/gone\tparse: no" },
    { file: "differences.tsv", op: "-", line: `c/also_gone\t${WRONG}` },
    { file: "differences.tsv", op: "-", line: `lost/b\t${WRONG}` },
  ]);
});

test("a report with a problem fails with every problem and every change to the lists", () => {
  const report = newReport();
  report.problems.push("c/a: refused: parse: no; no list holds it", "c/b: the run failed: x");
  report.changes.push({ file: "refusals.tsv", op: "+", line: "c/a\tparse: no" });
  assert.equal(
    corpusError(() => assertHeld(report)),
    [
      "2 problem(s):",
      "c/a: refused: parse: no; no list holds it",
      "c/b: the run failed: x",
      "1 change(s) to the lists:",
      "refusals.tsv: + c/a\tparse: no",
    ].join("\n"),
  );
});

test("order: rows sorts the answer before it is compared", async () => {
  const report = newReport();
  const corpus: Corpus = {
    name: "c",
    cases: [{ name: "a", order: "rows", query: "q", answer: "s\n\nx\ny\n" }],
    tables: [],
  };
  const t = new Table({ s: vectorFromArray(["y", null, "x"], new Utf8()) });
  await runCorpus(session({ q: t }), corpus, NONE, report);
  assert.deepEqual(report.answered, ["c/a"]);
});
