#!/usr/bin/env bash
# run_tests.sh -- end-to-end tests of the Mojo rules. Each test can fail.
#
# usage: tools/build/tests/run_tests.sh [--no-umbrella] [--no-run] [--no-uncached] [--require-install] [--host-check-only]
#        (from the repo root; BUCK2 overrides the binary)
#
# Where the tests run is where this checkout builds: read from the execution
# platforms buck2 registers (tools/build/platforms/default). With a
# `.buckconfig.local` naming a remote-execution service (`[komira_re]`), every
# action runs there and every test below runs. Without one, every action
# runs on this machine: the script says so on its first line, and skips,
# each with its own SKIP line, the tests that need a remote-execution service
# (7, 9, 12 and 24), and test 3, whose red needs the remote executor's input isolation. The remote and local executors are never mixed in one run.
#
# The tests are numbered, and the number is the test's name everywhere (the
# README, the docs). What a test builds lives in functional/ (behaviour that
# must work) or negative/ (planted defects that must go red); a test may have
# both halves, under the same package name.
#
#   1. The examples build and their run checks pass (stdout compared byte for
#      byte), and every action that executed ran on this checkout's executor
#      (remotely, or locally in a local-only run).
#   2. The gate: tests//negative/libgate_bad fails with GATED TEST FAILED, while its
#      [ungated] package builds -- the red comes from the test, not the compile.
#      A binary depending on it fails the same way, and a binary naming its
#      [ungated] sub-target in `deps` fails analysis (no gate bypass).
#   3. Packages reach the compiler only through `deps`: a binary importing
#      hellopkg without depending on it fails to compile.
#   4. The toolchain refuses an incomplete closure (exit 2) instead of falling
#      back to anything on the worker.
#   5. No action argv or env names an absolute host path (Mojo, Rust and
#      protobuf actions).
#   6. Built outputs are path-free: the linked binary's only run path is
#      DT_RUNPATH `$ORIGIN/lib`, and no string in it names a buck-out
#      directory. (Inside every compile action the
#      wrapper also refuses an output containing that action's working
#      directory, exit 4.)
#   7. A repository using komira as a cell -- a git submodule at ./komira or
#      ./third_party/komira, or a git external cell -- gets remote cache hits
#      with the same action digests as a standalone checkout, one of them
#      with a frozen copy of the toolchains cell, and an override in a
#      consumer's toolchains cell reaches the compile command; a consumer
#      with the remote settings in its root .buckconfig resolves to the
#      remote platforms, and refuses execution = remote with an incomplete
#      [komira_re] (tools/build/tests/functional/umbrella_cache.sh; five scratch
#      checkouts and daemons, skipped with --no-umbrella).
#   8. The host floor: during a real compile, and a run of the binary it
#      built, the loader maps libstdc++.so.6 and libgcc_s.so.1 from the
#      toolchain, and nothing from the worker except glibc's own objects
#      (tests//functional/runtime_libs:loader_trace, read from LD_DEBUG). The
#      toolchain libraries the run loaded are exactly the ones a runnable
#      directory carries in lib/ (komira//tools/build/toolchains:mojo_runtime), no more, no
#      fewer, and every run path those libraries carry is $ORIGIN-relative.
#   9. `buck2 run //tools/build/examples:hello` prints the greeting on this
#      machine from a fresh clone, downloads only the binary and its runtime libraries, and
#      the runnable directory still starts after it is moved
#      (tools/build/tests/functional/buck2_run.sh; skipped with --no-run).
#  10. Execution platforms: Mojo compiles, gated tests and run checks,
#      toolchain unpack/copy targets, and third_party_srcs generation, drift
#      test and fixture archive all resolve to the one linux execution
#      platform, `linux-x86_64`.
#  11. (Retired 2026-09-30 with the multi-NUMA rule.)
#  12. Every action runs with the one linux property set, read per action:
#      an uncached build of //tools/build/examples:hello and
#      //tools/build/third_party_srcs:aws_lc_mini_gen (its own daemon under a
#      fixed --isolation-dir, --no-remote-cache, so every action really
#      executes) must record a remote execution carrying `[komira_re]
#      linux_x86_64_properties` for every action it ran, and must have run
#      zig_unpack, zig_build_exe, conda_unpack, mojo_runtime, fixture_archive,
#      third_party_srcs and mojo_build (`buck2 log what-ran`; a cache hit
#      records no properties, so a warm build cannot answer this). Costs about 3 minutes of remote execution; the isolated
#      daemon's buck-out/komira_tests_uncached (~50 MB) is reused per run.
#  13. A program built as a bundle behaves as its executable: stdout, stderr
#      and exit status agree byte for byte across argv, environment, exit(),
#      an unhandled error, buffered output, a data file found through
#      /proc/self/exe, abort() and SIGSEGV (status and stdout exact, the
#      stack dump's first line), and a symlink invocation with another
#      argv[0] (tests//functional/bundle_parity:parity, a remote action).
#  14. The launcher's CPU level function gives glibc's level for the made-up
#      CPUs of tools/build/package/launcher/cpu_models.h: the hand-written ones, and one
#      per feature glibc requires, a CPU of that level or above with just that
#      bit cleared (//tools/build/package:level_test, a remote action). On an x86-64
#      glibc host, its level for this host's CPU agrees with this host's
#      glibc loader (tools/build/tests/functional/glibc_level.sh).
#  15. The bundle of //tools/build/examples:hello (tools/build/tests/functional/bundle.sh): layout, run paths
#      and SHA256SUMS; it runs from a relocated copy and through a symlink on
#      PATH; a CPU below x86-64-v3 gets the one-line refusal (test launcher);
#      two uncached builds give byte-identical bundles, tarballs and docker
#      archives and the same image digest (skipped with --no-uncached; about
#      3 minutes of remote execution).
#  16. The package formats of //tools/build/examples:hello (tools/build/tests/functional/formats.sh): the
#      tarball and the OCI image follow the determinism rules and hold the
#      bundle; the image's blobs, config (entrypoint, linux/amd64) and pinned
#      base layers are checked; the base is fetched only by pinned
#      downloads; `docker run` of the loaded image prints the greeting (SKIP
#      without docker).
#  17. Markdown links are a validation of the build: //:docs (every Markdown
#      file of the repository) and tests//functional/doc_links:ok build, and
#      tests//negative/doc_links:dead fails naming a missing file, a bad
#      #anchor and a link leaving the tree. Every package of the komira and
#      tests cells is in //:docs through the doc_tree its rules declare, the
#      toolchains cell (not in it) holds no Markdown, no BUCK file names a
#      doc_tree or calls package_docs (the rules do), and neither cell sets
#      `[project] package_boundary_exceptions` (a prefix covering one package
#      covers every package under it, so a target could own another
#      package's files).
#  18. The configuration hash of linux-x86_64 (the target platform, and the
#      execution platform's configuration) equals its pin: it is in the
#      digest of every configured action.
#  19. What a repository using komira as a cell loads names no cell but
#      komira, prelude and toolchains: every label outside a comment in the
#      BUCK and .bzl files of tools/build/{mojo,rust,proto-codegen,toolchains,
#      platforms,package,examples,cells} and third_party. A label naming `tests`
#      (standalone-only) fails to load there.
#  20. C/C++ dependencies of Mojo targets: see tools/build/tests/cxx_tests.sh.
#  21. A Mojo binary whose own code records a source location (a List
#      index) builds and runs: the compile wrapper strips the staging
#      directory from recorded paths, so its exit-4 refusal does not fire
#      (tests//functional/location_path).
#  22. Rust rules, and rustc's host floor: see
#      tools/build/tests/rust_tests.sh.
#  23. mojo_proto_library and mojo_db_proto_library, mojo_gcp_client (REST
#      and gRPC service clients), protoc-gen-mojo's text goldens,
#      proto_fixture_check (protoc reading wire fixtures), and
#      deterministic generation across two uncached
#      builds (skipped with --no-uncached; about 16 minutes): see
#      tools/build/tests/proto_tests.sh.
#  24. The macOS arm64 target and execution platform: registration only when
#      configured, resolution, compile command lines, linux actions
#      unchanged, the osx-arm64 closure's Mach-O load commands (unpacked on
#      the farm), the macOS scripts against stand-ins (the wrapper's compile
#      watchdog included), and, when the macOS
#      workers are configured, a build and run check of
#      //tools/build/examples:hello on them (tools/build/tests/functional/darwin/check.sh).
#  25. A fresh clone with no `.buckconfig.local` builds locally: in a scratch
#      clone of the working tree, with no user or system buckconfig, every
#      registered execution platform is local-only, Mojo and toolchain
#      targets resolve to them, and forcing remote execution there refuses,
#      naming `[komira_re]`; and three toolchain actions (a zig unpack and two
#      concurrent zig program builds, no Mojo compile) run locally with an
#      empty PATH (tools/build/tests/functional/local_default.sh). Runs in both modes.
#  26. The vendored aws-lc and s2n-tls: source lists against their archives,
#      known-answer tests, a TLS handshake, the s2n-tls feature probes: see
#      tools/build/tests/c_libs_tests.sh.
#  28. The compile watchdog of mojo_wrapper.sh on stand-in compilers
#      (tests//functional/watchdog:cases, a remote action): a process tree using no CPU
#      is killed with exit 124 and the message, its children and an orphaned
#      grandchild with it; a tree using CPU (itself, through a child, or
#      through an orphaned member of its session while it waits), a
#      short idle and a disabled watchdog are not killed; a compiler error
#      keeps its exit status; malformed knobs are refused (exit 2); and the
#      compiler dies with the wrapper: TERM to the wrapper kills compiler and
#      child before it exits 143, and after a KILL the tether in the
#      compiler's session kills them within 5 s. The macOS wrapper's
#      watchdog (ps rather than /proc) is part of test 24.
#  29. The test runtime contract (tests//functional/test_data): a gated test opens a
#      declared fixture by its repository path from its staged share/, and a
#      fixture it did not declare is absent (the gate goes red); TEST_TMPDIR
#      is private, empty and not /tmp in each of two actions; test_env and a
#      mojo_test's data and env arrive under `buck2 test`, and so do its
#      args, each $(location) an absolute path the test opens and an
#      $(exe_target) a binary with its lib/ (also as a build action,
#      mojo_test_args_action, which is what a pull request builds); a mojo_test
#      exiting 77 (SKIP to some harnesses) fails; a red test stays
#      red with test_env {BIN: true} (library) and env {BIN: true} (mojo_test);
#      the runner itself, run twice in ONE action directory
#      (tests//functional/test_data:runner_cases), gives each run its own empty
#      TEST_TMPDIR under that directory and removes it, no --env reaches
#      the verdict, --arg values arrive in order and unexported, exit 77 is
#      red, and a test killed by SIGKILL or SIGABRT fails with its
#      own status (137, 134) and no marker; five inadmissible data/env
#      declarations are refused at analysis. A library's `test_deps`
#      (tests//functional/test_deps) reach its welded tests: a test imports a
#      test-support package the library does not depend on; and nothing else
#      (tests//negative/test_deps): the library's source and a consumer of
#      the library importing it fail to compile, and an entry that is not a
#      mojo_library, or is also in `deps`, is refused at analysis.
#  30. Optimization levels, read from each compile command (buck2 aquery,
#      analysis only): mojo_test and a mojo_library's gated tests at -O1,
#      mojo_binary and the shared libraries of a bundle at -O3, a per-target
#      override honoured either way; a level mojo build does not accept is
#      refused at analysis (tools/build/tests/functional/opt_level.sh).
#  31. Lints are part of the build: a planted shellcheck warning in a script
#      the rules run fails the build of a Mojo and a Rust example
#      (tools/build/tests/negative/lint_weld.sh).
#  32. The ./buck2 bootstrap installs only what tools/buck2 pins
#      (tools/build/tests/functional/bootstrap.sh; a made-up release, no network).
#  33a. Conda packages: see tools/build/tests/functional/conda.sh (a package is a
#       directory read back with unzip, zstd, tar and jq; kci's manifest contract;
#       a new library gets its package from the macro with no declaration; the
#       refusals, as targets that build and releases that do not; the stamp; two
#       uncached builds, skipped with --no-uncached; a pixi install from a
#       file:// channel and a Mojo program importing the library, skipped
#       without pixi or network, a FAIL instead with --require-install, as the
#       nightly workflow runs it). tests//functional/install_gate:cases holds
#       that switch: no pixi on PATH is a SKIP line, and a FAIL line with it.
#  33b. The conda package set and metapackage: see tools/build/tests/functional/conda_set.sh
#       (every library's package target builds; the stamped releases; the metapackage
#       from the members' manifests; kci's own parser over the emitted manifests; the
#       refusals; two uncached builds, skipped with --no-uncached; a pixi install of
#       the metapackage alone, skipped or failed as in 33a).
#  33. The client is Linux x86_64: several tests run binaries built for the
#      farm, and ELF tools, on this machine, so on any other client this
#      script stops before it builds anything (exit 2). `--host-check-only`
#      stops after that test; run with a `uname` reporting macOS arm64 it must
#      refuse, and with this machine's, pass.
#  34. aws-client-gen (tests//functional/aws_codegen): the CloudWatch Logs
#      GetLogEvents module, pure and client, a restJson1 client of a tiny
#      model, a restXml module of a tiny S3-shaped model (pure, with the `s3`
#      customization), an awsQuery module of a tiny model (pure and client),
#      an ec2Query module of a tiny model (pure), and the layout probe of
#      each, equal their text goldens byte for byte; the generator refuses
#      an empty or missing operation list, an operation the model lacks, a
#      protocol it does not implement, a
#      restXml model reaching a union, an XML attribute or a body map, the
#      `s3` customization unless the model's serviceId is `S3` and its
#      protocol restXml, or an unknown customization, a
#      missing, malformed (not 64 lowercase hex digits) or wrong
#      --model-sha256, a zero-byte model, and --probe-import without
#      --probe-out, and writes no file when it refuses. A golden that
#      differs, and a refusal check given inputs the generator accepts, both
#      go red (tests//negative/aws_codegen). Each client module (logs, the
#      tiny restJson1 and the tiny awsQuery model) must also contain, as
#      whole lines, the strings its must_contain names (the caller's
#      HttpClientConfig reaching the send); a must_contain whose lines the
#      module holds only non-adjacently, or only as the tail of a longer
#      line, goes red, and for no other reason. The tiny models' clients
#      built in the komira cell (komira//tools/build/proto-codegen/
#      aws_rest_json and aws_rest_xml, pure; aws_query, the awsQuery client
#      pure and client mode and the ec2Query client pure) generated exactly
#      their files, and exactly their welded tests ran: see test 36.
#  35. Rust tests are part of the build (tools/build/rust, `rust_test`): the
#      inline tests of komira_proto_codegen run as a build action and pass,
#      every one counted. In tests//negative/rust_test a failing #[test]
#      makes the test, a binary welded to it, and a binary linking a library
#      welded to it unbuildable (GATED TEST FAILED, with the harness's
#      `1 passed; 1 failed`: the panic unwound), while the test executable
#      itself compiles; a binary welded to a passing test builds and runs;
#      the harness sees only HOME, PATH and TMPDIR; a target with no tests
#      and an #[ignore]d test are each refused; a hanging test is NO VERDICT
#      at its timeout. There are no holds: every welded test must pass.
#      `buck2 test` of a welded library runs its rust_test (Pass, with the
#      harness's count), and of a binary welded to a red test fails.
#  36. mojo_aws_client (tools/build/cloud/aws.bzl; tests//functional/mojo_aws_client): a
#      pure-mode CloudWatch Logs client generated from the pinned botocore
#      model with operations = [GetLogEvents], over stub runtime deps, builds
#      only once its welded tests pass: the generated layout probe, then a
#      caller test of the encoded request (body, X-Amz-Target) and a decoded
#      response. GetLogEvents' error shapes have no members in that model, so
#      the error-shape check pins only that the generated shape is memberless
#      (it decodes nothing); an error's code and message are read by
#      komira_aws_core, stubbed here, and are tested in
#      komira//src/komira_aws_core. Generated code compiled against the
#      real komira_aws_core and komira_json: the AWS conformance driver, and
#      a pure-mode restJson1 client of a tiny model
#      (komira//tools/build/proto-codegen/aws_rest_json), which builds only
#      once its layout probe and a caller test of the requests it builds and
#      the responses it reads pass; and a pure-mode restXml client of a tiny
#      S3-shaped model with the `s3` customization
#      (komira//tools/build/proto-codegen/aws_rest_xml), likewise, against
#      komira_aws_core and komira_xml; and in
#      komira//tools/build/proto-codegen/aws_query, a pure-mode awsQuery and
#      a pure-mode ec2Query client of two tiny models, likewise, against
#      komira_aws_core and komira_xml, and a client-mode awsQuery client,
#      which builds only once its layout probe and a caller test over a
#      scripted connector and komira_aws_core's echo connector pass. For
#      each, exactly its files are generated, nothing of an operation not
#      named, and exactly its welded tests ran (the layout probe, the
#      environment scan mojo_aws_client writes, the caller's). A second
#      client adds a hand_srcs module and the overrides manifest naming it:
#      the module is copied into the package, the header names its owner,
#      and a caller test imports it. A client-mode client (tests//functional/aws_client_mode)
#      carries the signed-send surface, the komira_http_core and
#      komira_http_client imports, the constructor's HttpClientConfig and
#      the error builder, and builds against the same stubs with their client
#      half, once its layout probe and a caller test of what its send hands
#      the transport (the caller's HttpClientConfig included) and of its
#      error builder pass. Refused at
#      analysis: empty, joined or repeated `operations`, empty `deps`,
#      `overrides` without `hand_srcs` and the reverse, a hand_srcs entry
#      that is a label, not `.mojo`, or named like a generated file, and a
#      model path the service id cannot be read from, and a caller
#      `test_data` entry for the environment scan; an operation the model
#      lacks by the generator; a failing caller test reds the client; and so
#      does a hand-written module of the package that reads HOME, through
#      the environment scan (tests//negative/mojo_aws_client): by a banned
#      name, or by an import of std.pathlib off its allow-list, which it reads
#      at the start of a line, at an indent, after a `;`, after a one-line
#      function's `:`, and as the second name of a plain `import` list,
#      after a backtick name holding a quote or `#`, after a string (one or
#      three quotes, raw or not) holding an escaped quote, and joined after a
#      backslash-ended line; a file with a t-string (prefix `t`, `T`, `tr`,
#      `Rt`) or an ASCII control byte other than a tab or a line feed (a
#      carriage return, lone or after a backslash, a vertical tab or a form
#      feed after an import) is refused;
#      the same text in a docstring, a comment or a string is not an import
#      (the hand_srcs client of tests//functional/mojo_aws_client builds).
#  37. The platform table (tools/build/platforms/table.bzl, one row per
#      (os, cpu)) is complete and the default target platform is the client's
#      own: loading tests//functional/platform_table: runs the load-time
#      cases (a table missing a pin or a field, with a pending pin in a
#      registered row, a malformed sha256 or a duplicate key or host is
#      refused naming the row and the pin; each host_info() selects its row);
#      `platforms:host` is linux-x86_64 on this client and a target stating no
#      --target-platforms is configured for it; the reserved linux-arm64 row
#      has no platform and its `[komira_re]` key is refused
#      (tools/build/tests/functional/platform_table/check.sh).
#  38. README examples (tools/build/mojo/README.md#readme-examples): the
#      examples of tests//functional/readme_examples/ok run and its marker is
#      PASS; a README with no example (.../none) compiles and runs nothing,
#      its marker NO EXAMPLE; tests//negative/readme_examples fail naming the
#      README line of a raising example, a compile error and a `mojo skip` fence.
#      A README that ships (its library has a conda package) refuses a relative
#      link naming its line (.../relative_link); the same README in a library
#      with `conda = False` builds (tests//functional/readme_examples/unshipped).
#      Two libraries, one README (`readme`, tools/build/mojo/readme.bzl):
#      .../owner builds with the README on :owner only (`readme = False` on
#      :owner_base, which has no [tests][readme]); without the keyword
#      (tests//negative/readme_examples/unowned) the base library's README
#      compile fails; `readme = True` with no README.md and a non-bool
#      `readme` are refused at load (.../readme_keyword, per -c case).
#  39. Test welding (tools/build/lint/test_weld.bzl), each lint checked by
#      its BXL script: //:test_weld (every package under src/) and
#      tests//functional/test_weld:ok (a planted tree with its ledger) pass;
#      each target of tests//negative/test_weld fails
#      naming its one planted finding: an unwelded test file (named only in a
#      comment of a test_srcs list), a package with no welded test, a ledger
#      row for a welded test or package (the ledger only shrinks; one test is
#      welded only by a computed list), a row naming nothing, a row with no
#      reason, and a root with no package.
#  40. README API coverage (tools/build/lint/readme_api_coverage.bzl;
#      docs/readme_api_coverage.md): //:readme_api_coverage (the census of
#      every package under src/ but the test-only ones, report-only) and
#      tests//functional/readme_api_coverage:ok (a planted tree whose census
#      must equal its expected files, counts and statuses exactly) build; each
#      target of tests//negative/readme_api_coverage fails naming its one
#      planted finding: a malformed ledger row, a repeated row, a row for a
#      symbol not exported, a row for a symbol the README uses (the ledger
#      only shrinks), an undocumented symbol under `enforce = True`, and a
#      root with no package.

