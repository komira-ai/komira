// Every case of src/tests/conformance/komira_sql_conformance run on the real
// engine through Session.sql (docs/design/typescript_package.md, "SQL
// conformance, reused"): each corpus's tables registered from the Parquet the
// pinned DuckDB wrote, each answer written as the corpus writes DuckDB's and
// compared byte for byte, and each case that does not answer as DuckDB held
// to its line in refusals.tsv or differences.tsv, the lists the corpus's
// runners share. A failure lists every problem and the lines to add to or
// remove from the lists.

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { test } from "node:test";

import { DIFFERENCES, REFUSALS, assertHeld, newReport, parseList, readCorpus, strayLines, type Lists } from "./corpus.ts";
import { CONFORMANCE, loadEngine, runOnEngine } from "./staged.ts";

loadEngine();

/** The corpus's case count (its README, "The corpora"): a corpus staged in part is a failure, not a smaller run. */
const CASES = 6420;
const CORPORA = 89;

test("every corpus case answers as DuckDB, or is refused or differs as the lists say", async () => {
  const cases = path.join(CONFORMANCE, "cases");
  const lists: Lists = {
    refusals: parseList(REFUSALS, readFileSync(path.join(CONFORMANCE, REFUSALS), "utf8")),
    differences: parseList(DIFFERENCES, readFileSync(path.join(CONFORMANCE, DIFFERENCES), "utf8")),
  };
  const corpora = readdirSync(cases).sort();
  const report = newReport();
  for (const c of corpora) {
    await runOnEngine(readCorpus(c, path.join(cases, c), path.join(CONFORMANCE, "tables", c)), lists, report);
  }
  strayLines(lists, corpora, report);
  assertHeld(report);
  assert.equal(corpora.length, CORPORA);
  assert.equal(report.answered.length + report.refused.length + report.differs.length, CASES);
});
