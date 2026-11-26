// Session: one engine context and its tables (docs/design/typescript_package.md,
// "Public names" and "Behaviour"), and the default session of this
// JavaScript environment.
//
// The calls that take a table or run a query are asynchronous, as the design
// fixes: they return promises, and every error, an argument's included, is a
// rejection.
// Arguments are checked before the library is called: a wrong type is a
// TypeError and a wrong value of the right type a RangeError. The addon runs
// each session's library calls in order on a native thread of the session's
// own, so the event loop never waits on the engine.

import path from "node:path";
import { fileURLToPath } from "node:url";

import { KomiraError, UnsupportedOperation } from "./errors.ts";
import { call, callAsync, load, type Handle, type Native } from "./native.ts";
import { resultOf, type Result } from "./result.ts";

/**
 * The options of a session, passed to `komira_ctx_new_with_options` as
 * arguments (never read from the environment) and fixed for the life of the
 * session. An option left out, or undefined, takes the engine's default.
 */
export interface SessionOptions {
  /** The engine's worker threads, a positive integer. */
  readonly threads?: number | undefined;
  /**
   * The bytes the operators of one query may hold in total, a positive
   * integer. A query that needs more is refused at the execute step with the
   * code `MEMORY_BUDGET_EXCEEDED`.
   */
  readonly memoryLimit?: number | undefined;
}

/** The options of a CSV file, those `komira_csv_binding` takes. */
export interface CsvOptions {
  /** The field delimiter, one ASCII character. */
  readonly delimiter?: string | undefined;
  /** Whether the first line names the columns. */
  readonly header?: boolean | undefined;
  /** Whether every column is read as VARCHAR. */
  readonly allVarchar?: boolean | undefined;
}

/** A file to register: a path, or a `file:` URL. */
export type FilePath = string | URL;

/** The keys of `value`, an options object or undefined, checked against `known`. */
function optionsOf(what: string, value: unknown, known: readonly string[]): Record<string, unknown> {
  if (value === undefined) {
    return {};
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new TypeError(`${what} must be an object`);
  }
  for (const key of Object.keys(value)) {
    if (!known.includes(key)) {
      throw new TypeError(`${what} has no option ${JSON.stringify(key)}; its options are ${known.join(", ")}`);
    }
  }
  return value as Record<string, unknown>;
}

/** A positive integer option that may be left out (undefined). */
function positiveInteger(name: string, value: unknown): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "number") {
    throw new TypeError(`${name} must be a number`);
  }
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new RangeError(`${name} must be a positive integer, not ${value}`);
  }
  return value;
}

/** Checks a boolean option that may be left out. */
function flag(name: string, value: unknown): void {
  if (value !== undefined && typeof value !== "boolean") {
    throw new TypeError(`${name} must be a boolean`);
  }
}

/** A table name: a non-empty string without a NUL byte, that UTF-8 can spell. */
function tableName(name: unknown): string {
  if (typeof name !== "string") {
    throw new TypeError("the table name must be a string");
  }
  if (name === "") {
    throw new RangeError("the table name is empty");
  }
  if (name.includes("\0")) {
    throw new RangeError("the table name holds a NUL byte");
  }
  if (!name.isWellFormed()) {
    throw new RangeError("the table name holds a lone surrogate, which UTF-8 cannot spell");
  }
  return name;
}

/**
 * The absolute path of a file argument, as Node's `fs` resolves it: a
 * relative path against the working directory when the call is made, and `~`
 * not expanded. A URL must be a `file:` URL of this host.
 */
function filePath(value: unknown): string {
  let p: string;
  if (typeof value === "string") {
    p = value;
  } else if (value instanceof URL) {
    if (value.protocol !== "file:") {
      throw new RangeError(`the path must be a file: URL, not a ${value.protocol} one`);
    }
    try {
      p = fileURLToPath(value);
    } catch (e) {
      throw new RangeError(`the path ${value.href} is not a file of this host: ${(e as Error).message}`);
    }
  } else {
    throw new TypeError("the path must be a string or a file: URL");
  }
  if (p === "") {
    throw new RangeError("the path is empty");
  }
  if (p.includes("\0")) {
    throw new RangeError("the path holds a NUL byte");
  }
  if (!p.isWellFormed()) {
    throw new RangeError("the path holds a lone surrogate, which UTF-8 cannot spell");
  }
  return path.resolve(p);
}

/** The SQL text of a query: a string without a NUL byte, that UTF-8 can spell. */
function queryText(query: unknown): string {
  if (typeof query !== "string") {
    throw new TypeError("the query must be a string");
  }
  if (query.includes("\0")) {
    throw new RangeError("the query holds a NUL byte");
  }
  if (!query.isWellFormed()) {
    throw new RangeError("the query holds a lone surrogate, which UTF-8 cannot spell");
  }
  return query;
}

/** The refusal of a registration this package does not bind yet. */
function noRegistration(method: string, what: string): UnsupportedOperation {
  return new UnsupportedOperation(
    `${method} is not supported yet: this package does not yet bind the call that registers ${what} by name; ` +
      `registerParquet registers a Parquet file`,
  );
}

