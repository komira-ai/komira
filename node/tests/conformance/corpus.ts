// The SQL conformance corpus run through Session.sql
// (docs/design/typescript_package.md, "SQL conformance, reused").
//
// A corpus is a directory of src/tests/conformance/komira_sql_conformance's
// cases/<corpus>/: each case's <case>.sql (its row order line, comment lines,
// one SELECT) beside DuckDB's committed answer <case>.tsv. Its tables are the
// Parquet files the pinned DuckDB wrote from its tables.sql (that package's
// :<corpus>_tables), one <table>.parquet each, registered under <table>:
// nothing here runs CREATE TABLE.
//
// Each case's query runs through `sql`, and its answer is written as the
// corpus writes DuckDB's (render.ts) and compared with the committed text,
// header included, byte for byte. Two lists beside the corpus, which every
// runner of it reads, say which cases do not answer as DuckDB does:
//
//   refusals.tsv     a case komira refuses by name, with the refusal word for
//                    word (the message `sql` rejects with)
//   differences.tsv  a case komira answers otherwise, with how its answer
//                    differs (`difference`)
//
// A case is held to exactly one of: DuckDB's answer, its listed refusal, its
// listed difference. A case that does otherwise, a listed case that answers
// as DuckDB, and a listed case that is no case are each a problem, which
// names its case and says the line to add to or remove from a list. Every
// case is run: one wrong answer is one problem.

import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

import type { Table } from "apache-arrow";

import { answerText, type RowOrder } from "./render.ts";

/** A corpus or a list read wrongly: a case with no answer, a file that is no case, a malformed line. */
export class CorpusError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CorpusError";
  }
}

/** One case: its name within its corpus, its row order, the query komira runs, DuckDB's answer. */
export interface SqlCase {
  readonly name: string;
  readonly order: RowOrder;
  readonly query: string;
  readonly answer: string;
}

/** A table of a corpus: the name a case reads it by, and its Parquet file. */
export interface CorpusTable {
  readonly name: string;
  readonly file: string;
}

/** A corpus: its name, its cases in name order, and its tables. */
export interface Corpus {
  readonly name: string;
  readonly cases: readonly SqlCase[];
  readonly tables: readonly CorpusTable[];
}

/** The order lines a case may start with (README.md, "A case"). */
const ORDER_LINES: ReadonlyMap<string, RowOrder> = new Map([
  ["-- order: query", "query"],
  ["-- order: rows", "rows"],
]);

/**
 * The row order and query of the case `name` from its file's text: the first
 * line names the order; every comment line and blank line is dropped and the
 * others are trimmed and joined with a space, so the query is one line, as
 * sql_e2e's corpus reader makes it (src/tests/e2e/sql_e2e/corpus.mojo), and a
 * refusal at a position reads `line 1`.
 */
export function parseCase(name: string, text: string): { order: RowOrder; query: string } {
  const lines = text.split("\n");
  const order = ORDER_LINES.get(lines[0]!);
  if (order === undefined) {
    throw new CorpusError(`${name}: the first line must be "-- order: query" or "-- order: rows"`);
  }
  const query = lines
    .map((l) => l.trim())
    .filter((l) => l !== "" && !l.startsWith("--"))
    .join(" ");
  if (query === "") {
    throw new CorpusError(`${name}: no query after the comment lines`);
  }
  return { order, query };
}

/** The names in `files` ending in `suffix`, without it, sorted. */
function stems(files: readonly string[], suffix: string): string[] {
  return files
    .filter((f) => f.endsWith(suffix))
    .map((f) => f.slice(0, -suffix.length))
    .sort();
}

/**
 * The corpus `name`: its cases from `casesDir` (`<case>.sql` with
 * `<case>.tsv`, and tables.sql, which a runner does not read) and its tables
 * from `tablesDir` (`<table>.parquet`). A case with no answer, an answer with
 * no case, any other file, and a corpus with no case or no table are
 * refused, every such problem in one CorpusError.
 */
