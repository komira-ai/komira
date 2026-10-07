# Contributing to komira

Thank you for helping. This page says how a change gets in; the details live in
the docs it links.

## Before you start

- **A bug or a small fix:** open a pull request, or an issue first if you are
  not sure it is a bug.
- **Anything larger** (a new library, a change to a public API, a build rule or
  a workflow): open an issue describing it first, so the design can be agreed
  before you write it. [docs/index.md](docs/index.md) says which doc is the
  authority for each subsystem.
- **A security problem:** do not open an issue; see [SECURITY.md](SECURITY.md).

## Building and testing

[DEVELOPMENT.md](DEVELOPMENT.md) sets up buck2 and the hermetic toolchain. On
Linux x86_64:

```sh
./buck2 build //...        # every target, with its welded tests and the lints
```

The build is the test run: a Mojo library's `test_srcs`, and the `mojo`
examples in its `README.md`, are built and run as part of building the library,
and the library cannot be built unless they pass
([tools/build/mojo/README.md](tools/build/mojo/README.md)). A green build of the
targets you changed is the evidence a review starts from.

## What a change should carry

- **A test that fails without the change.** A bug fix ships with the test that
  reproduced the bug; name it in the library's `test_srcs`, or it never runs.
- **Docs that match the code.** If you change what a library does, change its
  `README.md` and any design doc that describes it in the same pull request.
- **Mojo that follows the safety rules** in
  [docs/design/mojo_safety_and_idioms.md](docs/design/mojo_safety_and_idioms.md):
  no pointer type in a public API, and every `UnsafePointer` carries a
  `# SAFETY:` comment that says why the access is sound.
- **One subject per pull request**, with a description that says what changed,
  why, and how it was tested.

## Pull requests from forks

A pull request from a fork gets no build: the build runs on build-farm workers,
and running a stranger's build there would run its code
([docs/ci.md](docs/ci.md#pull-requests-from-forks)). A maintainer reads the
whole change, pushes it to a branch of this repository, and merges only after
that branch's build is green. Expect that review to take longer than one of a
branch of this repository, and keep a fork's pull request small.

## License

komira is licensed under the [Apache License 2.0](LICENSE). By contributing,
you agree that your contribution is licensed under the same license
(section 5 of the license).

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
