// A damaged platform package: libkomira's self-contained native directory
// with one of the three Mojo runtime libraries, libMSupportGlobals.so, left
// out (//tools/build/package/libkomira:dist_without_msupport, picked file by
// file from //src/so:libkomira[dist]). The loader fails to open libkomira, and
// the package says so as a LibraryLoadError, no other class, whose message
// names the library it tried and the missing file. The loader's own words
// differ by platform, so the test holds the class, the prefix the package
// writes and the file name, not the whole text. This file is its own process,
// so nothing else has opened a library before it.

import assert from "node:assert/strict";
import path from "node:path";
import { test } from "node:test";

import { LibraryLoadError } from "../src/errors.ts";
import { loadFrom } from "../src/native.ts";
import { ADDON_FILE, LINUX_X64, fixture, refused } from "./helpers.ts";

test("a native directory without one of the Mojo runtime libraries is a LibraryLoadError naming that file", () => {
  const dir = fixture("native_without_msupport");
  const prefix = `cannot load libkomira from ${path.join(dir, "libkomira.so")}: `;
  const message = refused(() => loadFrom(ADDON_FILE, dir, LINUX_X64), LibraryLoadError);
  assert.ok(message.startsWith(prefix), message);
  assert.match(message.slice(prefix.length), /\blibMSupportGlobals\.so\b/);
});