export function readCorpus(name: string, casesDir: string, tablesDir: string): Corpus {
  const files = readdirSync(casesDir).sort();
  const sqls = stems(files, ".sql").filter((s) => s !== "tables");
  const tsvs = stems(files, ".tsv");
  const problems: string[] = [];
  for (const f of files) {
    if (!f.endsWith(".sql") && !f.endsWith(".tsv")) {
      problems.push(`${name}/${f}: not a case (<case>.sql), an answer (<case>.tsv) or tables.sql`);
    }
  }
  for (const s of sqls) {
    if (!tsvs.includes(s)) {
      problems.push(`${name}/${s}: a case with no answer (${s}.tsv)`);
    }
  }
  for (const t of tsvs) {
    if (!sqls.includes(t)) {
      problems.push(`${name}/${t}: an answer with no case (${t}.sql)`);
    }
  }
  if (sqls.length === 0) {
    problems.push(`${name}: no case in ${casesDir}`);
  }
  const tables = stems(readdirSync(tablesDir), ".parquet").map((t) => ({
    name: t,
    file: path.join(tablesDir, `${t}.parquet`),
  }));
  if (tables.length === 0) {
    problems.push(`${name}: no <table>.parquet in ${tablesDir}`);
  }
  if (problems.length > 0) {
    throw new CorpusError(problems.join("\n"));
  }
  const cases = sqls.map((s) => {
    const { order, query } = parseCase(`${name}/${s}`, readFileSync(path.join(casesDir, `${s}.sql`), "utf8"));
    return { name: s, order, query, answer: readFileSync(path.join(casesDir, `${s}.tsv`), "utf8") };
  });
  return { name, cases, tables };
}

/** The two lists: a case's refusal, and how a case's answer differs, by `<corpus>/<case>`. */
export interface Lists {
  readonly refusals: ReadonlyMap<string, string>;
  readonly differences: ReadonlyMap<string, string>;
}

/** The lists' file names, as a problem names them. */
export const REFUSALS = "refusals.tsv";
export const DIFFERENCES = "differences.tsv";

/**
 * A list's lines (`file` names it in an error): `#` comment lines, then one
 * line per case, `<corpus>/<case>` TAB the text it holds, each line ending in
 * LF. A line of another shape, a case listed twice, and a last line with no
 * LF are refused, every one in one CorpusError.
 */
export function parseList(file: string, text: string): Map<string, string> {
  const out = new Map<string, string>();
  const problems: string[] = [];
  if (text !== "" && !text.endsWith("\n")) {
    problems.push(`${file}: the last line does not end in LF`);
  }
  // The text after the last LF is no line.
  text
    .split("\n")
    .slice(0, -1)
    .forEach((line, i) => {
      if (line.startsWith("#")) {
        return;
      }
      const tab = line.indexOf("\t");
      const key = tab < 0 ? line : line.slice(0, tab);
      const value = tab < 0 ? "" : line.slice(tab + 1);
      if (!/^[A-Za-z0-9_]+\/[A-Za-z0-9_]+$/.test(key) || value === "") {
        problems.push(`${file} line ${i + 1}: not "<corpus>/<case>" TAB a non-empty text`);
      } else if (out.has(key)) {
        problems.push(`${file} line ${i + 1}: ${key} is listed twice`);
      } else {
        out.set(key, value);
      }
    });
  if (problems.length > 0) {
    throw new CorpusError(problems.join("\n"));
  }
  return out;
}

/**
 * How the answer `got` differs from DuckDB's `want`, or null when the texts
 * are equal byte for byte. The header line and the rows are compared apart,
 * so a column named otherwise does not hide a wrong value: `header: got
 * "<line>", want "<line>"` when the headers differ, `line <n>: got "<line>",
 * want "<line>"` at the first row line that differs (`no line` past the end
 * of one text; the final LF counts), and both, joined by `; `. A line is
 * shown as a JSON string, so the text holds no TAB or LF of its own.
 */
