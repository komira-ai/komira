// The Node addon over libkomira (node/komira_addon.c, node/README.md), loaded
// once per JavaScript environment, and the conversion of its errors into the
// package's own.
//
// `load` finds the platform package (platform.ts), picks the libkomira file of
// its native directory and checks the CPU (cpu.ts), and only then opens
// anything: the addon with require, then the library with the addon's `load`,
// which checks the ABI major version and resolves the functions the addon
// calls. Every failure is a LibraryLoadError (or UnsupportedCpuError) that
// names the file. Importing the package loads nothing; the first call that
// needs the library does. A refused library stays mapped (the Mojo runtime
// cannot be unloaded), and the next call tries again.
//
// The addon's own error codes (KOMIRA_ARG, KOMIRA_LOAD_FAILED, ...) stay in
// this module: `fromAddon` turns an error the addon threw, or a session call's
// rejection, into a KomiraError. A session's calls run on a native thread of
// its own (node/README.md, "The session thread") and return Promises.

import { createRequire } from "node:module";
import path from "node:path";

import type { ArrowAddon } from "./arrow_import.ts";
import { isFile, libraryPath, type Host } from "./cpu.ts";
import { KomiraError, LibraryLoadError, type Step } from "./errors.ts";
import { ADDON, NATIVE, defaultHost, platformPackage, platformPackageDir } from "./platform.ts";

/** A session of the addon: an external it made, opaque to JavaScript. */
export type Handle = object;

/** The calls of the addon this package makes (node/README.md, "The calls"). */
export interface Addon extends ArrowAddon {
  load(path: string): void;
  abiVersion(): number;
  newSession(): Handle;
  /** Refuses later calls at once; the Promise settles once the context is freed, after the calls made before it. */
  freeSession(session: Handle): Promise<void>;
  /** Runs on the session's own thread; the Promise rejects with the call's status. */
  registerParquet(session: Handle, name: string, path: string): Promise<void>;
  /** komira_sql_stream on the session's thread, its stream drained there: a result the Arrow calls read. */
  sql(session: Handle, query: string): Promise<object>;
  sessionStats(): { created: number; freed: number };
}

/** The addon with the library it loaded, and where both came from. */
export interface Native {
  readonly addon: Addon;
  /** The addon file. */
  readonly addonFile: string;
  /** The native directory (absolute). */
  readonly dir: string;
  /** The libkomira file of `dir` the addon opened. */
  readonly library: string;
}

let loaded: Native | undefined;
let hostOf: () => Host = defaultHost;

/**
 * Sets the host `load` reads in place of this process's (`defaultHost`), so
 * a test plants the platform and the cpuinfo.
 */
export function setHost(h: Host): void {
  hostOf = () => h;
}

/** Makes `load` read this process's host again. */
export function resetHost(): void {
  hostOf = defaultHost;
}

/**
 * The loaded library of this environment, loading it from the platform
 * package on the first call.
 */
export function load(): Native {
  if (loaded !== undefined) {
    return loaded;
  }
  const h = hostOf();
  const dir = platformPackageDir(platformPackage(h));
  return loadFrom(path.join(dir, ADDON), path.join(dir, NATIVE), h);
}

/** The message of an error a loader threw. */
function messageOf(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/**
 * Loads the addon `addonFile` and, with it, libkomira from the native
 * directory `nativeDir` on `host`. A second load of the same directory in
 * this environment returns the first without reading the CPU again; another
 * directory is refused.
 */
export function loadFrom(addonFile: string, nativeDir: string, h: Host): Native {
  const dir = path.resolve(nativeDir);
  if (loaded !== undefined) {
    if (loaded.dir === dir) {
      return loaded;
    }
    throw new LibraryLoadError(`libkomira is already loaded from ${loaded.dir}, so it cannot be loaded from ${dir}`);
  }
  const library = libraryPath(dir, h);
  if (!isFile(addonFile)) {
    throw new LibraryLoadError(
      `the Node addon ${addonFile} is missing, so the platform package is damaged: install it again`,
    );
  }
  let addon: Addon;
  try {
    addon = createRequire(import.meta.url)(addonFile) as Addon;
  } catch (e) {
    throw new LibraryLoadError(`cannot load the Node addon ${addonFile}: ${messageOf(e)}`);
  }
  try {
    addon.load(library);
  } catch (e) {
    // The addon says "cannot load libkomira: <the loader's message>" when the
    // file does not open, and names the version or the symbol otherwise.
    const message = messageOf(e).replace(/^cannot load libkomira: /, "");
    throw new LibraryLoadError(`cannot load libkomira from ${library}: ${message}`);
  }
  loaded = { addon, addonFile, dir, library };
  return loaded;
}

/** komira_last_error_step's numbers (KOMIRA_STEP_*), as the step's name; 0 is none. */
const STEPS: readonly (Step | null)[] = [null, "parse", "bind", "optimize", "lower", "execute"];

/**
 * The KomiraError for an error the addon threw or rejected with. A failed C
 * call (an error with a status) carries its status and the
 * context's last error, which becomes the message unchanged (the addon's own
 * message when the library gave no text), and the engine's named code and
 * step (komira_last_error_code and _step, ABI 1.7), each null when the
 * library gave none or is older. `sql` on a library older than ABI 1.3 is a
 * LibraryLoadError naming both versions. Anything else (a stream the Arrow
 * import could not drain or read, or the addon refusing its own use) keeps
 * its message with no status. A KomiraError (UnsupportedOperation from the
 * Arrow import) is returned as it is.
 */
export function fromAddon(e: unknown): KomiraError {
  if (e instanceof KomiraError) {
    return e;
  }
  const fields = (typeof e === "object" && e !== null ? e : {}) as {
    status?: unknown;
    code?: unknown;
    lastError?: unknown;
    errorCode?: unknown;
    errorStep?: unknown;
  };
  if (fields.code === "KOMIRA_ABI_TOO_OLD") {
    return new LibraryLoadError(messageOf(e));
  }
  // A failed callback of an Arrow C stream has an errno value as its status, not the ABI's.
  if (typeof fields.status !== "number" || fields.code === "KOMIRA_ARROW_STREAM") {
    return new KomiraError(messageOf(e));
  }
  const text = typeof fields.lastError === "string" && fields.lastError !== "" ? fields.lastError : messageOf(e);
  const code = typeof fields.errorCode === "string" && fields.errorCode !== "" ? fields.errorCode : null;
  const step = typeof fields.errorStep === "number" ? (STEPS[fields.errorStep] ?? null) : null;
  return new KomiraError(text, { status: fields.status, code, step });
}

/** `f()`, with an error the addon throws turned into a KomiraError. */
export function call<T>(f: () => T): T {
  try {
    return f();
  } catch (e) {
    throw fromAddon(e);
  }
}

/**
 * The value of the addon's Promise `f()`, with what it throws (a misuse,
 * before anything is queued) or rejects with (a failed C call, from the
 * session's thread) turned into a KomiraError.
 */
export async function callAsync<T>(f: () => Promise<T>): Promise<T> {
  try {
    return await f();
  } catch (e) {
    throw fromAddon(e);
  }
}