#  41. Coverage builds: see tools/build/tests/coverage_tests.sh.
#  42. The pointer lint (tools/build/lint/defs.bzl, pointer_lint;
#      docs/design/mojo_safety_and_idioms.md): //:pointer_lint (every .mojo
#      file of the cell, against tests/pointer_lint_ffi.tsv and
#      tests/pointer_lint_holds.tsv) and tests//functional/pointer_lint:ok (a
#      planted tree whose every site is held at its exact count, beside near
#      misses) build; each target of tests//negative/pointer_lint fails naming
#      its one planted site (each rule, the two-statement partial move, a
#      public method and __init__.mojo, a library file of a test-only package
#      under src/tests/<kind>/, one site over a hold, a non-origin
#      site in an FFI module, an unlisted marked module) or ledger defect,
#      an empty tree fails as checking nothing, and a target naming no tree
#      is refused at analysis.
#  43. Coverage runs: see tools/build/tests/coverage_run_tests.sh.
#  52. API JSON (tools/build/mojo/doc.bzl, mojo_doc_json):
#      //tools/build/examples:hellopkg_doc (in test 1) equals its golden;
#      tests//functional/mojo_doc_json:docpkg_doc resolves an import through
#      `deps` and declares a path of each kind the symbol check walks; each
#      target of tests//negative/mojo_doc_json fails naming its defect: a
#      source that does not compile, a golden that differs, and three paths
#      the JSON does not declare.
#  44. The public boundary lint: see tools/build/tests/public_boundary_tests.sh.
#  45. The layout of src/ (tools/build/lint/defs.bzl, src_layout): //:src_layout
#      (every package under src/, read from the build graph) and
#      tests//functional/src_layout:ok (a planted list) build; each target of
#      tests//negative/src_layout fails naming its one planted finding: an
#      *_e2e, *_loopback or *_conformance package directly under src/, an
#      unshipped komira_test_* there, a stale `shipped` name, a package nested
#      where none is, a src/tests kind it does not hold or a package not at
#      src/tests/<kind>/<name>, a package under the wrong kind, and a root with
#      no package. With a module map (`map`; //:src_layout reads
#      docs/architecture.md): a package with no row, a row naming no package,
#      a second row for a package, and a row whose name is not its link's.
#  46. The coverage gate and what ships waits for it: tools/build/tests/coverage_gate_tests.sh (sourced by 43's).
#  47. Branch coverage runs: tools/build/tests/coverage_branch_tests.sh (sourced by 43's).
#  49. Assert level, defines and memory cap: see
#      tools/build/tests/assert_level_tests.sh.
#  51. Python oracles (tools/build/python/defs.bzl, python_oracle): each
#      target of tests//negative/python_oracle fails analysis naming the
#      input an action built outside third_party/ (a komira library's
#      package as data, a komira binary in srcs or as src, a wheel installed
#      outside third_party/ as a dep or as the tzdata wheel, an interpreter
#      unpacked outside third_party/).
#      What works is in src/tests/helpers/komira_test_python.
#  53. The surface capability matrix (tools/build/lint/surface_capability_matrix.bzl;
#      docs/surface_capability_matrix.md): //:surface_capability_matrix (every
#      surface and capability of the plan, against tests/surface_capability_matrix.bzl)
#      and tests//functional/surface_capability_matrix:ok (a planted matrix,
#      three cells filled by planted surface e2e targets, whose census must
#      equal its expected files) build; each target of
#      tests//negative/surface_capability_matrix fails naming its one planted
#      defect: a target that does not exist, a repeated pair, an unknown
#      capability or surface, a target in another surface's package, outside
#      src/tests/e2e, in a subpackage or a longer-named package, an alias of a
#      test elsewhere, a target that is no test (a file, a mojo_library that
#      welds none), one test filling two cells of a surface, a pair with no
#      row, an empty field, a capability grounded in no declared constant, a
#      family constant no capability names or in a form the lint cannot read,
#      a repeated capability, fewer filled cells than the floor, no surface,
#      and (built by package pattern) a test incompatible with the lint's
#      platform.
#  54. The hermetic Node.js rules (tools/build/node/defs.bzl): each target of
#      tests//negative/node and below fails with its planted defect: a failing
#      script, a wrong expected error or an unexpected pass, a path or package
#      staged twice, an unresolved import, an empty expect_error or exe, a pin
#      that differs, a C warning, the test-only runtime named where it is not
#      visible. See tools/build/tests/node_tests.sh.
#  55. Refused imports (tools/build/lint/defs.bzl, mojo_deps refused_imports;
#      tools/build/lint/refused_imports.awk): tests//functional/refused_imports:ok
#      (each refused module spelt where it is no import of it: comments,
#      docstrings, string literals, longer module names, a name imported
#      from another module) builds; each target of
#      tests//negative/refused_imports fails naming exactly its one finding
#      (from M, from M.sub, from P import N, parentheses over lines with a
#      parenthesis in a comment, import M, M as p, M.sub, an import list,
#      `;` statements, a `\` continuation, an indented import, an import
#      after a docstring, after a docstring holding the other triple quote,
#      after a triple quote inside a one-line string, `from`/`import` with
#      spaces around the dot, a dotted reference with no import of the module
#      (plain, spaced, continued by `\`, over lines inside parentheses,
#      through an `as` alias of its parent, through a name a from-import
#      bound)), and an entry that is not a dotted komira_* module name is
#      refused at analysis.
set -uo pipefail

