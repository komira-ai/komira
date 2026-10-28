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
