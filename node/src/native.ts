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
// The addon's own error codes (KOMIRA_ARG, KOMIRA_LOAD_FAILED, ...) and the
// KOMIRA_ERR_* names of the statuses stay in this module: `fromAddon` turns
// an error the addon threw, or a session call's rejection, into a KomiraError
// of the class the engine's code picks. A session's calls run on a native thread of
// its own (node/README.md, "The session thread") and return Promises.

import { createRequire } from "node:module";
import path from "node:path";

import { isFile, libraryPath, type Host } from "./cpu.ts";
import { KomiraError, LibraryLoadError, errorClass, stepOf } from "./errors.ts";
import { ADDON, NATIVE, defaultHost, platformPackage, platformPackageDir } from "./platform.ts";

/** A session of the addon: an external it made, opaque to JavaScript. */
export type Handle = object;

/** The calls of the addon this package makes (node/README.md, "The calls"). */
export interface Addon {
  load(path: string): void;
  abiVersion(): number;
  /**
   * A context: `komira_ctx_new`, or `komira_ctx_new_with_options` when an
   * option is given and not 0 (0 or undefined is the engine's own value).
   */
  newSession(threads?: number, memoryLimit?: number): Handle;
  /** Refuses later calls at once; the Promise settles once the context is freed, after the calls made before it. */
  freeSession(session: Handle): Promise<void>;
  /** Runs on the session's own thread; the Promise rejects with the call's status. */
  registerParquet(session: Handle, name: string, path: string): Promise<void>;
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

/**
 * The KomiraError for an error the addon threw. A failed C call carries its
 * status and the context's last error: its text becomes the message unchanged
 * (the addon's own message when the library gave no text), its named code the
 * error's `code` (null when empty) and its step number the error's `step`
 * (null for none or a number this package does not know). The status and the
 * code pick the class (`errorClass`). Anything else is the addon refusing its
 * own use, or a session the library could not make, and keeps its message
 * with no status.
 */
export function fromAddon(e: unknown): KomiraError {
  const fields = (typeof e === "object" && e !== null ? e : {}) as {
    status?: unknown;
    lastError?: unknown;
    lastErrorCode?: unknown;
    lastErrorStep?: unknown;
  };
  if (typeof fields.status !== "number") {
    return new KomiraError(messageOf(e));
  }
  const text = typeof fields.lastError === "string" && fields.lastError !== "" ? fields.lastError : messageOf(e);
  const code = typeof fields.lastErrorCode === "string" && fields.lastErrorCode !== "" ? fields.lastErrorCode : null;
  const cls = errorClass(fields.status, code);
  return new cls(text, { status: fields.status, code, step: stepOf(fields.lastErrorStep) });
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
