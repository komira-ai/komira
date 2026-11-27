//! The cases of release/ci/npm_smoke (the tool of //release:npm_packages and .github/workflows/npm.yml), run
//! by the zig_test //release/ci/tests:test_npm_smoke as a build action: building the program is running them.
//! Nothing here reaches the network, a clock or a real npm: npm and node are in memory (npm_testing.zig), the
//! pause between attempts only counts, and files are written under the test's scratch directory.
//!
//! What each file holds, and what it would catch:
//!
//! - npm_set_test.zig: the digests (SHA-256 hex and npm's `sha512-<padded base64>`) against vectors computed
//!   outside Zig; npm pack's file name and the version read back only from a package's own file; the set of
//!   the tarballs written as the golden text, platform packages sorted by name and the main package last;
//!   every refusal of `build` (no package, a name outside the scope or twice, two versions, a file that is not
//!   npm pack's, the main package missing or alone, an unstamped set when a stamp is required); a written set
//!   read back as itself, an unknown key ignored; every refusal of `parse` (not JSON, a missing field, a bad
//!   version, name, file, sha256 or integrity, the main package not last, unsorted platform packages, a name
//!   twice); a directory held to its set (a stray file, other bytes, a missing tarball, no directory).
//! - npm_gate_test.zig: the gate's one line, off or on, among comments; every other text refused, naming the
//!   line (none, an unknown value, a trailing space, CR, an indented comment, two lines).
//! - npm_publish_test.zig: the exact commands, the platform package published before the main package, each
//!   after the registry was asked; E404 and an empty answer are absent, the set's integrity is not published
//!   again, another integrity stops before anything is published; a registry error, a failed publish (the
//!   main package then never asked for), an npm that cannot start or ends on a signal, each named.
//! - npm_smoke_run_test.zig: the project (package.json naming the main package at the set's version, the
//!   program) and the exact install and query commands with nothing between them; an install tried again
//!   while the registry lags, the pause between attempts, refused after the last; a work directory not empty;
//!   the query's answer held exactly, and a failing query; every check of the lock (no main, no platform,
//!   other bytes, another version, a package of the scope outside the set, a nested copy, an install script,
//!   no lock, not a lock).
//! - npm_cli_test.zig: exit 0, 1 and 2; each usage error before anything runs; `set` writing the golden and
//!   refusing an unstamped set when told; `gate` appending its line after the output file's earlier lines,
//!   and nothing on a refusal; `verify` appending the version and refusing a set other than the one built, or
//!   a tarball changed since; an unstamped set refused by `verify`, `publish` and `smoke` before any command;
//!   `publish` holding the directory to the set before the registry is asked; the annotation escaped to one
//!   line; `smoke`'s attempts and delay, and their defaults.
const std = @import("std");

test {
    _ = @import("npm_set_test.zig");
    _ = @import("npm_gate_test.zig");
    _ = @import("npm_publish_test.zig");
    _ = @import("npm_smoke_run_test.zig");
    _ = @import("npm_cli_test.zig");
}
