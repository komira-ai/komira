// The runner's negative case (docs/design/typescript_package.md, "SQL
// conformance, reused"): the fixture corpus fixtures/wrong_answer, run on the
// real engine, holds two answers DuckDB gives and one committed answer wrong
// in one cell, the d of k = 2 in wrong.tsv. The run must fail on that case
// alone, saying the line differences.tsv would need.

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";

import { assertHeld, newReport, readCorpus, type Lists } from "./corpus.ts";
import { CONFORMANCE, loadEngine, runOnEngine } from "./staged.ts";

loadEngine();

/** The fixture corpus, read as the run reads a corpus of the conformance package. */
function fixture() {
  return readCorpus("wrong_answer", path.join(CONFORMANCE, "wrong_answer"), path.join(CONFORMANCE, "wrong_answer_tables"));
}

/** How the engine's answer to wrong.sql differs from the committed one. */
const DIFFERENCE = 'line 3: got "2\\t-2.25", want "2\\t-2.5"';

test("a corpus with one wrong committed answer fails the run, naming that case alone", async () => {
  const report = newReport();
  await runOnEngine(fixture(), { refusals: new Map(), differences: new Map() }, report);
  assert.deepEqual(report, {
    answered: ["wrong_answer/multiset", "wrong_answer/ordered"],
    refused: [],
    differs: [],
    problems: [`wrong_answer/wrong: the answer differs from DuckDB's: ${DIFFERENCE}; no list holds it`],
    changes: [{ file: "differences.tsv", op: "+", line: `wrong_answer/wrong\t${DIFFERENCE}` }],
  });
  assert.throws(() => assertHeld(report), {
    name: "CorpusError",
    message: [
      "1 problem(s):",
      `wrong_answer/wrong: the answer differs from DuckDB's: ${DIFFERENCE}; no list holds it`,
      "1 change(s) to the lists:",
      `differences.tsv: + wrong_answer/wrong\t${DIFFERENCE}`,
    ].join("\n"),
  });
});

test("the same corpus with that difference listed is held, and the case counted as differing", async () => {
  const report = newReport();
  const lists: Lists = { refusals: new Map(), differences: new Map([["wrong_answer/wrong", DIFFERENCE]]) };
  await runOnEngine(fixture(), lists, report);
  assert.deepEqual(report.differs, ["wrong_answer/wrong"]);
  assert.doesNotThrow(() => assertHeld(report));
});
