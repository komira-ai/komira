// Result: the answer of one Session.sql call (docs/design/typescript_package.md,
// "Public names" and "Behaviour"), read once, as one apache-arrow Table or as
// its RecordBatches.
//
// The addon ran komira_sql_stream and drained the Arrow C stream on the
// session's thread before `sql` resolved, so a Result holds the answer's
// schema and batches in native memory and needs neither the session nor its
// context: it reads after the session is closed. The batches become
// apache-arrow data over that memory through the private Arrow import
// (arrow_import.ts); a batch is released when apache-arrow no longer holds its
// buffers, and what a Result never reads is released when the Result is
// collected.

import type { RecordBatch, Table } from "apache-arrow";

import { openBatches, tableOf, type ArrowAddon } from "./arrow_import.ts";
import { KomiraError } from "./errors.ts";
import { call } from "./native.ts";

/** What a Result reads: the addon's Arrow calls and the drained result `sql` resolved with. */
export interface ResultSource {
  readonly addon: ArrowAddon;
  readonly handle: object;
}

let construct: (source: ResultSource) => Result;

/**
 * The answer of one `sql` call, read once: the first `toArrow()`, or the first
 * step of an iteration, takes its batches, and any later read rejects with
 * KomiraError("the result was already read"). It reads after its session is
 * closed. Made by `Session.sql` and the module-level `sql`, never by user code.
 */
export class Result {
  #source: ResultSource | null;

  private constructor(source: ResultSource) {
    this.#source = source;
  }

  static {
    construct = (source) => new Result(source);
  }

  /** The source, taken: a Result is read once. */
  #take(): ResultSource {
    const source = this.#source;
    if (source === null) {
      throw new KomiraError("the result was already read");
    }
    this.#source = null;
    return source;
  }

  /**
   * The whole answer as one apache-arrow Table, of the `apache-arrow` the
   * user installed. Rejects with UnsupportedOperation naming the column when a
   * column's Arrow type is one this package does not read, and with
   * KomiraError when the result was already read.
   */
  async toArrow(): Promise<Table> {
    const { addon, handle } = this.#take();
    return call(() => tableOf(addon, handle));
  }

  /**
   * The answer's apache-arrow RecordBatches, in order, for `for await`.
   * Leaving the loop early releases the batches not read. The first step
   * rejects as `toArrow` does.
   */
  async *[Symbol.asyncIterator](): AsyncGenerator<RecordBatch, void, undefined> {
    const { addon, handle } = this.#take();
    const { batches } = call(() => openBatches(addon, handle));
    try {
      for (;;) {
        const next = call(() => batches.next());
        if (next.done === true) {
          return;
        }
        yield next.value;
      }
    } finally {
      // Closes the result when the loop is left before the last batch.
      batches.return(undefined);
    }
  }
}

/** A Result over `source`, for `Session.sql`. */
export function resultOf(source: ResultSource): Result {
  return construct(source);
}
