// The errors the package raises on purpose (docs/design/typescript_package.md,
// "Errors a user can act on"). Every one is a KomiraError, so `instanceof
// KomiraError` catches komira's errors and nothing else. A wrong argument is
// JavaScript's own TypeError or RangeError instead, raised before the library
// is called. The private Arrow import (arrow_import.mts) raises
// UnsupportedOperation for a format it does not map. `errorClass` and
// `stepOf` are how an engine refusal's code and step pick its class, as the
// Python package's error table does (python/komira/_errors.py).

/** The step of a query an engine error came from. */
export type Step = "parse" | "bind" | "optimize" | "lower" | "execute";

/** The fields a KomiraError carries beside its message; each defaults to null. */
export interface KomiraErrorFields {
  readonly status?: number | null;
  readonly code?: string | null;
  readonly step?: Step | null;
}

/**
 * An error from libkomira or from the package's own state.
 *
 * `status` is the status number of the C call that failed (negative; -3 when
 * the engine refused), or null when no call returned one. `code` is the named
 * code of the refusal (`SQL_SYNTAX_ERROR`, `LOWERING_WINDOW_UNSERVED`, ...)
 * and `step` the step of the query that refused: "parse", "bind", "optimize",
 * "lower" or "execute". Each is null when the library gave none: the refusal
 * has none, the library is older than ABI 1.7, or no library call failed;
 * `code` is never the empty string. The message is the engine's text,
 * unchanged, when the library gave one.
 */
export class KomiraError extends Error {
  readonly status: number | null;
  readonly code: string | null;
  readonly step: Step | null;

  constructor(message: string, fields: KomiraErrorFields = {}) {
    super(message);
    this.name = new.target.name;
    this.status = fields.status ?? null;
    this.code = fields.code ?? null;
    this.step = fields.step ?? null;
  }
}

/**
 * libkomira cannot be loaded: there is no platform package for this platform,
 * or it is not installed; the Node addon or the library cannot be opened (the
 * message is the loader's, naming the file); the library's ABI major version
 * is not the one this package was written for, or it lacks a function the
 * addon calls; or the variant manifest of the native directory is damaged.
 */
export class LibraryLoadError extends KomiraError {}

/**
 * The CPU lacks an instruction set extension libkomira was compiled to use,
 * so the library is not opened. The message names the missing features.
 */
export class UnsupportedCpuError extends LibraryLoadError {}

/**
 * komira refused a construct by name: the message names it and says why, and
 * names a call that works if there is one.
 */
export class UnsupportedOperation extends KomiraError {}

/**
 * The steps komira_last_error_step answers, by their KOMIRA_STEP_* number
 * (src/so/abi/komira.tsv); 0, KOMIRA_STEP_NONE, is no step.
 */
const STEPS: readonly (Step | null)[] = [null, "parse", "bind", "optimize", "lower", "execute"];

/** The step of a KOMIRA_STEP_* number: null for none, and for a number this package does not know. */
export function stepOf(n: unknown): Step | null {
  return typeof n === "number" ? (STEPS[n] ?? null) : null;
}

/**
 * The codes of the error table (docs/design/credentials_and_writes.md,
 * section 11) whose class is UnsupportedOperation. The table's other classes
 * (Python's ParseError, BindError, MemoryLimitError, CredentialsError and
 * StorageError) are not names of this package, so their codes are a
 * KomiraError that carries the code.
 */
const UNSUPPORTED_CODES: ReadonlySet<string> = new Set([
  "SQL_NOT_SUPPORTED",
  "STATEMENT_NOT_A_QUERY",
  "OPTIMIZE_UNRESOLVED_SCALAR",
  "LOWERING_UNCUTTABLE_NODE",
  "LOWERING_SCAN_NOT_TOTAL",
  "LOWERING_SINK_UNSERVED",
  "LOWERING_JOIN_UNSERVED",
  "LOWERING_WINDOW_UNSERVED",
  "LOWERING_UDF_UNSERVED",
  "SQL_STATEMENT_UNSUPPORTED",
  "COPY_OPTION_UNSUPPORTED",
  "COPY_FORMAT_NOT_INFERRED",
  "STORAGE_URL_REFUSED",
  "STORAGE_RANGE_NOT_SUPPORTED",
  "STORAGE_WRITE_UNSUPPORTED",
  "PLAN_URL_QUERY_REFUSED",
]);

/** The status of an engine refusal, KOMIRA_ERR_ENGINE: the only status the table classifies. */
const ENGINE_REFUSAL = -3;

/**
 * The class of the error of a C call that returned `status`, with the
 * engine's `code` (null for none): UnsupportedOperation for an engine
 * refusal whose code the table gives that class, else KomiraError.
 */
export function errorClass(status: number, code: string | null): typeof KomiraError {
  return status === ENGINE_REFUSAL && code !== null && UNSUPPORTED_CODES.has(code) ? UnsupportedOperation : KomiraError;
}
