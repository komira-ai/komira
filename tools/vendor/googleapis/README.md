# googleapis protos, referenced at a pinned commit

The `.proto` files komira generates Google Cloud clients from come from
[googleapis](https://github.com/googleapis/googleapis) (Apache-2.0) and are
**not committed here**. [BUCK](BUCK) fetches googleapis's GitHub archive at
one pinned commit (`_COMMIT`), checked against its sha256 (`_SHA256`), and
extracts at build time exactly the files a client needs. No generated code is
checked in either. The well-known types (`google/protobuf/*`) are not taken
from googleapis: protoc provides them.

googleapis's license is the archive's own `LICENSE`, extracted unmodified as
`//tools/vendor/googleapis:googleapis[LICENSE]`; googleapis ships no NOTICE
file at the pinned commit.

| target | what it is |
|---|---|
| `:googleapis.tar.gz` | the archive at the pin (`pinned_file`) |
| `:googleapis` | the files extracted from it, each a sub-target named by its path (`:googleapis[google/rpc/status.proto]`, `:googleapis[LICENSE]`) |
| `:logging_v2` | the Cloud Logging v2 protos (roots `google/logging/v2/{logging,log_entry}.proto`, for `ListLogEntries`), checked to be exactly their import closure |

## Using the protos

Depend on `//tools/vendor/googleapis:logging_v2`. Its `ProtoSrcsInfo` is the
checked tree, so a `mojo_proto_library` names it in `proto_deps`;
`:logging_v2[tree]` is that tree as a directory (the files at their import
paths), and the default output is protoc's descriptor set for the roots
(`--include_imports`).

`:logging_v2` is a `proto_check` ([proto_check.bzl](proto_check.bzl),
[proto_check.sh](proto_check.sh)): protoc must parse the roots from the
extracted files alone, into a descriptor set naming every one of them. A file
the closure needs and the list lacks fails the build, and so does a listed
file nothing imports. Its fixtures in `testdata/` hold the check to refusing
both; every `proto_check` target depends on them.

## Bumping the pin

The pin changes only by an edit here: an upstream change never reaches a
build on its own.

1. `tools/vendor/googleapis/upstream_version.sh` prints the pin, the head of
   googleapis's default branch, and which extracted files differ between the
   two. It is a report; nothing runs it in the build. If no file differs,
   there is nothing to bump for.
2. Set `_COMMIT` in BUCK to the new full commit sha, and `_SHA256` to the
   sha256 of `https://github.com/googleapis/googleapis/archive/<commit>.tar.gz`.
3. Build `//tools/vendor/googleapis:logging_v2`. If the new commit changed the
   import closure, the check names the file to add to (or drop from)
   `_LOGGING_V2_CLOSURE`.

## Adding a client

Add its roots and their closure as a list in BUCK, add the closure to
`:googleapis`'s `files`, and declare a `proto_check` over them as
`:logging_v2` is declared.