umbrella=1
run=1
uncached=1
require_install=0
host_only=0
for a in "$@"; do
    case "$a" in
        --no-umbrella) umbrella=0 ;;
        --no-run) run=0 ;;
        --no-uncached) uncached=0 ;;
        --require-install) require_install=1 ;;
        --host-check-only) host_only=1 ;;
        *) echo "usage: $0 [--no-umbrella] [--no-run] [--no-uncached] [--require-install] [--host-check-only]" >&2; exit 2 ;;
    esac
done

# Several tests run what the farm built for Linux x86_64 (the inspect tool,
# the example binaries and bundles) and readelf/objdump on this machine. On
# another client they would fail one by one, looking like defects; stop here
# instead. `./buck2 build //...` and `./buck2 test //...` work from any client.
client=$(uname -s) arch=$(uname -m)
# komira-limit:run-tests-linux-x86-64-client
if [ "$client $arch" != "Linux x86_64" ]; then
    echo "run_tests.sh: needs a Linux x86_64 client, this is $client $arch: the tests run Linux x86_64 binaries and ELF tools here. ./buck2 build //... and ./buck2 test //... run from any client." >&2
    exit 2
fi
if [ "$host_only" = 1 ]; then
    echo "run_tests.sh: client $client $arch"
    exit 0
fi

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
if [ -z "${BUCK2:-}" ]; then
    BUCK2="$ROOT/buck2"
fi
# Logs, and the scratch checkouts of tests 7 and 9, go under $TMPDIR. Where
# /tmp is memory, point TMPDIR at a disk directory. The checkouts are deleted
# on exit, pass or fail (KEEP_SCRATCH=1 keeps them); logs are kept.
LOG=$(mktemp -d "${TMPDIR:-/tmp}/komira_tests.XXXXXX")
export INSPECT_LOG="$LOG/inspect_build.log"
. "$ROOT/tools/build/tests/tool_lib.sh"
fails=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
needs_remote() { echo "SKIP  $1: needs a remote-execution service; this run is local-only (DEVELOPMENT.md, step 3)"; }

# Local or remote: read from the executor of every execution platform buck2
# registers, so `-c`, a user buckconfig and `.buckconfig.local` all count.
EP=$(cfg_value build.execution_platforms)
if [ -z "$EP" ] || ! "$BUCK2" audit providers "$EP" > "$LOG/mode.txt" 2>> "$LOG/mode.err"; then
    echo "FAIL  mode: cannot read the registered execution platforms (see $LOG/mode.err)"
    exit 1
fi
n_platforms=$(grep -c 'executor_config=' "$LOG/mode.txt")
n_local=$(grep -c 'executor: Local(' "$LOG/mode.txt")
if [ "$n_platforms" = 0 ]; then
    echo "FAIL  mode: $EP registers no execution platform (see $LOG/mode.txt)"
    exit 1
elif [ "$n_local" = "$n_platforms" ]; then
    MODE=local
    EXEC_RE='^local'
    echo "MODE  local: no remote-execution service is configured, so every action of these tests runs on this machine ($n_platforms local execution platforms from $EP)."
    echo "      Skipped here, they need one: 7 umbrella cache, 9 buck2 run, 12 action platforms, 24 macOS. To run them, configure .buckconfig.local (DEVELOPMENT.md, step 3)."
elif [ "$n_local" = 0 ]; then
    MODE=remote
    EXEC_RE='^(re\(|cache)'
    echo "MODE  remote: every action runs on the remote-execution service in .buckconfig.local ($n_platforms remote execution platforms from $EP)."
else
    echo "FAIL  mode: $EP mixes $n_local local and $((n_platforms - n_local)) remote execution platforms; these tests expect one kind (see $LOG/mode.txt)"
    exit 1
fi
export KOMIRA_CHECKS_MODE=$MODE

expect_green() { # name, targets...
    local name=$1; shift
    if "$BUCK2" build "$@" > "$LOG/$name.log" 2>&1; then pass "$name"; else fail "$name (see $LOG/$name.log)"; fi
}

expect_red() { # name, required text, target
    local name=$1 text=$2 target=$3
    if "$BUCK2" build "$target" > "$LOG/$name.log" 2>&1; then
        fail "$name: $target built, but it must fail"
    elif grep -qF -- "$text" "$LOG/$name.log"; then
        pass "$name"
    else
        fail "$name: failed without '$text' (see $LOG/$name.log)"
    fi
}

EXAMPLES=(
    //tools/build/examples:hello //tools/build/examples:hellopkg //tools/build/examples:hello_pkg_user
    //tools/build/examples/libgate_ok:libgate_ok //tools/build/examples:test_hellopkg
    //tools/build/examples:hellopkg_doc
    //tools/build/mojo/runtime_paths:komira_runtime_paths
    //tools/build/examples:hello_bundle //tools/build/package:level_test
    //tools/build/examples/cshim:add //tools/build/examples/cshim:cadd
    //tools/build/examples/cshim:cadd_user //tools/build/examples/cshim:test_add_direct
    //third_party/snappy:snappy //tools/build/examples/snappy:test_snappy
    //tools/build/examples/shared_lib:spike //tools/build/examples/shared_lib:spike_exact //tools/build/examples/shared_lib:plain //tools/build/examples/shared_lib:plain_exact //tools/build/examples/shared_lib_mid:mid
)
# Sub-targets are built in their own invocation. (`buck2 build //... 'T[sub]'`
# was observed to skip the sub-target, so never rely on combining them with a
# recursive pattern.)
RUN_CHECKS=("//tools/build/examples:hello[run_check]" "//tools/build/examples:hello_pkg_user[run_check]"
    "//tools/build/examples/cshim:cadd_user[run_check]")

# Each execution platform enables one executor, remote or local; this reads
# the build log to confirm every action used it. Only meaningful when
# something executed: an invocation with nothing to do proves nothing, and
# says so.
check_executor() { # name
    local name=$1 executed
    if ! "$BUCK2" log what-ran > "$LOG/$name.what_ran.txt" 2>&1; then
        fail "$name: cannot read what-ran"
        return
    fi
    executed=$(awk -F'\t' 'NF >= 3' "$LOG/$name.what_ran.txt" | wc -l)
    if awk -F'\t' -v re="$EXEC_RE" 'NF >= 3 && $3 !~ re' "$LOG/$name.what_ran.txt" | grep -q .; then
        fail "$name: an action ran outside $MODE execution (see $LOG/$name.what_ran.txt)"
    elif [ "$executed" = 0 ]; then
        echo "SKIP  $name: nothing executed in this invocation, $MODE-only not re-observed"
    elif [ "$MODE" = local ]; then
        pass "$name: all $executed executed actions ran locally"
    else
        pass "$name: all $executed executed actions were remote runs or remote cache hits"
    fi
}

# 1
expect_green examples "${EXAMPLES[@]}"
check_executor examples
expect_green run_checks "${RUN_CHECKS[@]}"
check_executor run_checks

# 2
expect_red gate_red "GATED TEST FAILED" tests//negative/libgate_bad:libgate_bad
expect_green gate_ungated_green "tests//negative/libgate_bad:libgate_bad[ungated]"
expect_red gate_consumer_red "GATED TEST FAILED" tests//negative/libgate_bad:gated_consumer
expect_red gate_bypass_refused "MojoInfo" tests//negative/libgate_bad:bypass_consumer

# 2 (mojo_shared_lib): the gate refuses to publish a library whose compile is green
for t in missing_export unresolved_symbol failing_driver forced_not_loaded leaks_by_default plain_leaks; do
    expect_green "sharedlib_${t}_ungated" "tests//negative/shared_lib:${t}[ungated]"
done
expect_red sharedlib_missing_export_red "MISSING EXPORT: neg_missing" tests//negative/shared_lib:missing_export
expect_red sharedlib_unresolved_red "undefined symbol: komira_neg_undefined_symbol" tests//negative/shared_lib:unresolved_symbol
expect_red sharedlib_driver_red "GATED TEST FAILED" tests//negative/shared_lib:failing_driver
expect_red sharedlib_force_load_red "MISSING EXPORT: komira_spike_forced" tests//negative/shared_lib:forced_not_loaded
expect_red sharedlib_leaks_by_default_red "komira_example_add leaked into the dynamic symbol table" tests//negative/shared_lib:leaks_by_default
expect_red sharedlib_plain_leaks_red "plain_hidden leaked into the dynamic symbol table" tests//negative/shared_lib:plain_leaks
expect_red sharedlib_empty_exports_refused "exports\` is empty" tests//negative/shared_lib:empty_exports
expect_red sharedlib_duplicate_definition_red "duplicate symbol: komira_neg_dup" tests//negative/shared_lib:duplicate_definition

# 3
# Its red depends on the executor staging only declared inputs. A local action
# is not sandboxed and runs in the checkout root, where the compiler might find
# hellopkg's source without the dep; nobody has measured whether it does, so a
# local run does not quote this test as a gate.
if [ "$MODE" = local ]; then
    echo "SKIP  missing_dep: needs remote input isolation; a local action is not sandboxed and may see the undeclared package in the checkout (DEVELOPMENT.md, step 4)"
else
    expect_red missing_dep "unable to locate module 'hellopkg'" tests//negative/missing_dep:missing_dep
fi

# 4
expect_red closure_refusal "REFUSING: toolchain member" tests//negative/closure_refusal:hello_incomplete_toolchain