/** One engine context (`komira_ctx_new`) and the tables registered on it. */
export class Session {
  #native: Native;
  #handle: Handle | null;
  /** The addon's free of the context, once `close` has asked for it. */
  #freed: Promise<void> | undefined;

  /**
   * A new session. An option of the wrong type or value throws TypeError or
   * RangeError before the library is loaded. Loads libkomira on the first
   * session or call of this environment, so it throws LibraryLoadError when
   * the library cannot be loaded. With an option, it throws KomiraError when
   * the library is older than ABI 1.4, which cannot take options, or when the
   * engine cannot start with them.
   */
  constructor(options?: SessionOptions) {
    const o = optionsOf("the session options", options, ["threads", "memoryLimit"]);
    const threads = positiveInteger("threads", o["threads"]);
    const memoryLimit = positiveInteger("memoryLimit", o["memoryLimit"]);
    this.#native = load();
    const native = this.#native;
    this.#handle = call(() => native.addon.newSession(threads, memoryLimit));
  }

  /** Whether `close` was called. */
  get closed(): boolean {
    return this.#handle === null;
  }

  /**
   * Refuses every later call at once, and frees the session's context once
   * the calls already made have run: never under a running call. Calling it
   * again does nothing.
   */
  close(): void {
    const handle = this.#handle;
    if (handle !== null) {
      this.#handle = null;
      this.#freed = this.#native.addon.freeSession(handle);
    }
  }

  /** The open session's handle, or the refusal of a closed one. */
  #open(): Handle {
    if (this.#handle === null) {
      throw new KomiraError("the session is closed");
    }
    return this.#handle;
  }

  /**
   * Registers the Parquet file at `path` (a string or a `file:` URL) as the
   * table `name`. A relative path is resolved against the working directory
   * now. Registering a name again replaces it. Rejects with a KomiraError
   * carrying the engine's status, code and message when the engine refuses.
   */
  async registerParquet(name: string, path: FilePath): Promise<void> {
    const table = tableName(name);
    const file = filePath(path);
    const handle = this.#open();
    const native = this.#native;
    await callAsync(() => native.addon.registerParquet(handle, table, file));
  }

  /**
   * Registers a CSV file as the table `name`. Not supported yet: its
   * arguments are checked, and it rejects with UnsupportedOperation.
   */
  async registerCsv(name: string, path: FilePath, options?: CsvOptions): Promise<void> {
    tableName(name);
    filePath(path);
    const o = optionsOf("the CSV options", options, ["delimiter", "header", "allVarchar"]);
    const delimiter = o["delimiter"];
    if (delimiter !== undefined) {
      if (typeof delimiter !== "string") {
        throw new TypeError("delimiter must be a string");
      }
      if (!/^[\x01-\x7f]$/.test(delimiter)) {
        throw new RangeError(`delimiter must be one ASCII character other than NUL, not ${JSON.stringify(delimiter)}`);
      }
    }
    flag("header", o["header"]);
    flag("allVarchar", o["allVarchar"]);
    this.#open();
    throw noRegistration("registerCsv", "a CSV file");
  }

  /**
   * Registers a newline-delimited JSON file as the table `name`. Not
   * supported yet: its arguments are checked, and it rejects with
   * UnsupportedOperation.
   */
  async registerNdjson(name: string, path: FilePath): Promise<void> {
    tableName(name);
    filePath(path);
    this.#open();
    throw noRegistration("registerNdjson", "a newline-delimited JSON file");
  }

  /**
   * Runs the one SQL statement `query` over the session's tables
   * (`komira_sql_stream`) and resolves with its answer, unread. The answer is
   * computed before the promise settles, so it rejects on a syntax error, an
   * unknown table or column, and every refusal at bind, optimize, lower or
   * execute: with a KomiraError (an UnsupportedOperation for a construct the
   * engine refuses by name) whose message is the engine's
   * (`<step>: <reason>`), whose status is -3, and whose code and step are
   * the engine's. A query that is not a string is a TypeError, and one
   * holding a NUL byte or a lone surrogate a RangeError, before the library
   * is called. The session takes its next call after a refusal.
   */
  async sql(query: string): Promise<Result> {
    const text = queryText(query);
    const handle = this.#open();
    const native = this.#native;
    const drained = await callAsync(() => native.addon.sql(handle, text));
    return resultOf({ addon: native.addon, handle: drained });
  }

  /** `close()`, for `using`. */
  [Symbol.dispose](): void {
    this.close();
  }

  /** `close()`, for `await using`, settled once the context is freed. */
  async [Symbol.asyncDispose](): Promise<void> {
    this.close();
    await this.#freed;
  }
}

// A module is evaluated once per JavaScript environment, so a worker thread
// has its own default session: an addon external cannot cross environments.
let defaultSession: Session | undefined;

/**
 * The session the module-level calls use: made with default options at the
 * first call of this environment, and never closed.
 */
export function defaultSessionOf(): Session {
  defaultSession ??= new Session();
  return defaultSession;
}

/** `registerParquet` on the default session. */
export async function registerParquet(name: string, path: FilePath): Promise<void> {
  return defaultSessionOf().registerParquet(name, path);
}

/** `sql` on the default session. */
export async function sql(query: string): Promise<Result> {
  return defaultSessionOf().sql(query);
}
