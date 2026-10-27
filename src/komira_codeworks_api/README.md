# komira_codeworks_api

The HTTP surface of CodeWorks (git hosting and code review) as path
classification. It has no dependencies and does no I/O.

A request path belongs to one plane:

- the git wire, `/<repo>.git/...`: the git smart and dumb HTTP protocol, whose
  client is `git`;
- the control plane: repository create and list (`/repos`) and code review
  (`/workspaces/:wid/reviews*`, `/workspaces/:wid/review-policy`, `/reviews/*`);
- a liveness probe (`/healthz`, `/livez`);
- unknown, for anything not declared.

The one CodeWorks service has two arms. The git arm owns the wire, the
repository routes and the probes; the review arm owns the review routes. The
plane and the arm are separate questions (the control plane spans both arms), so
there is a function for each.

- `codeworks_plane_for(path)` returns a `CODEWORKS_PLANE_*` value;
  `codeworks_control_surface_for(path)` returns `CODEWORKS_SURFACE_REPO`,
  `CODEWORKS_SURFACE_REVIEW` or `CODEWORKS_SURFACE_NONE`;
  `codeworks_owner_for(path)` returns `CODEWORKS_OWNER_GIT`,
  `CODEWORKS_OWNER_REVIEW` or `CODEWORKS_OWNER_NONE`.
- A repository named `reviews.git`, `repos.git` or `healthz.git` is still a
  repository and the git arm's: routes and probes match whole path segments.
- `codeworks_git_wire_repo_name(path)` is the one place the repository name is
  taken from a wire path (without `.git`, ignoring a query), so a gate and a
  router cannot disagree about which repository a request touches.
- `codeworks_repo_name_is_safe(name)` accepts a non-empty run of
  `[A-Za-z0-9._-]` with no leading `.` and no `..`. It accepts or rejects and
  never rewrites the name.
- The two owner predicates, `codeworks_path_owned_by_git` and
  `codeworks_path_owned_by_review`, name declared resource routes only and never
  both match; probes are attributed by `codeworks_owner_for`.
- Constants: the service id, the resource type keys (`codeworks.repo`,
  `codeworks.review`), the route literals, and the response marker header
  (`x-komira-codeworks`, value `1`) a service stamps on its own responses so a
  validator can tell them from a proxy's.

This is classification, not authorization. An undeclared path is unknown and
owned by no arm; a gate built on it must deny that path. No function takes or
returns a pointer.

```mojo
from komira_codeworks_api import (
    CODEWORKS_OWNER_GIT,
    CODEWORKS_OWNER_NONE,
    CODEWORKS_OWNER_REVIEW,
    CODEWORKS_PLANE_CONTROL,
    CODEWORKS_PLANE_GIT_WIRE,
    codeworks_git_wire_repo_name,
    codeworks_owner_for,
    codeworks_plane_for,
    codeworks_repo_name_is_safe,
)
from std.testing import assert_equal, assert_false, assert_true

var wire = "/acme-api.git/info/refs?service=git-upload-pack"
assert_equal(codeworks_plane_for(wire), CODEWORKS_PLANE_GIT_WIRE)
assert_equal(codeworks_git_wire_repo_name(wire), "acme-api")
assert_equal(codeworks_owner_for(wire), CODEWORKS_OWNER_GIT)

# the control plane spans both arms
assert_equal(codeworks_plane_for("/repos"), CODEWORKS_PLANE_CONTROL)
assert_equal(codeworks_owner_for("/repos"), CODEWORKS_OWNER_GIT)
assert_equal(
    codeworks_owner_for("/workspaces/w1/reviews"), CODEWORKS_OWNER_REVIEW
)

# a repository named like a route is still the wire
assert_equal(codeworks_owner_for("/reviews.git/info/refs"), CODEWORKS_OWNER_GIT)

# an undeclared path is owned by nobody
assert_equal(codeworks_owner_for("/admin"), CODEWORKS_OWNER_NONE)

assert_true(codeworks_repo_name_is_safe("acme-api"))
assert_false(codeworks_repo_name_is_safe("../acme"))
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_codeworks_api`, version 0.1.0
(`mopm.toml`). The library is `src/komira_codeworks_api/` (`surface.mojo`, and the `__init__.mojo` that re-exports it), its tests are `tests/`
(`test_surface.mojo` and `test_repo_name_and_constants.mojo`). The package has no dependencies, no native archive and calls no foreign
function. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a
source, a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_codeworks_api:lib` on the farm. A test file that `buildrules mojo sync` has not
listed is not run: run the sync after adding one.

`:conda` is the `.conda` of the mopm package (`mojo-komira_codeworks_api-0.1.0-mojo1.0.0_0.conda`): the `.mojoc`, which
exists only once the tests have passed. `:komira_codeworks_api` is `:lib` as komira's Mojo rules take it
(`mojo_adopted_library`); it also compiles and runs the README's examples above (`[tests][readme]`) against
`:lib`, which `:lib` does not do.