# 5
# The scan covers the Rust and protobuf actions too (rustc, protoc, the
# plugin, the generated packages), and aws-lc's and s2n-tls's.
SCAN_TARGETS=(//tools/build/examples/rust:prost_roundtrip
    tests//functional/proto:test_person tests//functional/proto:team_proto
    //tools/build/examples/aws_lc:test_aws_lc //tools/build/examples/s2n_tls:test_s2n_handshake)
SCAN=("${EXAMPLES[@]}" "${RUN_CHECKS[@]}" "${SCAN_TARGETS[@]}")
query="deps(set($(printf '"%s" ' "${SCAN[@]}")))"
abs_path_re="[\"' =:]/[A-Za-z][A-Za-z0-9_.-]*"
# The closure holds libraries with a README (komira_runtime_paths among
# them, and komira libraries the examples import). aquery cannot run a
# README's generate step (a local-only dynamic action) and fails on it unless
# this daemon has already built it, so the scan builds what it reads first
# rather than depend on an earlier test having done so. Sub-targets get their
# own invocation (see RUN_CHECKS). The builds keep going and their failure is
# not this test's: a target that does not build is reported by the tests that
# build it, and the scan still reads every action aquery can reach (it fails,
# and names the build log, only if that leaves a README unbuilt).
host_paths_built=yes
"$BUCK2" build --keep-going "${EXAMPLES[@]}" "${SCAN_TARGETS[@]}" > "$LOG/host_paths_build.log" 2>&1 || host_paths_built=no
"$BUCK2" build --keep-going "${RUN_CHECKS[@]}" >> "$LOG/host_paths_build.log" 2>&1 || host_paths_built=no
if ! printf '%s\n' "\"cmd\": \"['/bin/sh', 'x']\"" | grep -qE "$abs_path_re"; then
    fail "host paths: the scan pattern does not detect a planted absolute path"
elif ! "$BUCK2" aquery "$query" --output-attribute cmd --output-attribute env --json > "$LOG/aquery.json" 2> "$LOG/aquery.err"; then
    fail "host paths: aquery failed (see $LOG/aquery.err; building the scanned targets succeeded: $host_paths_built, see $LOG/host_paths_build.log)"
elif ! grep -q '"cmd"' "$LOG/aquery.json"; then
    fail "host paths: aquery returned no commands"
elif grep -oE "$abs_path_re" "$LOG/aquery.json" > "$LOG/abs_paths.txt"; then
    fail "host paths: absolute paths in action commands: $(sort -u "$LOG/abs_paths.txt" | tr '\n' ' ')"
else
    pass "host paths: no absolute path in $(grep -c '"cmd"' "$LOG/aquery.json") action commands$([ "$host_paths_built" = yes ] || echo " (some scanned targets did not build; see $LOG/host_paths_build.log)")"
fi

# 6
if ! "$BUCK2" build //tools/build/examples:hello --materializations all --show-full-simple-output > "$LOG/outputs.txt" 2> "$LOG/outputs.log"; then
    fail "outputs: cannot materialize //tools/build/examples:hello (see $LOG/outputs.log)"
else
    bin=$(tail -n 1 "$LOG/outputs.txt")
    if [ ! -s "$bin" ]; then
        fail "outputs: no binary at '$bin'"
    elif ! grep -qa 'libKGENCompilerRTShared' "$bin"; then
        fail "outputs: scan cannot see the binary's dynamic section (no NEEDED name found)"
    elif ! command -v readelf > /dev/null; then
        fail "outputs: readelf is not installed; cannot read the run path"
    elif [ "$(readelf -d "$bin" | grep -E 'RPATH|RUNPATH' | sed -E 's/.*\((RPATH|RUNPATH)\).*\[(.*)\]$/\1 \2/')" != 'RUNPATH $ORIGIN/lib' ]; then
        fail "outputs: $bin run path is not exactly RUNPATH \$ORIGIN/lib: $(readelf -d "$bin" | grep -E 'RPATH|RUNPATH' | tr -s ' ')"
    elif grep -qa 'buck-out/' "$bin"; then
        fail "outputs: $bin names a buck-out path: $(grep -ao '[^[:cntrl:]]*buck-out/[^[:cntrl:]]*' "$bin" | head -n 1)"
    else
        pass "outputs: $bin has run path \$ORIGIN/lib only and names no buck-out path"
    fi
fi

# 8
GLIBC_FLOOR="/lib64/ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0"
if ! "$BUCK2" build tests//functional/runtime_libs:loader_trace --show-full-simple-output > "$LOG/loader.txt" 2> "$LOG/loader.log"; then
    fail "host floor: loader trace failed (see $LOG/loader.log)"
else
    report=$(tail -n 1 "$LOG/loader.txt")
    problems=""
    for phase in compile run; do
        grep -qx "$phase rc=0" "$report" || problems="$problems $phase-did-not-succeed"
        for lib in libstdc++.so.6 libgcc_s.so.1; do
            grep -q "^$phase init <toolchain>/.*/$lib\$" "$report" || problems="$problems $phase:$lib-not-from-toolchain"
        done
    done
    # Every object mapped from outside the toolchain must be glibc's.
    while read -r _ _ path; do
        case "$path" in "<toolchain>/"*) continue ;; esac
        ok=0
        for g in $GLIBC_FLOOR; do
            case "$path" in "$g" | */"$g") ok=1 ;; esac
        done
        [ "$ok" = 1 ] || problems="$problems host:$path"
    done < <(grep ' init ' "$report")
    if [ -n "$problems" ]; then
        fail "host floor:$problems (see $report)"
    else
        pass "host floor: libstdc++/libgcc_s from the toolchain in compile and run; host objects only glibc ($(grep -c ' init ' "$report") mapped)"
    fi
    # What the run loaded from the toolchain must be what a runnable directory ships.
    sed -n 's|^run init <toolchain>/lib/||p' "$report" | LC_ALL=C sort > "$LOG/runtime_loaded.txt"
    if ! "$BUCK2" build "//tools/build/examples:hello[runnable]" --show-full-simple-output > "$LOG/runnable.txt" 2> "$LOG/runnable.log"; then
        fail "runtime libs: cannot build //tools/build/examples:hello[runnable] (see $LOG/runnable.log)"
    elif ! (cd "$(tail -n 1 "$LOG/runnable.txt")/lib" && ls -1) 2> /dev/null | LC_ALL=C sort > "$LOG/runtime_shipped.txt"; then
        fail "runtime libs: no lib/ in $(tail -n 1 "$LOG/runnable.txt")"
    elif [ ! -s "$LOG/runtime_loaded.txt" ]; then
        fail "runtime libs: the loader trace records no toolchain library for the run"
    elif ! cmp -s "$LOG/runtime_loaded.txt" "$LOG/runtime_shipped.txt"; then
        fail "runtime libs: loaded [$(tr '\n' ' ' < "$LOG/runtime_loaded.txt")] but lib/ ships [$(tr '\n' ' ' < "$LOG/runtime_shipped.txt")]"
    else
        pass "runtime libs: lib/ ships exactly the $(wc -l < "$LOG/runtime_shipped.txt" | tr -d ' ') toolchain libraries a run loads"
    fi
    # Every run path a shipped library carries (vendor DT_RPATH included) must
    # be relative to the library itself, or it names a directory on the
    # machine that built it.
    libdir="$(tail -n 1 "$LOG/runnable.txt")/lib"
    : > "$LOG/runtime_runpaths.txt"
    for so in "$libdir"/*; do
        [ -f "$so" ] || continue
        readelf -d "$so" 2> /dev/null | sed -nE 's/.*\((RPATH|RUNPATH)\).*\[(.*)\]$/\2/p' | tr ':' '\n' |
            sed "s|^|$(basename "$so") |" >> "$LOG/runtime_runpaths.txt"
    done
    if [ ! -s "$LOG/runtime_runpaths.txt" ]; then
        fail "runtime run paths: read none from $libdir; the scan saw nothing"
    elif grep -v -E '^[^ ]+ \$ORIGIN(/|$)' "$LOG/runtime_runpaths.txt" > "$LOG/runtime_runpaths_bad.txt"; then
        fail "runtime run paths: not \$ORIGIN-relative: $(head -n 3 "$LOG/runtime_runpaths_bad.txt" | tr '\n' ' ')"
    else
        pass "runtime run paths: all $(wc -l < "$LOG/runtime_runpaths.txt" | tr -d ' ') run path entries in lib/ are \$ORIGIN-relative"
    fi
fi

# 10
# `buck2 audit execution-platform-resolution` prints, per target, either
# "Execution platform: <label>" or "Failed to configure: ...".
resolve() { # log name, extra args..., targets...: prints "<target> <platform|FAILED>"
    local name=$1; shift
    "$BUCK2" audit execution-platform-resolution "$@" > "$LOG/$name.txt" 2>&1 || return 1
    awk '/^[^ ].* \(.*\):$/ { t = $1; next }
         t != "" && /^  Execution platform: / { print t, $3; t = "" }
         t != "" && /^  Failed to configure/ { print t, "FAILED"; t = "" }' "$LOG/$name.txt"
}
EXPECT_PLATFORMS="
komira//tools/build/examples:hello komira//tools/build/platforms:linux-x86_64
komira//tools/build/examples:hellopkg komira//tools/build/platforms:linux-x86_64
komira//tools/build/examples/libgate_ok:libgate_ok komira//tools/build/platforms:linux-x86_64
komira//tools/build/examples:test_hellopkg komira//tools/build/platforms:linux-x86_64
komira//tools/build/toolchains:zig komira//tools/build/platforms:linux-x86_64
komira//tools/build/toolchains:conda_unpack komira//tools/build/platforms:linux-x86_64
komira//tools/build/toolchains:mojo_compiler komira//tools/build/platforms:linux-x86_64
komira//tools/build/toolchains:mojo_runtime komira//tools/build/platforms:linux-x86_64
komira//tools/build/third_party_srcs:aws-lc-mini.tar.gz komira//tools/build/platforms:linux-x86_64
komira//tools/build/third_party_srcs:aws_lc_mini_gen komira//tools/build/platforms:linux-x86_64
komira//tools/build/third_party_srcs:aws_lc_mini_drift komira//tools/build/platforms:linux-x86_64
komira//third_party/aws-lc:srcs_gen komira//tools/build/platforms:linux-x86_64"
want=$(printf '%s\n' "$EXPECT_PLATFORMS" | sed '/^$/d' | LC_ALL=C sort)
# shellcheck disable=SC2046 # one target label per line, split into arguments on purpose
if ! got=$(resolve platforms $(printf '%s\n' "$want" | cut -d' ' -f1)); then
    fail "exec platforms: audit failed (see $LOG/platforms.txt)"
elif [ "$(printf '%s\n' "$got" | LC_ALL=C sort)" != "$want" ]; then
    fail "exec platforms: resolution differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got" | LC_ALL=C sort) | grep '^>' | tr '\n' ' ') (see $LOG/platforms.txt)"
else
    pass "exec platforms: $(printf '%s\n' "$want" | grep -c .) Mojo and toolchain targets on linux-x86_64"
fi

# 12
re_value() { # key: prints [komira_re] <key> of the root cell
    cfg_value "komira_re.$1"
}
action_platforms() { # what-ran json: every action ran remotely, with the linux set
    local linux acts
    linux=$(props_norm "$LINUX_PROPS")
    acts=$(whatran_actions "$1") || { echo "cannot read $1"; return 1; }
    printf '%s\n' "$acts" | awk -F '\t' -v P="$linux" '
        BEGIN {
            n = split("conda_unpack fixture_archive mojo_build mojo_runtime third_party_srcs zig_build_exe zig_unpack", order, " ")
        }
        NF < 3 { next }
        {
            seen[$1]++; total++
            if ($2 != "Re" || $3 == "-") msg = $1 " ran as " $2 ", not a remote execution"
            else if ($3 != P) msg = $1 " ran with [" $3 "], not the linux set"
            else next
            bad = bad (bad == "" ? "" : "; ") msg
        }
        END {
            for (i = 1; i <= n; i++) if (!(order[i] in seen)) missing = missing " " order[i]
            if (missing != "") bad = bad (bad == "" ? "" : "; ") "not executed:" missing
            if (bad != "") { print bad; exit 1 }
            printf "%d actions, every one a remote execution with [%s]\n", total, P
        }'
}
LINUX_PROPS=$(re_value linux_x86_64_properties)
ISO=komira_tests_uncached
if [ "$MODE" = local ]; then
    needs_remote "action platforms (per-action worker property sets)"
elif [ -z "$LINUX_PROPS" ]; then
    fail "action platforms: cannot read [komira_re] linux_x86_64_properties"
# The isolated daemon keeps its outputs between runs, and --no-remote-cache
# does not rerun an action whose output is already on disk: clean first, or
# a second run of these tests in the same checkout executes nothing.
elif ! "$BUCK2" --isolation-dir "$ISO" clean > "$LOG/uncached_clean.log" 2>&1; then
    fail "action platforms: cannot clean the isolated buck-out (see $LOG/uncached_clean.log)"
elif ! timeout 900 "$BUCK2" --isolation-dir "$ISO" build --no-remote-cache //tools/build/examples:hello //tools/build/third_party_srcs:aws_lc_mini_gen > "$LOG/uncached.log" 2>&1; then
    fail "action platforms: uncached build failed (see $LOG/uncached.log)"
elif ! "$BUCK2" --isolation-dir "$ISO" log what-ran --format json > "$LOG/uncached.what_ran.json" 2>&1; then
    fail "action platforms: cannot read what-ran"
elif ! verdict=$(action_platforms "$LOG/uncached.what_ran.json"); then
    fail "action platforms: ${verdict:-no verdict} (see $LOG/uncached.what_ran.json)"
else
    pass "action platforms: $verdict"
fi
[ "$MODE" = local ] || "$BUCK2" --isolation-dir "$ISO" kill > /dev/null 2>&1

# 13
if "$BUCK2" build tests//functional/bundle_parity:parity --show-full-simple-output > "$LOG/parity.txt" 2> "$LOG/parity.log"; then
    pass "bundle parity: $(tail -n 1 "$(tail -n 1 "$LOG/parity.txt")") between executable and bundle"
else
    fail "bundle parity: $(grep -m1 -E '^[0-9]+ cases' "$LOG/parity.log") (see $LOG/parity.log)"
fi

# 14
if "$BUCK2" build //tools/build/package:level_test --show-full-simple-output > "$LOG/level.txt" 2> "$LOG/level.log"; then
    lt=$(tail -n 1 "$LOG/level.txt")
    ltbin=$("$BUCK2" build '//tools/build/package:level_test[bin]' --show-full-simple-output 2>> "$LOG/level.log" | tail -n 1)
    rc=0; here=$("$ROOT/tools/build/tests/functional/glibc_level.sh" "$ltbin") || rc=$?
    case "$rc" in
    0 | 2) pass "launcher levels: $(grep -c '^ok ' "$lt") made-up CPUs judged as glibc does ($(sed -n 's/^models: //p' "$lt")); $here" ;;
    *) fail "launcher levels: $here (see $LOG/level.log)" ;;
    esac
else
    fail "launcher levels: $(grep -m3 '^BAD' "$LOG/level.log" | tr '\n' ' ')(see $LOG/level.log)"
fi

# 15
bundle_args=()
[ "$uncached" = 1 ] || bundle_args+=(--no-uncached)
BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/bundle.sh" ${bundle_args[@]+"${bundle_args[@]}"} > "$LOG/bundle.log" 2>&1
while IFS= read -r line; do
    case "$line" in
        "PASS  bundle "*) pass "${line#PASS  }" ;;
        "FAIL  bundle "*) fail "${line#FAIL  } (see $LOG/bundle.log)" ;;
        "SKIP  "*) echo "$line" ;;
    esac
done < "$LOG/bundle.log"
grep -qE '^(PASS|FAIL)  bundle ' "$LOG/bundle.log" || fail "bundle: tools/build/tests/functional/bundle.sh reported nothing (see $LOG/bundle.log)"

# 16
BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/formats.sh" > "$LOG/formats.log" 2>&1
while IFS= read -r line; do
    case "$line" in
        "PASS  formats "*) pass "${line#PASS  }" ;;
        "FAIL  formats "*) fail "${line#FAIL  } (see $LOG/formats.log)" ;;
        "SKIP  "*) echo "$line" ;;
    esac
done < "$LOG/formats.log"
grep -qE '^(PASS|FAIL)  formats ' "$LOG/formats.log" || fail "formats: tools/build/tests/functional/formats.sh reported nothing (see $LOG/formats.log)"

# 17
# //:docs is the repository's Markdown: its validation fails on a dead link.
# The negative fixture plants one link per diagnostic beside two that
# resolve; the validation must name each dead one with its reason, and only
# those.
expect_green docs //:docs tests//functional/doc_links:ok
DEAD=(
    'dead.md:4: sub/missing.md (no such file)'
    'dead.md:5: sub/a.md#nope (no heading #nope)'
    'dead.md:6: ../outside.md (leaves the repository)'
    'doc links: 3 of 5 relative links do not resolve'
)
missed=""
if "$BUCK2" build tests//negative/doc_links:dead > "$LOG/doc_links_dead.log" 2>&1; then
    missed="(it built)"
else
    for want in "${DEAD[@]}"; do
        grep -qF "$want" "$LOG/doc_links_dead.log" || missed="$missed [$want]"
    done
fi
if [ -n "$missed" ]; then
    fail "doc links: tests//negative/doc_links:dead must fail naming each planted link; missed $missed (see $LOG/doc_links_dead.log)"
else
    pass "doc links: tests//negative/doc_links:dead fails naming its missing file, bad anchor and escaping link"
fi
# Each package's rules declare its doc_tree, which names its own files (a
# glob stops at a subpackage) and collects its subpackages' doc_trees, so
# //:docs holds every package with no list. A package left out would drop
# its Markdown from the check without a word, and a BUCK file naming its
# doc_tree is the boilerplate the rules replace.
pkgs() { sed -e 's/:[^:]*$//' | LC_ALL=C sort -u; }
if "$BUCK2" uquery '//... + tests//...' > "$LOG/doc_pkgs_all.txt" 2> "$LOG/doc_pkgs.log" &&
   "$BUCK2" uquery 'kind(doc_tree, deps(//:docs))' > "$LOG/doc_pkgs_docs.txt" 2>> "$LOG/doc_pkgs.log"; then
    missing=$(LC_ALL=C comm -23 <(pkgs < "$LOG/doc_pkgs_all.txt") <(pkgs < "$LOG/doc_pkgs_docs.txt") | tr '\n' ' ')
    n=$(pkgs < "$LOG/doc_pkgs_all.txt" | wc -l)
    if [ "$n" -lt 2 ]; then
        fail "doc links: \`uquery //... + tests//...\` found $n packages (see $LOG/doc_pkgs_all.txt)"
    elif [ -n "$missing" ]; then
        fail "doc links: packages with no doc_tree in //:docs: $missing"
    else
        pass "doc links: all $n packages of the komira and tests cells are in //:docs, each through the doc_tree its rules declare"
    fi
else
    fail "doc links: the package queries failed (see $LOG/doc_pkgs.log)"
fi
# The toolchains cell is not in //:docs (the root BUCK says why), so it may
# hold no Markdown.
tc_md=$(cd "$ROOT" && git ls-files -- 'tools/build/cells/*.md' | tr '\n' ' ')
if [ -n "$tc_md" ]; then
    fail "doc links: the toolchains cell, which //:docs does not read, holds Markdown: $tc_md"
else
    pass "doc links: the toolchains cell, which //:docs does not read, holds no Markdown"
fi
# Every BUCK file calls a rule or macro that declares its doc_tree, so none
# names a doc_tree or calls package_docs() itself.
named=$(cd "$ROOT" && git ls-files -- BUCK '*/BUCK' | xargs grep -lE '^[[:space:]]*(doc_tree|package_docs)[(]' | tr '\n' ' ' || true)
if [ -n "$named" ]; then
    fail "doc links: BUCK files name a doc_tree or call package_docs, which the rules declare: $named"
else
    pass "doc links: no BUCK file names a doc_tree; the rules declare each package's"
fi
exc=""
for cell in komira tests; do
    v=$("$BUCK2" audit config --cell "$cell" project.package_boundary_exceptions 2>> "$LOG/doc_pkgs.log") || { exc="$exc $cell:(audit failed)"; continue; }
    v=$(printf '%s\n' "$v" | grep -v '^\[' | grep -v '^ *$' || true)
    [ -z "$v" ] || exc="$exc $cell:[$v]"
done
if [ -n "$exc" ]; then
    fail "package boundaries: [project] package_boundary_exceptions is set:$exc (see $LOG/doc_pkgs.log)"
else
    pass "package boundaries: neither cell sets [project] package_boundary_exceptions"
fi

# 18
# The configuration hashes. The target platform's label and constraints key
# every configuration, and the hash appears in the output paths, and so in
# the digest, of every configured action: moving or renaming
# komira//tools/build/platforms, or changing a constraint, changes every action digest in
# the repository and every repository mounting it (a buck2 upgrade may too).
# The pins make such a change a deliberate edit of this list.
EXPECT_CFGS="
komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be"
want=$(printf '%s\n' "$EXPECT_CFGS" | sed '/^$/d')
if ! "$BUCK2" cquery 'deps(komira//tools/build/examples:hello)' > "$LOG/cfg_hashes.txt" 2>&1; then
    fail "configuration hashes: cquery failed (see $LOG/cfg_hashes.txt)"
elif got=$(grep -oE '\([^ ()]*:[a-z0-9_-]+#[0-9a-f]+\)' "$LOG/cfg_hashes.txt" | tr -d '()' | LC_ALL=C sort -u) \
        && [ "$got" != "$want" ]; then
    fail "configuration hashes moved, so every action digest did: got $(printf '%s' "$got" | tr '\n' ' '); if deliberate, update EXPECT_CFGS (see $LOG/cfg_hashes.txt)"
else
    pass "configuration hashes: linux-x86_64, the only configuration of hello's closure, keeps its pinned hash"
fi

# 19
EXPORTED="tools/build/mojo tools/build/rust tools/build/proto-codegen tools/build/toolchains tools/build/platforms tools/build/package tools/build/examples
    tools/build/cells third_party"
missing=""
for d in $EXPORTED; do [ -d "$ROOT/$d" ] || missing="$missing $d"; done
labels=$(cd "$ROOT" && git ls-files -z $EXPORTED |
    grep -zE '(^|/)(BUCK|[^/]*\.bzl)$' | xargs -0 grep -nE '[a-z_]+//' |
    awk -F: '{ line = $0; sub(/^[^:]*:[^:]*:/, "", line) } line !~ /^[ \t]*#/ { print }' |
    grep -oE '^[^:]*:[0-9]+:|(^|[^a-z_])[a-z_]+//' | tr -d '"(' )
n=$(printf '%s\n' "$labels" | grep -cE '[a-z_]+//$')
foreign=$(printf '%s\n' "$labels" | awk '/:[0-9]+:$/ { at = $0; next } /\/\/$/ { c = $0; sub(/^[^a-z_]*/, "", c); sub(/\/\/$/, "", c); if (c != "komira" && c != "prelude" && c != "toolchains") print at c "//" }')
if [ -n "$missing" ]; then
    fail "exported cells: searched directories missing:$missing"
elif [ "$n" -lt 20 ]; then
    fail "exported cells: only $n cell-qualified labels found, the scan is not reading the rules"
elif [ -n "$foreign" ]; then
    fail "exported cells: labels naming a cell a consuming repository lacks: $(printf '%s' "$foreign" | head -n 5 | tr '\n' ' ')"
else
    pass "exported cells: $n cell-qualified labels in the exported packages name only komira, prelude and toolchains"
fi

# 20
. "$ROOT/tools/build/tests/cxx_tests.sh"

# 21
expect_green location_path "tests//functional/location_path:main[run_check]"

# 22
# shellcheck source=tools/build/tests/rust_tests.sh
. "$ROOT/tools/build/tests/rust_tests.sh"

# 23
# shellcheck source=tools/build/tests/proto_tests.sh
. "$ROOT/tools/build/tests/proto_tests.sh"

# 26 (before 24, which prints its own lines)
# shellcheck source=tools/build/tests/c_libs_tests.sh
. "$ROOT/tools/build/tests/c_libs_tests.sh"

# 24
if [ "$MODE" = local ]; then
    needs_remote "darwin (macOS arm64 builds run on macOS workers of a remote service)"
else
darwin_rc=0
darwin_out=$(cd "$ROOT" && BUCK2="$BUCK2" bash tools/build/tests/functional/darwin/check.sh "$LOG" 2>&1) || darwin_rc=$?
printf '%s\n' "$darwin_out" > "$LOG/darwin.log"
grep -E '^(PASS|FAIL|SKIP)  ' "$LOG/darwin.log"
darwin_fails=$(grep -c '^FAIL  ' "$LOG/darwin.log" || true)
if [ "$darwin_rc" != 0 ] && [ "$darwin_fails" = 0 ]; then
    fail "darwin: tools/build/tests/functional/darwin/check.sh exited $darwin_rc without a FAIL line (see $LOG/darwin.log)"
fi
fails=$((fails + darwin_fails))
fi

# 25
if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/local_default.sh" > "$LOG/local_default.log" 2>&1; then
    pass "local default: $(grep -o 'PASS  local default: .*' "$LOG/local_default.log" | cut -c 22-)"
else
    fail "local default: $(grep -o 'FAIL  local default: .*' "$LOG/local_default.log" | cut -c 22-) (see $LOG/local_default.log)"
fi

# 28
if ! "$BUCK2" build tests//functional/watchdog:cases --show-full-simple-output > "$LOG/watchdog_cases.txt" 2> "$LOG/watchdog_cases.log"; then
    fail "compile watchdog cases: $(grep '^BAD ' "$LOG/watchdog_cases.log" | sort -u | tr '\n' ' ')(see $LOG/watchdog_cases.log)"
else
    report=$(tail -n 1 "$LOG/watchdog_cases.txt")
    ok=$(grep -c '^ok ' "$report" || true)
    if grep -q '^BAD ' "$report" || [ "$ok" -lt 15 ]; then
        fail "compile watchdog cases: $(grep -v '^ok ' "$report" | tr '\n' ' ') ($ok ok; see $report)"
    else
        pass "compile watchdog: $ok stand-in compilers, each killed (124) or left alone as required"
    fi
fi

# 29
expect_green td_declared tests//functional/test_data:declared
expect_red td_undeclared "No such file or directory" tests//negative/test_data:undeclared
expect_red td_undeclared_gate "GATED TEST FAILED: tests//negative/test_data:undeclared:" tests//negative/test_data:undeclared
if timeout 900 "$BUCK2" test tests//functional/test_data:mojo_test_data > "$LOG/td_mojo_test.log" 2>&1; then
    pass "td_mojo_test: buck2 test of a mojo_test with data and env"
else
    fail "td_mojo_test: buck2 test tests//functional/test_data:mojo_test_data failed (see $LOG/td_mojo_test.log)"
fi
if timeout 900 "$BUCK2" test tests//functional/test_data:mojo_test_args > "$LOG/td_mojo_test_args.log" 2>&1; then
    pass "td_mojo_test_args: buck2 test of a mojo_test with args, \$(location) and \$(exe_target) expanded to files it opens"
else
    fail "td_mojo_test_args: buck2 test tests//functional/test_data:mojo_test_args failed (see $LOG/td_mojo_test_args.log)"
fi
expect_green td_mojo_test_args_action tests//functional/test_data:mojo_test_args_action
if timeout 900 "$BUCK2" test tests//negative/test_data:skip_77 > "$LOG/td_skip_77.log" 2>&1; then
    fail "td_skip_77: buck2 test tests//negative/test_data:skip_77 passed, but its test exits 77 (see $LOG/td_skip_77.log)"
elif ! grep -qE "GATED TEST FAILED: [a-z]*//([a-z/]*/)?negative/test_data:skip_77 \(exit 77\)" "$LOG/td_skip_77.log"; then
    fail "td_skip_77: failed without the test's exit 77 (see $LOG/td_skip_77.log)"
elif ! grep -q "Fail 1" "$LOG/td_skip_77.log"; then
    fail "td_skip_77: exit 77 was not counted as a test failure (see $LOG/td_skip_77.log)"
else
    pass "td_skip_77: a mojo_test exiting 77 (SKIP to some harnesses) fails, counted as Fail"
fi
expect_red td_env_bin_lib "GATED TEST FAILED: tests//negative/test_data:env_bin_lib:tests/test_red.mojo" tests//negative/test_data:env_bin_lib
if timeout 900 "$BUCK2" test tests//negative/test_data:env_bin > "$LOG/td_env_bin.log" 2>&1; then
    fail "td_env_bin: buck2 test tests//negative/test_data:env_bin passed, but its test is red (env BIN reached the runner; see $LOG/td_env_bin.log)"
elif grep -qF "test_red: DELIBERATE FAILURE" "$LOG/td_env_bin.log"; then
    pass "td_env_bin: env {BIN: true} does not replace a red mojo_test"
else
    fail "td_env_bin: failed without the test's own failure (see $LOG/td_env_bin.log)"
fi
if ! "$BUCK2" build tests//functional/test_data:runner_cases --show-full-simple-output > "$LOG/runner_cases.txt" 2> "$LOG/runner_cases.log"; then
    fail "gate runner cases: $(grep '^BAD ' "$LOG/runner_cases.log" | sort -u | tr '\n' ' ')(see $LOG/runner_cases.log)"
else
    report=$(tail -n 1 "$LOG/runner_cases.txt")
    ok=$(grep -c '^ok ' "$report" || true)
    if grep -q '^BAD ' "$report" || [ "$ok" -lt 5 ]; then
        fail "gate runner cases: $(grep -v '^ok ' "$report" | tr '\n' ' ') ($ok ok; see $report)"
    else
        pass "gate runner: $ok cases in one action (private TEST_TMPDIR per run; env cannot reach the verdict)"
    fi
fi
expect_red td_bad_dest "holds an empty, \`.\` or \`..\` segment" tests//negative/test_data:bad_dest
expect_red td_bad_dest_clash "is both a file and the directory of" tests//negative/test_data:bad_dest_clash
expect_red td_bad_data_entry "test_data[\"tests/test_nope.mojo\"]: not a test_srcs entry" tests//negative/test_data:bad_data_entry
expect_red td_bad_env_owned "env sets TEST_TMPDIR, which the test runner sets itself" tests//negative/test_data:bad_env_owned
expect_green td_test_deps tests//functional/test_deps:tdlib
expect_red td_test_deps_src "unable to locate module 'tdhelper'" tests//negative/test_deps:src_imports_test_dep
expect_red td_test_deps_consumer "unable to locate module 'tdhelper'" tests//negative/test_deps:consumer_of_test_dep
expect_red td_test_deps_not_mojo "test_deps entry tests//negative/test_deps:not_a_package is not a Mojo package" tests//negative/test_deps:not_mojo
expect_red td_test_deps_also_in_deps "is in both deps and test_deps" tests//negative/test_deps:also_in_deps
expect_red td_bad_env_name "is not a shell variable name" tests//negative/test_data:bad_env_name

# 30
if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/opt_level.sh" "$LOG" > "$LOG/opt_level.log" 2>&1; then
    pass "$(grep -o 'PASS  optimization levels: .*' "$LOG/opt_level.log" | cut -c 7-)"
else
    fail "$(grep -o 'FAIL  optimization levels: .*' "$LOG/opt_level.log" | cut -c 7-) (see $LOG/opt_level.log)"
fi
expect_red opt_bad_level "optimization level \`fast\` is not one of 0, 1, 2, 3" tests//negative/opt_level:bad_level

# 31
if "$ROOT/tools/build/tests/negative/lint_weld.sh" > "$LOG/lint_weld.log" 2>&1; then
    pass "$(grep -m1 '^PASS' "$LOG/lint_weld.log" | cut -c 7-)"
else
    fail "$(grep -m1 '^FAIL' "$LOG/lint_weld.log" | cut -c 7-) (see $LOG/lint_weld.log)"
fi

# 32
if "$ROOT/tools/build/tests/functional/bootstrap.sh" "$LOG/bootstrap" > "$LOG/bootstrap.log" 2>&1; then
    pass "./buck2 bootstrap: $(grep -c '^PASS' "$LOG/bootstrap.log") cases: installs and caches a matching pin, refuses a wrong sha256 or size leaving the cache empty, reads tools/buck2"
else
    fail "./buck2 bootstrap: $(grep '^FAIL' "$LOG/bootstrap.log" | cut -c 18- | tr '\n' ' ')(see $LOG/bootstrap.log)"
fi

# 33a
conda_args=()
[ "$uncached" = 1 ] || conda_args+=(--no-uncached)
[ "$require_install" = 0 ] || conda_args+=(--require-install)
expect_green install_gate tests//functional/install_gate:cases
BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/conda.sh" ${conda_args[@]+"${conda_args[@]}"} > "$LOG/conda.log" 2>&1
while IFS= read -r line; do
    case "$line" in
        "PASS  conda "*) pass "${line#PASS  }" ;;
        "FAIL  conda "*) fail "${line#FAIL  } (see $LOG/conda.log)" ;;
        "SKIP  "*) echo "$line" ;;
    esac
