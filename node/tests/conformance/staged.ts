// What the SQL conformance tests share: where node/BUCK (:sql_conformance_test)
// stages the corpus, its tables, the lists and the engine, and a run of one
// corpus on a session of the real engine.
//
// The staged directory is the package's (tests/helpers.ts), and beside it
//   komira_addon.node             the addon
//   libkomira/                    libkomira with its runtime (src/so:libkomira[runnable])
//   conformance/cases/<corpus>/   the corpus (komira_sql_conformance:cases_tree)
//   conformance/tables/<corpus>/  its tables, <table>.parquet (:<corpus>_tables)
//   conformance/refusals.tsv      the lists every runner reads
//   conformance/differences.tsv
//   conformance/wrong_answer/     the fixture corpus with one wrong answer, and
//   conformance/wrong_answer_tables/   its table (node/BUCK, :conformance_wrong_answer_tables)

import path from "node:path";

import { loadFrom, setHost } from "../../src/native.ts";
import { Session } from "../../src/session.ts";
import { LINUX_X64, ROOT } from "../helpers.ts";
import { runCorpus, type Corpus, type Lists, type Report } from "./corpus.ts";

/** The staged conformance directory. */
export const CONFORMANCE = path.join(ROOT, "conformance");

/** Loads the addon and the real libkomira, on the host of the staged x86-64-v3 cpuinfo. */
export function loadEngine(): void {
  setHost(LINUX_X64);
  loadFrom(path.join(ROOT, "komira_addon.node"), path.join(ROOT, "libkomira"), LINUX_X64);
}

/** Runs `corpus` on a new session of the real engine into `report`, the session closed after. */
export async function runOnEngine(corpus: Corpus, lists: Lists, report: Report): Promise<void> {
  const session = new Session();
  try {
    await runCorpus(session, corpus, lists, report);
  } finally {
    await session[Symbol.asyncDispose]();
  }
}
