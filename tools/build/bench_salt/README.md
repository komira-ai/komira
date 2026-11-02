# A benchmark salt: `-c komira.bench_salt`

A cached action is not run again, and `--no-remote-cache` would re-run every
action of the build, the compiler's unpacking included. To measure a build
whose inputs are read cold (every action executing, so the worker fetches its
input blobs from the content store), give the build a salt:

```sh
./buck2 build komira//src/foo:foo -c komira.bench_salt=run1
```

Every action that the rules of `komira//src/foo:foo` (and of the libraries it
depends on) declare gets one more environment variable,
`KOMIRA_BENCH_SALT=run1`. The environment is part of an action's key, so each
of those actions misses the cache and executes. A new value runs them all
again; a value used before is a cache hit of that run. The tools the actions
run (the Zig launcher and the other Zig executables, the unpacked compiler
and toolchains) are not salted, so they stay cache hits and the measured work
is the target's own.

It is a measurement flag. It is never set in a committed `.buckconfig`.

## The value

Empty, or letters, digits, `.`, `_` and `-`. Anything else fails the load of
every BUCK file, naming the value. Empty and unset are the same: no action
gets the variable, and every action key is exactly what it is without the
flag: the self-test `bench_salt` reads the environment `salted` returns for an unset, an empty and a set value, and compares the action digests of unset and empty.

[`bench_salt.bzl`](bench_salt.bzl) reads `[komira] bench_salt` of the root
cell once, when it is loaded, and a rule passes the environment of an action
through `salted(env)`.

## The rules that take it

| family | actions (category) |
|---|---|
| `mojo_library` | `mojo_precompile`, every `mojo_build` and `mojo_build_test` compile and link, `mojo_gated_test`, `mojo_gate_join`, `mojo_readme_join`, `native_reach`, `mojo_doc`, `mojo_doc_check`, the README generation |
| `mojo_binary`, `mojo_shared_lib` | the compile and link, `mojo_run_check`, `mojo_shared_lib_exports`, `mojo_shared_lib_gate`, `mojo_shared_lib_join` |
| `mojo_proto_library` and the ABI checks | the generation (`*_proto_gen`), `mojo_precompile`, `abi_golden`, `c_abi_check`, `archive_files`, `mojo_helper_check` |
| `rust_library`, `rust_binary`, `rust_test` | `rustc`, `rust_gate_join`, `rust_gated_test`, `rust_run_check` |
| the C/native rules | `native_exports`, `native_link`, `native_check`, `native_dynsym`, `prefix_header`, `prefixed_archive_check` |
| packaging | the launcher, bundle, tar, OCI tree, layers and image, the kcov guard and the install and OCI checks, and the conda package (`conda_pack`, `conda_check`, the README link, the manifest and the doc check) |

Not salted, on purpose:

- **Tools and toolchains**: `zig_unpack`, `zig_build_exe`, `zig_test`,
  `zig_bootstrap_*`, `conda_unpack`, `tar_member`, `c_exe`, the downloads, the
  Rust sysroot and crate unpacking and patching, `protoc_unpack`. Salting them
  would rebuild the compiler and every tool on each new value, and the
  measurement is of one target's actions.
- **Coverage and mutation runs** (`-c komira.coverage`, `-c komira.mutation`)
  and the lints: measurements of their own, with their own switches. (A
  library's coverage build compiles through the same compile helper, so it
  carries the salt on its compile and link actions.)
- **The Node.js and Python rules** and the code generators: not wired; the
  measurement does not use them.

## The guard

The self-test scenario [`bench_salt`](../selftest/bench_salt.zig) builds one
target of each family above four times, each in a fresh daemon, and reads
`buck2 log what-ran` with the action digests: with the value empty every
action keeps its digest; with a new value every action of each target has a
new digest and executes on the farm while the tool actions keep theirs; the
same value again is all cache hits; and a value with a space or a slash is
refused.