done < "$LOG/conda.log"
grep -qE '^(PASS|FAIL)  conda ' "$LOG/conda.log" || fail "conda: tools/build/tests/functional/conda.sh reported nothing (see $LOG/conda.log)"

# 33b
BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/conda_set.sh" ${conda_args[@]+"${conda_args[@]}"} > "$LOG/conda_set.log" 2>&1
while IFS= read -r line; do
    case "$line" in
        "PASS  conda_set "*) pass "${line#PASS  }" ;;
        "FAIL  conda_set "*) fail "${line#FAIL  } (see $LOG/conda_set.log)" ;;
        "SKIP  "*) echo "$line" ;;
    esac
done < "$LOG/conda_set.log"
grep -qE '^(PASS|FAIL)  conda_set ' "$LOG/conda_set.log" || fail "conda_set: tools/build/tests/functional/conda_set.sh reported nothing (see $LOG/conda_set.log)"

# 33
S="$LOG/uname_shim"
mkdir -p "$S/mac" "$S/here"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac\n' > "$S/mac/uname"
printf '#!/bin/sh\ncase "$1" in -s) echo %s ;; -m) echo %s ;; *) echo %s ;; esac\n' "$(uname -s)" "$(uname -m)" "$(uname -s)" > "$S/here/uname"
chmod +x "$S/mac/uname" "$S/here/uname"
PATH="$S/mac:$PATH" "$ROOT/tools/build/tests/run_tests.sh" --host-check-only > "$LOG/client_mac.log" 2>&1
mac_rc=$?
PATH="$S/here:$PATH" "$ROOT/tools/build/tests/run_tests.sh" --host-check-only > "$LOG/client_here.log" 2>&1
here_rc=$?
if [ "$mac_rc" != 2 ] || ! grep -qF 'needs a Linux x86_64 client, this is Darwin arm64' "$LOG/client_mac.log"; then
    fail "client: on a macOS arm64 client run_tests.sh did not refuse (exit $mac_rc, see $LOG/client_mac.log)"
