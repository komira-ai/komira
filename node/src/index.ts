// komira: SQL over local files, with libkomira, the komira query engine, in
// process (docs/design/typescript_package.md).
//
// This is the package's one entry. Its public names are exactly the ones
// exported here; every other module is private. Importing it loads nothing:
// the first Session, registerParquet, sql or abiVersion loads libkomira from
// the platform package npm installed beside it.

import { call, load } from "./native.ts";

export { KomiraError, LibraryLoadError, UnsupportedCpuError, UnsupportedOperation } from "./errors.ts";
export type { KomiraErrorFields, Step } from "./errors.ts";
export { Result } from "./result.ts";
export { Session, registerParquet, sql } from "./session.ts";
export type { CsvOptions, FilePath, SessionOptions } from "./session.ts";
export { version } from "./version.ts";

/**
 * The C ABI version of the loaded libkomira, `major * 1000 + minor` (1008 is
 * 1.8). Loads the library if no call has yet; throws LibraryLoadError when it
 * cannot.
 */
export function abiVersion(): number {
  const native = load();
  return call(() => native.addon.abiVersion());
}
