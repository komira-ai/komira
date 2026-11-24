// The errors the package raises on purpose (docs/design/typescript_package.md,
// "Errors a user can act on"). Every one is a KomiraError, so `instanceof
// KomiraError` catches komira's errors and nothing else. A wrong argument is
// JavaScript's own TypeError or RangeError instead, raised before the library
// is called. The private Arrow import (arrow_import.mts) raises
// UnsupportedOperation for a format it does not map.

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
 * the engine refused), or null when no call returned one. `code` is the
 * engine's name for that status (`KOMIRA_ERR_ENGINE`), or null. `step` is the
 * step of the query that failed, or null. The message is the engine's text,
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