elif [ "$here_rc" != 0 ]; then
    fail "client: on this client run_tests.sh --host-check-only exited $here_rc (see $LOG/client_here.log)"
else
    pass "client: run_tests.sh refuses a macOS arm64 client (exit 2) and accepts $(uname -s) $(uname -m)"
fi

# 34
expect_green aws_codegen tests//functional/aws_codegen:
expect_red aws_codegen_golden_differs "differs from the golden" tests//negative/aws_codegen:golden_differs
expect_red aws_codegen_accepted "expected a refusal, and the generator exited 0" tests//negative/aws_codegen:accepted
expect_red aws_codegen_missing_contains "does not contain" tests//negative/aws_codegen:missing_contains
expect_red aws_codegen_prefixed_contains "does not contain" tests//negative/aws_codegen:prefixed_contains
# Their modules equal the goldens, so the must_contain check is their only red.
for n in missing_contains prefixed_contains; do
    if grep -qF -- "differs from the golden" "$LOG/aws_codegen_$n.log"; then
        fail "aws_codegen_$n: also red for a golden difference (see $LOG/aws_codegen_$n.log)"
    fi
done

# 35
RT=tests//negative/rust_test
if "$BUCK2" build //tools/build/proto-codegen:komira_proto_codegen_unit --show-full-simple-output > "$LOG/rust_test_unit.txt" 2> "$LOG/rust_test_unit.log"; then
    rt_marker=$(tail -n 1 "$LOG/rust_test_unit.txt")
    if grep -qE '^PASS komira//tools/build/proto-codegen:komira_proto_codegen_unit: [1-9][0-9]* passed$' "$rt_marker"; then
        pass "rust_test_unit: $(cut -d' ' -f3- "$rt_marker")"
    else
        fail "rust_test_unit: marker $rt_marker does not record a passing run: $(cat "$rt_marker")"
    fi
else
    fail "rust_test_unit (see $LOG/rust_test_unit.log)"
fi
expect_green rust_test_compiles "$RT:red[bin]"
expect_red rust_test_red "GATED TEST FAILED: tests//negative/rust_test:red" "$RT:red"
expect_red rust_test_unwinds "1 passed; 1 failed" "$RT:red"
expect_red rust_test_bin_red "GATED TEST FAILED" "$RT:bin"
expect_red rust_test_lib_consumer_red "GATED TEST FAILED" "$RT:lib_consumer"
expect_green rust_test_bin_green "$RT:bin_green" "$RT:bin_green[run_check]"
expect_red rust_test_empty "EMPTY GATE" "$RT:empty"
expect_red rust_test_ignored "#[ignore]d test(s) did not run" "$RT:ignored"
expect_green rust_test_env_scrubbed "$RT:env_scrubbed"
expect_red rust_test_hang "timed out after 3s (exit 142)" "$RT:hang"
if "$BUCK2" test //tools/build/proto-codegen:komira_proto_codegen > "$LOG/rust_test_buck2_test.log" 2>&1 &&
    grep -qE 'PASS komira//tools/build/proto-codegen:komira_proto_codegen_unit: [1-9][0-9]* passed' "$LOG/rust_test_buck2_test.log"; then
    pass "rust_test_buck2_test: $(grep -m1 -oE 'komira_proto_codegen_unit: [0-9]+ passed' "$LOG/rust_test_buck2_test.log")"
else
    fail "rust_test_buck2_test: buck2 test of the welded library did not run its tests (see $LOG/rust_test_buck2_test.log)"
fi
if "$BUCK2" test "$RT:bin" > "$LOG/rust_test_buck2_test_red.log" 2>&1; then
    fail "rust_test_buck2_test_red: buck2 test $RT:bin passed, but its welded test fails"
elif grep -qF "GATED TEST FAILED: tests//negative/rust_test:red" "$LOG/rust_test_buck2_test_red.log"; then
    pass "rust_test_buck2_test_red"
else
    fail "rust_test_buck2_test_red: failed without the GATED TEST FAILED line (see $LOG/rust_test_buck2_test_red.log)"
fi

# 36
expect_green mojo_aws_client tests//functional/mojo_aws_client:
expect_green aws_rest_json //tools/build/proto-codegen/aws_rest_json:
expect_green aws_rest_xml //tools/build/proto-codegen/aws_rest_xml:
expect_green aws_query //tools/build/proto-codegen/aws_query:
expect_red aws_client_no_operations '`operations` is empty' tests//negative/mojo_aws_client:no_operations
expect_red aws_client_joined_operations 'is not a botocore operation name' tests//negative/mojo_aws_client:joined_operations
expect_red aws_client_no_runtime '`deps` is empty' tests//negative/mojo_aws_client:no_runtime
expect_red aws_client_unknown_operation 'declares no operation(s) ["GetLogEvent"]' tests//negative/mojo_aws_client:unknown_operation
expect_red aws_client_caller_test_red 'GATED TEST FAILED: tests//negative/mojo_aws_client:caller_test_red:test_logs_deliberate_failure.mojo' tests//negative/mojo_aws_client:caller_test_red
expect_green aws_client_mode tests//functional/aws_client_mode:
expect_red aws_client_duplicate_operation '`operations` names `GetLogEvents` twice' tests//negative/mojo_aws_client:duplicate_operation
expect_red aws_client_overrides_without_hand_srcs '`overrides` is set and `hand_srcs` is empty' tests//negative/mojo_aws_client:overrides_without_hand_srcs
expect_red aws_client_hand_srcs_without_overrides '`hand_srcs` is set and `overrides` is not' tests//negative/mojo_aws_client:hand_srcs_without_overrides
expect_red aws_client_hand_src_is_label '`hand_srcs` entry `:hand_owner_label` is not a source path of a `.mojo` file' tests//negative/mojo_aws_client:hand_src_is_label
expect_red aws_client_hand_src_not_mojo '`hand_srcs` entry `hand/notes.txt` is not a source path of a `.mojo` file' tests//negative/mojo_aws_client:hand_src_not_mojo
expect_red aws_client_hand_src_clashes 'has the name of a generated or another hand-written file, `_layout_probe.mojo`' tests//negative/mojo_aws_client:hand_src_clashes
expect_red aws_client_service_unreadable 'the botocore service id cannot be read from the model path' tests//negative/mojo_aws_client:service_unreadable
expect_red aws_client_env_read_hand 'env_reader.mojo names getenv; a mojo_aws_client package takes every input as a parameter' tests//negative/mojo_aws_client:env_read_hand
expect_red aws_client_env_read_home "env_home.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_home
expect_red aws_client_env_read_std_os 'env_std_os.mojo names expanduser; a mojo_aws_client package takes every input as a parameter' tests//negative/mojo_aws_client:env_read_std_os
expect_red aws_client_env_read_semicolon "env_semicolon.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_semicolon
expect_red aws_client_env_read_import_as "env_import_as.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_import_as
expect_red aws_client_env_read_indented "env_indented.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_indented
expect_red aws_client_env_read_compound "env_compound.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_compound
expect_red aws_client_env_read_backtick_quote "env_backtick_quote.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_backtick_quote
expect_red aws_client_env_read_backtick_hash "env_backtick_hash.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_backtick_hash
expect_red aws_client_env_read_backtick_triple "env_backtick_triple.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_backtick_triple
expect_red aws_client_env_read_escaped_quote "env_escaped_quote.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_escaped_quote
expect_red aws_client_env_read_raw_quote "env_raw_quote.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_raw_quote
expect_red aws_client_env_read_continuation "env_continuation.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_continuation
expect_red aws_client_env_read_t_string 'env_t_string.mojo has a t-string, which the environment scan does not read' tests//negative/mojo_aws_client:env_read_t_string
expect_red aws_client_env_read_t_upper 'env_t_upper.mojo has a t-string, which the environment scan does not read' tests//negative/mojo_aws_client:env_read_t_upper
expect_red aws_client_env_read_t_tr 'env_t_tr.mojo has a t-string, which the environment scan does not read' tests//negative/mojo_aws_client:env_read_t_tr
expect_red aws_client_env_read_t_rt 'env_t_rt.mojo has a t-string, which the environment scan does not read' tests//negative/mojo_aws_client:env_read_t_rt
expect_red aws_client_env_read_triple_escape "env_triple_escape.mojo imports std.pathlib, which is not on the environment scan's import allow-list (mojo_aws_client's _ENV_IMPORTS)" tests//negative/mojo_aws_client:env_read_triple_escape
expect_red aws_client_env_read_cr 'env_cr.mojo has the control byte 0x0D (carriage return), which the environment scan does not read' tests//negative/mojo_aws_client:env_read_cr
expect_red aws_client_env_read_crlf_continuation 'env_crlf_continuation.mojo has the control byte 0x0D (carriage return), which the environment scan does not read' tests//negative/mojo_aws_client:env_read_crlf_continuation
expect_red aws_client_env_read_ff 'env_ff.mojo has the control byte 0x0C (form feed), which the environment scan does not read' tests//negative/mojo_aws_client:env_read_ff
expect_red aws_client_env_read_vt 'env_vt.mojo has the control byte 0x0B (vertical tab), which the environment scan does not read' tests//negative/mojo_aws_client:env_read_vt
expect_red aws_client_env_scan_data_given '`test_data` has an entry for `tests/_no_env_reads.mojo`, the generated environment scan' tests//negative/mojo_aws_client:env_scan_data_given

