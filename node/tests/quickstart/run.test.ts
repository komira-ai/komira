// The quickstart runs as a user runs it: saved as quickstart.mjs in an empty
// project directory whose node_modules holds the package by its name (the
// staged package directory, with dist/, the pinned apache-arrow and the
// linux-x64 platform package as npm lays them out), and started there with
// `node quickstart.mjs`. What it prints is examples/quickstart.expected with
// the package's version, the ABI table's version and the directory's real
// path put in.
//
// The package loads libkomira as it does for a user, so it reads this host's
// real /proc/cpuinfo: this is an integration test (:quickstart_integration),
// run on the build farm's Linux x64 hosts.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, realpathSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { test } from "node:test";

import { fill } from "./shown.ts";
import { EXAMPLE, EXPECTED, MANIFEST, ROOT, abiVersion, staged } from "./staged.ts";

test("node quickstart.mjs in a new project prints the expected output", () => {
  const project = realpathSync(mkdtempSync(path.join(tmpdir(), "komira-quickstart-")));
  const installed = path.join(project, "node_modules", MANIFEST.name);
  mkdirSync(path.dirname(installed), { recursive: true });
  symlinkSync(ROOT, installed, "dir");
  copyFileSync(path.join(ROOT, EXAMPLE), path.join(project, "quickstart.mjs"));
  const run = spawnSync(process.execPath, ["quickstart.mjs"], { cwd: project, encoding: "utf8" });
  assert.equal(run.status, 0, `node quickstart.mjs exited with ${String(run.status)} (signal ${String(run.signal)}):\n${run.stderr}`);
  const want = fill(staged(EXPECTED), { version: MANIFEST.version, abi_version: abiVersion(), cwd: project });
  assert.equal(run.stdout, want, `stderr:\n${run.stderr}`);
});