export function difference(got: string, want: string): string | null {
  if (got === want) {
    return null;
  }
  const g = got.split("\n");
  const w = want.split("\n");
  const show = (l: string[], n: number) => (n < l.length ? JSON.stringify(l[n]) : "no line");
  const parts: string[] = [];
  if (g[0] !== w[0]) {
    parts.push(`header: got ${show(g, 0)}, want ${show(w, 0)}`);
  }
  let n = 1;
  while (n < g.length && n < w.length && g[n] === w[n]) {
    n++;
  }
  if (n < g.length || n < w.length) {
    parts.push(`line ${n + 1}: got ${show(g, n)}, want ${show(w, n)}`);
  }
  return parts.join("; ");
}

/** What `sql` resolves with: the part of a Result this runner reads. */
export interface Answer {
  toArrow(): Promise<Table>;
}

/** The part of a Session this runner uses. */
export interface SqlSession {
  registerParquet(name: string, file: string): Promise<void>;
  sql(query: string): Promise<Answer>;
}

/** A line a list must gain (`+`) or lose (`-`) to hold what a run measured. */
export interface Change {
  readonly file: typeof REFUSALS | typeof DIFFERENCES;
  readonly op: "+" | "-";
  readonly line: string;
}

/** What a run did: the cases answered as DuckDB, refused as listed, differing as listed, and every problem. */
export interface Report {
  readonly answered: string[];
  readonly refused: string[];
  readonly differs: string[];
  readonly problems: string[];
  readonly changes: Change[];
}

/** An empty report. */
export function newReport(): Report {
  return { answered: [], refused: [], differs: [], problems: [], changes: [] };
}