# 9
if [ "$MODE" = local ]; then
    needs_remote "buck2 run (measures what a remote build downloads)"
elif [ "$run" = 1 ]; then
    if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/buck2_run.sh" > "$LOG/buck2_run.log" 2>&1; then
        pass "buck2 run: $(grep -o 'PASS  buck2 run: .*' "$LOG/buck2_run.log" | cut -c 18-)"
    else
        fail "buck2 run: $(grep -o 'FAIL  buck2 run: .*' "$LOG/buck2_run.log" | cut -c 18-) (see $LOG/buck2_run.log)"
    fi
else
    echo "SKIP  buck2 run (--no-run)"
fi

# 7
if [ "$MODE" = local ]; then
    needs_remote "umbrella cache (remote cache hits across checkouts)"
elif [ "$umbrella" = 1 ]; then
    if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/umbrella_cache.sh" > "$LOG/umbrella.log" 2>&1; then
        pass "umbrella cache: $(grep -o 'PASS  umbrella cache: .*' "$LOG/umbrella.log" | cut -c 23-)"
    else
        fail "umbrella cache: $(grep -o 'FAIL  umbrella cache: .*' "$LOG/umbrella.log" | cut -c 23-) (see $LOG/umbrella.log)"
    fi
else
    echo "SKIP  umbrella cache (--no-umbrella)"
fi

