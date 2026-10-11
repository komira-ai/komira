# komira_test_node

The tests of the hermetic Node.js: the runtime and npm packages pinned in
[`third_party/node`](../../../../third_party/node/README.md) and the rules in
[`tools/build/node`](../../../../tools/build/node/README.md). Each `node_test`
runs its script with the pinned `node` as a build action on the farm, so
building a target runs it, and its output exists only if it passed. The
package has no Mojo library.

| target | what it proves | the defect it catches |
|---|---|---|
| `:isolation` ([`isolation.js`](isolation.js)) | `node` is the pinned version; `process.execPath` is inside the action's `buck-out`; the environment is exactly `HOME`, `LC_ALL`, `LD_LIBRARY_PATH`, `TMPDIR` and `TZ`; every file the process maps is under the action's working directory except glibc's own libraries, and `libstdc++.so.6` and `libgcc_s.so.1` are each mapped once, from there | a worker's `node` or C++ runtime reaching the test (`LD_LIBRARY_PATH` missing or wrong: the worker's `libstdc++.so.6` is mapped), or an environment variable leaking in |
| `:fails` ([`fails.js`](fails.js)) | `node_test` with `expect_error`: the script's failed assertion fails it, and the assertion's message is on stderr | a runner that reports a failing script as passed, or loses its error |
| `:fails_dash` ([`fails_dash.js`](fails_dash.js)) | `node_test` with an `expect_error` that starts with `--`: the text is matched, not read as an option of the matcher | a runner that passes `expect_error` where an option may stand (`grep -qF "$ERROR"`), which fails every such test |
| `:two_module` (`:two_module_bundle`, [`two_module/`](two_module/)) | `esbuild_bundle` resolves a relative import of a TypeScript module, strips its types and writes one file that runs alone: the test stages only the bundle, and asserts the second module's results | a bundle that leaves an import unresolved (it fails to load without `greet.ts`), or a wrong result from the bundled module |
| `:esm` (`:esm_bundle`, [`esm/`](esm/)) | `esbuild_bundle` with `format = "esm"` writes an ES module: the entry awaits at the top level and checks that `import.meta.url` is a `file:` URL, then runs from the bundle alone (`esm_bundle.mjs`) | `format` ignored or `cjs` written regardless (esbuild refuses a top-level `await` in cjs, so the bundle fails to build) |
| `:arrow_ipc` (`:arrow_ipc_bundle`, [`arrow_ipc.mjs`](arrow_ipc.mjs)) | apache-arrow, bundled from the pinned packages with its dependencies, writes an IPC stream (it starts with the continuation marker) of a float64 column with a null and a utf8 column, and reads it back with the same schema, values and null | a dependency missing from the closure (the bundle fails to build), or apache-arrow failing to round-trip |
| `:arrow_ipc_node_modules` ([`arrow_ipc.mjs`](arrow_ipc.mjs)) | the same script unbundled: node resolves apache-arrow and its dependencies from the packages `node_test` stages under `node_modules` (`deps`), as a runtime whose packages are installed beside it rather than bundled would | a dependency missing from the closure (`ERR_MODULE_NOT_FOUND` at run time) |
| `:addon_loads` (`:addon`, [`addon/`](addon/)) | a Node-API addon built by `c_shared_lib`, its `napi_*` symbols left undefined, loads in node and is context-aware: the main thread and two worker threads, alive together, each load it; `count()` counts per environment (each worker sees 1, 2, 3, and the main thread's count is not moved by the workers), because the state is per-environment instance data (`napi_set_instance_data`); and each worker's state is freed by its finalizer when the worker exits (`finalized()` is 2) | state shared between environments (a static counter), state never freed, or an addon that does not load in a worker |
| `:addon_exports` (`:addon`, [`addon/exports_test.js`](addon/exports_test.js)) | the addon's dynamic symbol table, read from the ELF file, defines exactly `napi_register_module_v1` and `node_api_module_get_api_version_v1`: `c_shared_lib` hides every other function, `addon.c`'s non-static `addon_next_count` included | `c_shared_lib` exporting functions its sources do not mark for export (`-fvisibility=hidden` dropped) |

The pins are checked by their own targets ([third_party/node](../../../../third_party/node/README.md#the-pins)):
building any test builds `:node` and the npm packages it uses, each of which
fails on a sha256, size, integrity, name or version that differs from its pin.
The rules' refusals, a failing script failing its `node_test` among them, are
planted in the `tests` cell
([test 54](../../../../tools/build/node/README.md#test-54-planted-defects)).