/** The message of a thrown value. */
function messageOf(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** The status of an engine refusal, KOMIRA_ERR_ENGINE. */
const ENGINE_REFUSAL = -3;

/**
 * Whether `e` is the engine refusing a query: an error carrying status -3,
 * as every KomiraError the engine's refusal becomes does. Another status (a
 * call that failed otherwise), a TypeError, an error of the package's own
 * state (status null) and anything else is the run failing, never a refusal.
 */
function isRefusal(e: unknown): e is Error {
  return e instanceof Error && (e as { status?: unknown }).status === ENGINE_REFUSAL;
}

/** What a case did: the line a list holds for it (none when it answers as DuckDB), and how to say so. */
interface Outcome {
  readonly line: { readonly file: Change["file"]; readonly text: string } | null;
  readonly what: string;
}

/**
 * Records in `report` how the outcome of the case `key` stands against its
 * lines in `lists`: held when the lists hold exactly the outcome's line (no
 * line for a case answered as DuckDB), else a problem saying what the case
 * did and what the lists hold, with the changes that make them hold it.
 */
function judge(report: Report, key: string, outcome: Outcome, lists: Lists): void {
  const listed: { file: Change["file"]; text: string }[] = [];
  for (const [file, list] of [
    [REFUSALS, lists.refusals],
    [DIFFERENCES, lists.differences],
  ] as const) {
    const text = list.get(key);
    if (text !== undefined) {
      listed.push({ file, text });
    }
  }
  const m = outcome.line;
  const same = (l: { file: string; text: string }) => m !== null && l.file === m.file && l.text === m.text;
  if (listed.length === (m === null ? 0 : 1) && listed.every(same)) {
    (m === null ? report.answered : m.file === REFUSALS ? report.refused : report.differs).push(key);
    return;
  }
  const holds = listed.length === 0 ? "no list holds it" : listed.map((l) => `${l.file} lists ${JSON.stringify(l.text)}`).join(", ");
  report.problems.push(`${key}: ${outcome.what}; ${holds}`);
  for (const l of listed) {
    if (!same(l)) {
      report.changes.push({ file: l.file, op: "-", line: `${key}\t${l.text}` });
    }
  }
  if (m !== null && !listed.some(same)) {
    report.changes.push({ file: m.file, op: "+", line: `${key}\t${m.text}` });
  }
}

/**
 * Runs every case of `corpus` on `session`, its tables registered first, and
 * holds each to DuckDB's answer or to its line in `lists`, into `report`.
 * A list line of this corpus that names none of its cases is a problem too.
 * An error that is no refusal (`isRefusal`), and an answer the renderer cannot
 * write, are problems that change no list; so is a table that cannot be
 * registered, after which none of the corpus's cases runs.
 */
export async function runCorpus(session: SqlSession, corpus: Corpus, lists: Lists, report: Report): Promise<void> {
  for (const t of corpus.tables) {
    try {
      await session.registerParquet(t.name, t.file);
    } catch (e) {
      // No case of the corpus can run as its corpus says; the other corpora still run.
      report.problems.push(`${corpus.name}: the table ${t.name} cannot be registered, so no case of the corpus ran: ${messageOf(e)}`);
      return;
    }
  }
  const names = new Set(corpus.cases.map((c) => `${corpus.name}/${c.name}`));
  for (const [file, list] of [
    [REFUSALS, lists.refusals],
    [DIFFERENCES, lists.differences],
  ] as const) {
    for (const [key, text] of list) {
      if (key.startsWith(`${corpus.name}/`) && !names.has(key)) {
        report.problems.push(`${key}: listed in ${file}, and the corpus has no such case`);
        report.changes.push({ file, op: "-", line: `${key}\t${text}` });
      }
    }
  }
  for (const c of corpus.cases) {
    const key = `${corpus.name}/${c.name}`;
    let table: Table;
    try {
      table = await (await session.sql(c.query)).toArrow();
    } catch (e) {
      if (isRefusal(e)) {
        judge(report, key, { line: { file: REFUSALS, text: e.message }, what: `refused: ${e.message}` }, lists);
      } else {
        report.problems.push(`${key}: the run failed: ${messageOf(e)}`);
      }
      continue;
    }
    let got: string;
    try {
      got = answerText(table, c.order);
    } catch (e) {
      report.problems.push(`${key}: the answer cannot be written: ${messageOf(e)}`);
      continue;
    }
    const d = difference(got, c.answer);
    judge(
      report,
      key,
      d === null
        ? { line: null, what: "answered as DuckDB" }
        : { line: { file: DIFFERENCES, text: d }, what: `the answer differs from DuckDB's: ${d}` },
      lists,
    );
  }
}

/**
 * The problems of list lines naming a corpus that is not one of `corpora`
 * (whose cases no run reads, so no run would see the line go stale), with
 * their changes, into `report`.
 */
export function strayLines(lists: Lists, corpora: readonly string[], report: Report): void {
  for (const [file, list] of [
    [REFUSALS, lists.refusals],
    [DIFFERENCES, lists.differences],
  ] as const) {
    for (const [key, text] of list) {
      const corpus = key.slice(0, key.indexOf("/"));
      if (!corpora.includes(corpus)) {
        report.problems.push(`${key}: listed in ${file}, and there is no corpus ${corpus}`);
        report.changes.push({ file, op: "-", line: `${key}\t${text}` });
      }
    }
  }
}

/**
 * Throws unless `report` holds no problem: the AssertionError-like message
 * names every problem, then every change to the lists that would make them
 * hold this run, one per line (`<file>: + <line>` or `<file>: - <line>`),
 * which is what to apply to the lists after a change to the engine.
 */
export function assertHeld(report: Report): void {
  if (report.problems.length === 0) {
    return;
  }
  const changes = report.changes.map((c) => `${c.file}: ${c.op} ${c.line}`);
  throw new CorpusError(
    [`${report.problems.length} problem(s):`, ...report.problems, `${changes.length} change(s) to the lists:`, ...changes].join("\n"),
  );
}
