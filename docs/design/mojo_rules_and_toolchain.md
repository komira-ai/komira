# Mojo rules and toolchain: why the build is shaped this way

The reference for using the Mojo rules is [tools/build/mojo/README.md](../../tools/build/mojo/README.md); the pinned downloads and the host floor are in [tools/build/toolchains/README.md](../../tools/build/toolchains/README.md); the worker classes are in [tools/build/platforms/README.md](../../tools/build/platforms/README.md). This doc does not repeat them. It records the decisions behind them, so a change to a rule, the wrapper or a pin can be judged against the reason it exists.

## What is it for, and what is out of scope?

The Mojo rules (`tools/build/mojo`) build each Mojo package into a `.mojoc` with `mojo precompile`, and each binary or test with `mojo build`, using a compiler that the toolchain (`tools/build/toolchains`) unpacks from sha256-pinned downloads. The platforms (`tools/build/platforms`) say which class of worker runs which action.

Out of scope:

- Welding tests and lints to artifacts: [build gates, test welding and lints](gates_test_welding_and_lints.md).
- Packaging a binary as a bundle: [tools/build/package/README.md](../../tools/build/package/README.md).
- The code the protobuf rule generates: [tools/build/mojo/README.md](../../tools/build/mojo/README.md#protobuf-mojo_proto_library).

## How does it work?

One action chain per Mojo target, and every tool in it is an input of the action:

```
pinned downloads (busybox, zig, mojo-compiler .conda, C++ runtime .conda)
   |  remote actions unpack them: zig -> conda_unpack -> :mojo_compiler (+ CLOSURE_MANIFEST)
   v
toolchains//:mojo   (runs on the one execution platform of its OS)
   v
mojo_library:  mojo_wrapper.sh -> mojo precompile -> <import>.mojoc
mojo_binary :  mojo_wrapper.sh -> mojo build      -> executable (+ lib/ of runtime libraries)
```

`mojo_wrapper.sh` is the single place the compiler's environment is decided. It runs under the pinned busybox, never consults the worker's `PATH`, renders `modular.cfg` for the action's own toolchain path, gives the compiler private cache, temporary and home directories, runs it under the watchdog, and checks the output afterwards (exit 3 for a missing or empty output, exit 4 for an output that contains the action's working directory).

## Why is it built this way?

### Why is every tool an input of the action?

**Decision.** The compiler, the linker driver, the shell and the C++ runtime are pinned files that remote actions unpack. The client only downloads them (`pinned_file`) and uploads them to the remote cache. No action reads a tool from the worker's `PATH`.

**Because.** An action's cache key names its inputs, not the machine it runs on. A compiler found on a worker produces an artifact under a key that names a different compiler, and a shared cache then serves it to everyone. Making each tool an input puts its content in the key. The only things an action takes from the worker are the kernel, a CPU that implements `x86-64-v3`, and glibc 2.34 or newer (the host floor in the toolchains README), and a test (test 8 in [tools/build/tests/README.md](../../tools/build/tests/README.md#8-host-floor-and-runtime-libraries)) reads the loader's own record of a real compile and run to prove nothing else is mapped from the worker.

**Alternatives weighed.**

- Use a compiler installed on the worker: every worker must be kept in step with the pin, and when one is not, the output is wrong with no diagnostic.
- Unpack the toolchain on the client: the client may be a different operating system from the worker.

**Revisit if.** Mojo ships one compiler binary that runs on every platform that executes actions, or buck2 can key an action on the executed binary itself.

### Why does the wrapper refuse instead of falling back?

**Decision.** When a member listed in the toolchain's `CLOSURE_MANIFEST` is missing or empty, the wrapper exits 2. It never runs a compiler it finds elsewhere.