# 38
expect_green readme_examples tests//functional/readme_examples/...
for want in "ok:PASS tests//functional/readme_examples/ok:ok:README.md" \
    "none:NO EXAMPLE tests//functional/readme_examples/none:none:README.md: no "; do
    t=${want%%:*}
    line=${want#*:}
    out=$("$BUCK2" build "tests//functional/readme_examples/${t}:${t}[tests][readme]" --show-full-output 2> "$LOG/readme_marker_$t.log" | awk 'NF == 2 { print $2 }')
    if [ -n "$out" ] && [ -f "$out" ] && [ "$(head -c "${#line}" "$out")" = "$line" ]; then
        pass "readme_marker_$t"
    else
        fail "readme_marker_$t: the [tests][readme] marker must start '$line' (see $LOG/readme_marker_$t.log)"
    fi
done
expect_red readme_example_raises 'negative/readme_examples/raises/README.md:13: FAILED: planted' tests//negative/readme_examples/raises:raises
expect_red readme_example_raises_counted 'readme_raises validation: 1 of 2 checks passed' tests//negative/readme_examples/raises:raises
expect_red readme_example_compile_error 'print(farewell("a"))  # README.md:9' tests//negative/readme_examples/compile_error:compile_error
expect_red readme_example_skip_word 'negative/readme_examples/skip_word/README.md:3: `mojo skip`' tests//negative/readme_examples/skip_word:skip_word
expect_red readme_example_shipped_relative_link 'negative/readme_examples/relative_link/README.md:11: greet.mojo: a relative link in a README that ships' tests//negative/readme_examples/relative_link:relative_link
expect_red readme_owner_base_no_readme 'requested sub target named `readme`' 'tests//functional/readme_examples/owner:owner_base[tests][readme]'
expect_red readme_unowned 'from unowned import top_word  # README.md:7' tests//negative/readme_examples/unowned:unowned_base
# Load-time refusals: the case is a config value, so not expect_red's one target.
for want in 'true_without_readme|`readme = True` and //negative/readme_examples/readme_keyword holds no README.md' \
    'not_bool|`readme` takes True, False or nothing'; do
    c=${want%%|*}
    if "$BUCK2" build -c "readme_keyword.case=$c" tests//negative/readme_examples/readme_keyword:kw > "$LOG/readme_keyword_$c.log" 2>&1; then
        fail "readme_keyword_$c: tests//negative/readme_examples/readme_keyword:kw built, but it must fail"
    elif grep -qF -- "${want#*|}" "$LOG/readme_keyword_$c.log"; then
        pass "readme_keyword_$c"
    else
        fail "readme_keyword_$c: failed without '${want#*|}' (see $LOG/readme_keyword_$c.log)"
    fi
done

# 39
# A test_weld target only declares its lint; its BXL script checks it
# (tools/build/lint/test_weld.bzl says why).
test_weld_check() { # name, lint target: the check's exit status, its log in $LOG
    "$BUCK2" bxl //tools/build/lint/test_weld.bxl:check -- --lint "$2" > "$LOG/$1.log" 2>&1
}
for lint in //:test_weld tests//functional/test_weld:ok tests//negative/test_weld/real:ok; do
    name="test_weld_green_$(printf '%s' "${lint#*//}" | tr '/:' '__')"
    if test_weld_check "$name" "$lint"; then pass "$name"; else fail "$name: $lint (see $LOG/$name.log)"; fi
done
tw_tree=tests//functional/test_weld/src
for want in \
    "unwelded|$tw_tree/komira_a/tests/test_dead.mojo: a test file no target welds" \
    "untested|$tw_tree/komira_b: 1 .mojo source(s) and no welded test" \
    "untested|$tw_tree/tests/helpers/komira_e: 1 .mojo source(s) and no welded test" \
    "shrink_package|src/komira_c: the package welds 1 test(s) now; delete the row (the ledger only shrinks)" \
    "shrink_file|src/komira_c/wire/tests/test_wire.mojo: the test is welded now; delete the row (the ledger only shrinks)" \
    "shrink_computed|src/komira_a/tests/test_one.mojo: the test is welded now; delete the row (the ledger only shrinks)" \
    "nothing|src/komira_a/tests/test_gone.mojo: names neither a test file nor a package with a .mojo source" \
    "nothing|src/komira_gen: names neither a test file nor a package with a .mojo source" \
    "malformed|ledger_malformed.tsv:2: a row is <path><TAB><reason>, with a reason" \
    "empty|test_weld: checked nothing (no package under nosuch)"; do
    t=${want%%|*} text=${want#*|} name="test_weld_${want%%|*}"
    if test_weld_check "$name" "tests//negative/test_weld:$t"; then
        fail "$name: tests//negative/test_weld:$t passed, but it must fail"
    elif grep -qF -- "$text" "$LOG/$name.log"; then
        pass "$name"
    else
        fail "$name: failed without '$text' (see $LOG/$name.log)"
    fi
done
# The real rules (negative/test_weld/real/BUCK): with no ledger row, exactly
# the three unwelded files are named, and none of the welded ones.
name=test_weld_real_red
tw_real=tests//negative/test_weld/real/src
if test_weld_check "$name" tests//negative/test_weld/real:red; then
    fail "$name: tests//negative/test_weld/real:red passed, but it must fail"
else
    tw_named=$(grep -o "^$tw_real/[^:]*: a test file no target welds" "$LOG/$name.log" | sed 's/:.*//' | sort -u | tr '\n' ' ')
    tw_want="$tw_real/komira_real/tests/test_commented.mojo $tw_real/komira_real/tests/test_imported.mojo $tw_real/komira_real/tests/test_shared.mojo "
    if [ "$tw_named" = "$tw_want" ]; then
        pass "$name"
    else
        fail "$name: named '$tw_named', want '$tw_want' (see $LOG/$name.log)"
    fi
fi

# 40
expect_green readme_api_coverage //:readme_api_coverage tests//functional/readme_api_coverage:ok
L=tests//functional/readme_api_coverage:exceptions.tsv
N=tests//negative/readme_api_coverage
for want in \
    "malformed|$N/ledger_malformed.tsv:2: a row is <package><TAB><symbol><TAB><reason>, with a reason" \
    "duplicate|$N/ledger_duplicate.tsv:3: komira_a top_level has a row already, on line 1" \
    "stale_gone|$N/ledger_stale_gone.tsv:2: komira_a Circle: not exported by src/komira_a/__init__.mojo; delete the row" \
    "stale_used|$N/ledger_stale_used.tsv:3: komira_a bye: src/komira_a/README.md uses it now; delete the row (the ledger only shrinks)" \
    "enforce|$N:enforce[files]/src/komira_a/greet.mojo:23: komira_a Greeter.wave: exported and used by no README example" \
    "empty|readme_api_coverage: checked nothing (no package under nosuch)"; do
    expect_red "readme_api_coverage_${want%%|*}" "${want#*|}" "$N:${want%%|*}"
done
expect_red readme_api_coverage_malformed_symbol "$N/ledger_malformed.tsv:3: a row is" "$N:malformed"
expect_red readme_api_coverage_stale_private "$N/ledger_stale_gone.tsv:3: komira_a Greeter._secret: not exported" "$N:stale_gone"
expect_red readme_api_coverage_enforce_ledger "or give it a row in $L" "$N:enforce"

# 41
# shellcheck source=tools/build/tests/coverage_tests.sh
. "$ROOT/tools/build/tests/coverage_tests.sh"

# 42
expect_green pointer_lint //:pointer_lint tests//functional/pointer_lint:ok
N=tests//negative/pointer_lint
S="$N/src/komira_a/plant.mojo"
for want in \
    "wildcard_origin|$S:2: wildcard_origin: " \
    "from_address|$S:3: from_address: " \
    "partial_move|$S:3: partial_move: " \
    "partial_move_two|$S:4: partial_move: var v = p.take_pointee() (bound to a field's address at line 3)" \
    "parallelize|$S:3: parallelize: " \
    "libc_read|$S:3: libc_redeclare: " \
    "libc_open|$S:3: libc_redeclare: " \
    "public_pointer|$S:2: public_pointer: " \
    "public_method|$S:3: public_pointer: " \
    "public_pointer_container|$N/src/tests/e2e/komira_c_e2e/plant.mojo:2: public_pointer: " \
    "public_init|$N/src/komira_b/__init__.mojo:2: public_pointer: " \
    "held_new_site|$N/src/komira_a/held.mojo:85: parallelize: parallelize[_worker](n) -- the standard library's parallelize[: run the work on a ParallelDispatch (3 sites, held 2)" \
    "ffi_from_address|$N/src/komira_a/ffi.mojo:11: from_address: " \
    "ffi_unlisted|$N/src/komira_a/ffi_clean.mojo:7: wildcard_origin: " \
    "holds_malformed|$N/holds_malformed.tsv:8: a row has 4 tab-separated fields (rule, file, count, reason), not 3" \
    "holds_rule|$N/holds_rule.tsv:8: unknown rule \`pointer_magic\`" \
    "holds_file|$N/holds_file.tsv:8: src/komira_a/gone.mojo is not a .mojo file of the tree; delete the row" \
    "holds_count|$N/holds_count.tsv:8: count \`0\` is not a positive whole number" \
    "holds_reason|$N/holds_reason.tsv:8: empty reason" \
    "holds_duplicate|$N/holds_duplicate.tsv:8: a second row for parallelize in src/komira_a/held.mojo" \
    "holds_lower|$N/holds_lower.tsv:6: parallelize in src/komira_a/held.mojo is held at 3 and has 2: lower the count to 2" \
    "holds_delete|$N/holds_delete.tsv:8: from_address in src/komira_a/near.mojo is held at 1 and has 0: delete the row" \
    "holds_ffi_wildcard|$N/holds_ffi_wildcard.tsv:8: wildcard_origin in src/komira_a/ffi.mojo is held at 2 and has 0: delete the row" \
    "ffi_malformed|$N/ffi_malformed.tsv:3: a row has 2 tab-separated fields (file, reason), not 1" \
    "ffi_unmarked|$N/ffi_unmarked.tsv:3: src/komira_a/near.mojo carries no \`# FFI-BOUNDARY:\` comment" \
    "ffi_mention|$N/ffi_mention.tsv:3: src/komira_a/mention.mojo carries no \`# FFI-BOUNDARY:\` comment" \
    "ffi_clean_row|$N/ffi_clean_row.tsv:3: src/komira_a/ffi_clean.mojo names no wildcard origin; delete the row" \
    "ffi_file|$N/ffi_file.tsv:3: src/komira_a/gone.mojo is not a .mojo file of the tree; delete the row" \
    "ffi_duplicate|$N/ffi_duplicate.tsv:3: a second row for src/komira_a/ffi.mojo" \
    "ffi_reason|$N/ffi_reason.tsv:3: empty reason" \
    "empty|pointer_lint: checked nothing"; do
    expect_red "pointer_lint_${want%%|*}" "${want#*|}" "$N:${want%%|*}"
done
expect_red pointer_lint_no_tree "name the files in exactly one of \`tree\` and \`files\`" "$N:no_tree"
expect_red pointer_lint_both_tree_and_files "name the files in exactly one of \`tree\` and \`files\`" "$N:both_tree_and_files"

# 43
# shellcheck source=tools/build/tests/coverage_run_tests.sh
. "$ROOT/tools/build/tests/coverage_run_tests.sh"

# 44
# shellcheck source=tools/build/tests/public_boundary_tests.sh
. "$ROOT/tools/build/tests/public_boundary_tests.sh"

# 45
expect_green src_layout //:src_layout tests//functional/src_layout:ok
N=tests//negative/src_layout
F="a test-only package directly under src/, which holds what komira ships; move it to"
for want in \
    "top_e2e|//src/komira_foo_e2e: $F src/tests/e2e/komira_foo_e2e" \
    "top_loopback|//src/komira_foo_loopback: $F src/tests/e2e/komira_foo_loopback" \
    "top_conformance|//src/komira_foo_conformance: $F src/tests/conformance/komira_foo_conformance" \
    "top_test_library|//src/komira_test_unlisted: a test library directly under src/ that \`shipped\` does not name" \
    "shipped_missing|shipped names komira_test_gone, which is no package directly under src/; delete it" \
    "nested|//src/komira_a_extra/komira_x_e2e: a package is src/<name>" \
    "bad_kind|//src/tests/bench/komira_y: src/tests holds packages only at src/tests/<kind>/<name>" \
    "shallow|//src/tests/komira_z_e2e: src/tests holds packages only at src/tests/<kind>/<name>" \
    "e2e_in_conformance|this one belongs in src/tests/e2e/komira_w_e2e" \
    "conformance_in_e2e|this one belongs in src/tests/conformance/komira_v_conformance" \
    "e2e_in_helpers|this one belongs in src/tests/e2e/komira_u_loopback" \
    "harness_in_e2e|this one belongs in src/tests/helpers/komira_t" \
    "map_missing_row|//src/komira_new: no row in" \
    "map_stale_row|: a row for src/komira_a, which is no package" \
    "map_duplicate_row|: a second row for src/komira_a" \
    "map_misnamed_row|: the row names komira_b but links src/komira_a; name it komira_a" \
    "empty|src_layout: checked nothing"; do
    expect_red "src_layout_${want%%|*}" "${want#*|}" "$N:${want%%|*}"
done

# 49
# shellcheck source=tools/build/tests/assert_level_tests.sh
. "$ROOT/tools/build/tests/assert_level_tests.sh"
# 51
N=tests//negative/python_oracle
F="which is not under third_party/; an oracle reads checked-in files and third_party/ outputs only"
expect_red python_oracle_komira_data "the oracle's data \"encoding.mojoc\" is built by komira//src/komira_encoding:komira_encoding, $F" "$N:komira_data"
expect_red python_oracle_komira_srcs "the oracle's srcs entry \"hello\" is built by komira//tools/build/examples:hello, $F" "$N:komira_srcs"
expect_red python_oracle_local_wheel "the oracle's wheel local is built by tests//negative/python_oracle:local_wheel, $F" "$N:local_wheel_dep"
expect_red python_oracle_local_tzdata "the oracle's wheel local is built by tests//negative/python_oracle:local_wheel, $F" "$N:local_tzdata"
expect_red python_oracle_komira_src "the oracle's src is built by komira//tools/build/examples:hello, $F" "$N:komira_src"
expect_red python_oracle_local_python "the oracle's python is built by tests//negative/python_oracle:stand_in_python, $F" "$N:local_python"

# 52
expect_green mojo_doc_json tests//functional/mojo_doc_json:docpkg_doc
N=tests//negative/mojo_doc_json
expect_red mojo_doc_json_compile_error "could not generate documentation" "$N:compile_error"
expect_red mojo_doc_json_compile_error_source "cannot implicitly convert" "$N:compile_error"
expect_red mojo_doc_json_golden_differs "mojo_doc_json: $N:golden_differs: the JSON differs from its golden" "$N:golden_differs"
expect_red mojo_doc_json_golden_differs_shown '-            "name": "greetings",' "$N:golden_differs"
for want in __init__._hidden shout shapes.Grid.cells; do
    expect_red "mojo_doc_json_missing_$want" "mojo_doc_json: $N:missing_symbol: the JSON declares no \`$want\`" "$N:missing_symbol"
done

# 53
expect_green surface_capability_matrix //:surface_capability_matrix tests//functional/surface_capability_matrix:ok
N=tests//negative/surface_capability_matrix
E=tests//functional/surface_capability_matrix/src/tests/e2e
# dangling and incompatible are loadable only for their own build (their .BUCK
# files say why); both directories are gitignored in case a run is cut short.
D="$ROOT/tools/build/tests/negative/surface_capability_matrix"
scm_planted() { # case, required text, target
    mkdir -p "$D/$1" && cp "$D/$1.BUCK" "$D/$1/BUCK"
    expect_red "surface_capability_matrix_$1" "$2" "$3"
    rm -f "$D/$1/BUCK" && rmdir "$D/$1"
}
scm_planted dangling "Unknown target \`test_join_left\` from package \`$E/polars_e2e\`" "$N/dangling:dangling"
for want in \
    "duplicate|matrix row 11 (pandas, filter): a second row for the pair, first at row 2" \
    "unknown_capability|matrix row 11 (pandas, window): unknown capability \`window\`" \
    "unknown_surface|matrix row 11 (spark, filter): unknown surface \`spark\`" \
    "other_surface|matrix row 7 (polars, filter): $E/pandas_e2e:test_filter is in $E/pandas_e2e, not $E/polars_e2e, the surface's own package" \
    "outside_e2e|matrix row 5 (pandas, errors): tests//functional/surface_capability_matrix:test_outside is in tests//functional/surface_capability_matrix, not $E/pandas_e2e" \
    "prefix_package|matrix row 5 (pandas, errors): $E/pandas_e2e_extra:test_x is in $E/pandas_e2e_extra, not $E/pandas_e2e" \
    "subpackage|matrix row 5 (pandas, errors): $E/pandas_e2e/sub:test_sub is in $E/pandas_e2e/sub, not $E/pandas_e2e" \
    "alias|matrix row 5 (pandas, errors): $E/pandas_e2e:alias_outside stands for a target of tests//functional/surface_capability_matrix (its outputs are made there" \
    "lib_no_tests|matrix row 5 (pandas, errors): $E/pandas_e2e:lib_no_tests is no test" \
    "shared_target|matrix row 5 (pandas, errors): $E/pandas_e2e:test_filter fills (pandas, filter) already, at row 2" \
    "unparseable|src/plan/plan.mojo:14: PLAN_ODD is a constant of a grounding family in a form this lint cannot read" \
    "not_test|matrix row 5 (pandas, errors): $E/pandas_e2e:data.csv is no test" \
    "missing_pair|matrix: no row for (polars, errors)" \
    "empty_field|matrix row 10 (polars, errors): an empty field" \
    "ungrounded|capability udf_map: grounding \`UDF_KIND_MAPX\` is declared by no grounding file" \
    "unclaimed|src/plan/plan.mojo:5: PLAN_CSE_REF is a plan constant that no capability and no not_capabilities row names" \
    "vocabulary_duplicate|capabilities: filter is listed twice" \
    "floor|floor: 3 cell(s) are filled and the floor is 4" \
    "empty|surface_capability_matrix: checked nothing (no surface or no capability)"; do
    expect_red "surface_capability_matrix_${want%%|*}" "${want#*|}" "$N:${want%%|*}"
done
# Each of those yields its one finding and no other.
for t in outside_e2e ungrounded empty_field alias shared_target; do
    n=$(grep -o "surface_capability_matrix: [0-9]* finding line(s)" "$LOG/surface_capability_matrix_$t.log" | head -1)
    if [ "$n" = "surface_capability_matrix: 1 finding line(s)" ]; then pass "surface_capability_matrix_${t}_alone"; else fail "surface_capability_matrix_${t}_alone: '$n', want 1 finding (see $LOG/surface_capability_matrix_$t.log)"; fi
done
# A row naming a test incompatible with the lint's platform fails the build
# even under a package pattern, so the lint never drops out of //... silently.
scm_planted incompatible "because its transitive dep $E/pandas_e2e:test_mac" "$N/incompatible:"

# 54
# shellcheck source=tools/build/tests/node_tests.sh
. "$ROOT/tools/build/tests/node_tests.sh"

# 55
expect_green refused_imports tests//functional/refused_imports:ok
N=tests//negative/refused_imports
P=komira_plan_ir.physical_plan
G=komira_plan_ir.physical_plan_purity_gate
for want in \
    "after_docstring|5: imports $P, a module this package refuses ($P)" \
    "alias_from|4: names $P.segment, a module this package refuses ($P.segment)" \
    "alias_parent|4: names $P, a module this package refuses ($P)" \
    "continuation|2: imports $P, a module this package refuses ($P)" \
    "from_module|2: imports $P, a module this package refuses ($P)" \
    "from_parent|2: imports $G, a module this package refuses ($G)" \
    "from_spaced|2: imports $P, a module this package refuses ($P)" \
    "from_submodule|2: imports $P.sub, a module this package refuses ($P)" \
    "import_as|2: imports $P, a module this package refuses ($P)" \
    "import_list|2: imports $P, a module this package refuses ($P)" \
    "import_module|2: imports $P, a module this package refuses ($P)" \
    "import_spaced|2: imports $P, a module this package refuses ($P)" \
    "import_sub|2: imports $P.sub, a module this package refuses ($P)" \
    "indented|3: imports $P, a module this package refuses ($P)" \
    "paren_comment_close|4: imports $P, a module this package refuses ($P)" \
    "paren_comment_open|3: imports $P, a module this package refuses ($P)" \
    "mixed_triple_quotes|5: imports $P, a module this package refuses ($P)" \
    "parenthesised|4: imports $P, a module this package refuses ($P)" \
    "qualified|4: names $P, a module this package refuses ($P)" \
    "qualified_continued|4: names $P, a module this package refuses ($P)" \
    "qualified_in_parens|4: names $P, a module this package refuses ($P)" \
    "qualified_spaced|4: names $P, a module this package refuses ($P)" \
    "semicolon|2: imports $P, a module this package refuses ($P)" \
    "semicolon_imports|2: imports $G, a module this package refuses ($G)" \
    "triple_quote_in_string|3: imports $P, a module this package refuses ($P)"; do
    t=${want%%|*}
    expect_red "refused_imports_$t" "$N/$t.mojo:${want#*|}" "$N:$t"
    n=$(grep -o "mojo_deps: [0-9]* finding line(s)" "$LOG/refused_imports_$t.log" | head -1)
    if [ "$n" = "mojo_deps: 1 finding line(s)" ]; then pass "refused_imports_${t}_alone"; else fail "refused_imports_${t}_alone: '$n', want 1 finding (see $LOG/refused_imports_$t.log)"; fi
done
expect_red refused_imports_bad_entry "refused_imports entry \`komira_plan_ir\` is not a dotted module name" "$N:bad_entry"

# 37
pt_rc=0
pt_out=$(cd "$ROOT" && BUCK2="$BUCK2" bash tools/build/tests/functional/platform_table/check.sh "$LOG" 2>&1) || pt_rc=$?
printf '%s\n' "$pt_out" > "$LOG/platform_table.log"
grep -E '^(PASS|FAIL)  ' "$LOG/platform_table.log"
pt_fails=$(grep -c '^FAIL  ' "$LOG/platform_table.log" || true)
if [ "$pt_rc" != 0 ] && [ "$pt_fails" = 0 ]; then
    fail "platform table: check.sh exited $pt_rc without a FAIL line (see $LOG/platform_table.log)"
fi
fails=$((fails + pt_fails))

echo "logs: $LOG"
[ "$fails" = 0 ] || { echo "$fails test(s) failed"; exit 1; }
echo "all tests passed"