**Because.** A fallback hides a broken input tree behind a working build. The refusal turns an incomplete closure into one named failure at the first action that needs it ([test 4](../../tools/build/tests/README.md#4-closure-refusal)).

The refusal has a limit that the toolchains README records and a reader should not assume away: `conda_unpack` writes the manifest from what it unpacked, so a toolchain built without the C++ runtime pin carries a manifest without those names. The wrapper cannot see the omission. The guard for the runtime pin is `:mojo_runtime`, which refuses a library name the closure lacks, together with test 8.

**Revisit if.** The manifest is generated from the pin rather than from the unpacked files.

### Why does the wrapper, not the action, set the compiler's environment?

**Decision.** The wrapper derives `MODULAR_HOME`, `PATH` and the library path from the toolchain path it is given at run time. Nothing is inherited from the worker.

**Because.** An absolute install prefix in the action would differ between machines, so equal actions would have different keys and the shared cache would not deduplicate them. The wrapper's own content is part of the key, and the paths it computes are not.

For the same reason the link step is rewritten. Through the `cc` shim, the wrapper drops every run path the compiler asks for, since each names one action's directory, and sets exactly one (`$ORIGIN/lib`, or a caller's `--runpath` that starts with `$ORIGIN`). It strips debug sections, because zig's C runtime objects record the compilation directory. The wrapper also strips the staging directory from the source names the compiler records, so an output names a file by its path in the package. An output therefore names no path that exists only inside one action, and a binary finds its runtime libraries in the `lib/` next to it.

**Revisit if.** buck2 can exclude an environment value from an action's key.

### Why does the compiler target a fixed CPU?

**Decision.** Every `mojo build` passes `--target-cpu` from the toolchain (`x86-64-v3`). `mojo precompile` does not, because it rejects the flag: a `.mojoc` holds no machine code, so the CPU is fixed where code is generated.

**Because.** The compiler's default is the CPU of the machine the action runs on, and that machine is not part of the action key. Two workers would then share a cache entry for different machine code. Pinning the target makes the output a function of the key. The cost is that gated tests and run checks execute the code they compile, so the worker must implement `x86-64-v3` (it is in the host floor).

**Revisit if.** The compiler's host CPU becomes part of the key.

### Why does the watchdog measure CPU and not wall time?

**Decision.** The wrapper samples the CPU time of the compiler's whole process tree every `watchdog_sample_secs` (default 30). After `watchdog_idle_secs` (default 300) of consecutive samples that each gained less than 1% of one CPU, it kills the session and exits 124. There is no wall-clock limit.

**Because.** The compiler can deadlock in its own runtime with every thread parked. A remote action has no other bound than the executor's timeout, so one wedge would hold a worker slot for all of it. A slow compile uses CPU the whole time, so a wall-clock limit would kill healthy work that merely runs long; zero CPU is the signature of a wedge. The compiler runs in a session of its own and the sampled set is exactly the set that gets killed, so a helper that does the work while the parent waits is never read as idle. Exit 124 means the action is safe to retry.

A kill of the wrapper cannot be caught, so a tether process in the compiler's session blocks reading a FIFO whose only writer is the wrapper. When the wrapper dies, however it dies, the read returns and the tether kills the session. Nothing polls for it.

**Revisit if.** The deadlock is fixed in the compiler. `watchdog_idle_secs = 0` turns the watchdog off.

### Why does a library's `deps` carry the whole closure, one directory per package?

**Decision.** The compiler gets one `-I` directory per package in the transitive closure, and each directory holds exactly one `.mojoc`.

**Because.** The compiler needs the full closure at consume time, not only direct dependencies, because a `.mojoc` does not inline its dependencies. One `.mojoc` per directory means a staged source directory can never shadow a package: a package reaches the compiler only through `deps`. The same shape makes a missing dependency fail to compile rather than resolve from something nearby ([test 3](../../tools/build/tests/README.md#3-missing-dependency)).

**Revisit if.** The compiler resolves a package's own dependencies without help from the command line.

### Why are vendored C and C++ libraries built from the pinned archive, with generated source lists?

**Decision.** Third-party C code (`third_party/snappy`, `third_party/brotli`, `third_party/aws-lc`, `third_party/s2n-tls`, `third_party/sqlite`) builds from a sha256-pinned archive with the prelude's `cxx_library`, using zig's clang. For aws-lc and s2n-tls the build does not run upstream's CMake. The source and header lists (`srcs.bzl`) are generated from the archive's CMake lists by the Mojo tool `tools/build/third_party_srcs`, and a drift test fails when the checked-in lists differ from the generated ones. aws-lc, s2n-tls and snappy's C API are built with every global symbol renamed under a komira prefix (`komira_awslc_`, `komira_s2n_`, `komira_snappy_`) by a header generated from the unprefixed archive's symbol table, and a symbol check of the prefixed archive gates every build that links it (`tools/build/native`), so komira's copies can share a process with other copies of those libraries.

**Because.** Running CMake would put a configure step, and whatever it probes on the machine, into the action. A generated list keeps the compiled file set equal to upstream's for that exact archive while every action stays a plain compile. Sources are named through `staged_files`, which copies them into `buck-out`, so a consumer that mounts komira at another path produces the same action digest and shares the cache (test 7).

**Alternatives weighed.**

- Check in a hand-written source list: it drifts silently when the archive is bumped. The drift test is what prevents that.
- Link the system's libraries: the build would then depend on the worker's package set, which this design excludes.

**Revisit if.** An upstream's CMake can run hermetically as a buck2 action.

### Why do C++ libraries link zig's libc++ statically?

**Decision.** A `cxx_library` lists `komira//tools/build/toolchains:libcxx` in `exported_deps`, and a binary links zig's libc++ and libc++abi statically.

**Because.** The Mojo runtime itself loads `libstdc++.so.6`, so a binary can hold two C++ runtimes. Linking one of them statically and exporting no dynamic symbol keeps them from interposing on each other. The consequence stays a rule for callers: memory and exceptions must not cross between C++ code and the Mojo runtime's own C++ internals. Test 20 checks the two-runtime binary on the snappy example.

**Revisit if.** The Mojo runtime stops loading a system C++ runtime.

### Why is there one execution platform per OS?

**Decision.** There is one Linux execution platform and one macOS one. No constraint separates unpacking from compiling, and no NUMA constraint exists: a target that needs the Linux x86_64 workers states `LINUX_X86_64` from `tools/build/platforms/defs.bzl`, and every other target needs no execution constraint.

**Because.** An earlier layout split the workers into classes (light, mojo_compile) and NUMA shapes, each a constraint and a platform. Every target and toolchain had to name its class, and a stale name broke analysis of everything that depended on it. The worker pool is now chosen by the service property set (`[komira_re] linux_x86_64_properties`), not by the build graph.

**Revisit if.** A workload needs workers the single pool cannot serve.

## What must always hold?

- **No action reads a tool from the worker.** Enforced by the wrapper's closure refusal (exit 2) and by test 8.
- **A binary's run paths are `$ORIGIN`-relative.** Enforced by the `cc` shim, and by test 8 for the runtime libraries' vendor `DT_RPATH` entries.
- **A zero-byte output is a failure.** Enforced by the wrapper (exit 3).
- **A compile that uses no CPU is not left running.** Enforced by the watchdog (exit 124).
- **The Mojo rules depend on the lint of the scripts they run.** The toolchain's `_script_lint` is a validation, so no Mojo target builds while a rule script has a finding.

## Where is the code?

| What | Where |
|---|---|
| The rules and the gate | `tools/build/mojo/defs.bzl`, `providers.bzl` |
| The compiler wrapper (Linux, macOS) | `tools/build/mojo/mojo_wrapper.sh`, `tools/build/mojo/darwin/` |
| The toolchain and the downloads | `tools/build/mojo/toolchain.bzl`, `download.bzl`, `tools/build/toolchains/` |
| C and C++ | `tools/build/mojo/cxx.bzl`, `archive.bzl`, `third_party/` |
| Worker classes | `tools/build/platforms/` |

## How is it tested?

The end-to-end tests under `tools/build/tests` ([README](../../tools/build/tests/README.md)) build and run the examples and plant the failures: a missing dependency, an incomplete closure, host paths in an output, the loader trace of the host floor, the compile watchdog, execution-platform resolution and C and C++ dependencies. Each of those is a `buck2 build` that must go red or green for a stated reason.

## What are its limits and open questions?

- The host floor is measured on a hello-world compile and run only. A library the compiler loads lazily on another path, such as its Python interop, is not traced.
- The floor is not part of an action key, so workers that differ in it must not share a remote cache.
- The aarch64 assembly source lists for aws-lc are generated but not built.
- Linux x86_64 is the target platform. macOS arm64 has its own compiler pin and wrapper, but the C and C++, Rust and protobuf toolchains are Linux x86_64 only, so a darwin target that needs one is incompatible rather than built for Linux.
