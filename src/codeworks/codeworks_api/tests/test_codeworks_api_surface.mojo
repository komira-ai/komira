# =============================================================================
# test_codeworks_api_surface.mojo — the CodeWorks API-SURFACE declaration: ONE
#   control plane (repo CRUD + review + coordinator), the git WIRE as the separate
#   dataplane, and which ARM of the ONE service owns each.
# =============================================================================
#
# WHAT THIS PINS. The model: git, review and the coordinator are all the same API
# plane, but git is a little more complex because its dataplane is separate. The
# git APIs CRUD repositories; RBAC then governs the underlying git operations.
#
#   1. The THREE control sub-surfaces are ONE plane (`CODEWORKS_PLANE_CONTROL`) —
#      repo CRUD and review and coordinator, not three planes.
#   2. The git WIRE is a DIFFERENT plane, and repo CRUD is NOT on it ("the git APIs
#      CRUD repositories" is control; the packfile protocol is data).
#   3. The plane and the OWNER ARM are different questions: the control plane spans
#      ALL THREE arms (repo CRUD is owned by the git arm because it has custody of
#      the object store; review + the device farm by their own arms).
#   4. The WIRE's per-repo identity is extracted in exactly ONE place, so the
#      per-repo gate and the router cannot disagree about which repo is touched.
#   5. An UNDECLARED path is `CODEWORKS_PLANE_UNKNOWN` / `CODEWORKS_OWNER_NONE` —
#      never silently control, never silently public, never silently an arm's (the
#      deny-by-default posture `resource_catalog` takes).
#   6. ★ THE FAN IS TOTAL AND EXCLUSIVE. Every declared path maps to EXACTLY ONE
#      owner arm, and the three owner predicates are PAIRWISE DISJOINT. This is the
#      property the service's three-way composite fan depends on: if two
#      predicates could both fire, the arm a request reached would be an artefact
#      of the order the `if`s happen to be written in.
#
# ★ ONE SERVICE. There is one container; the question that matters is "which ARM",
# and `codeworks_owner_for` answers it. Nothing here may be written against a
# multi-service topology.
#
# NO auth DECISION is asserted here — this file pins CLASSIFICATION, which is what the
# gates hang off. (The classification is not ahead of the gates: the git wire is
# behind `ResourceAuthzGate` over the git resource catalog, review behind
# `GrantVerifyingDispatcher`, the coordinator behind its device-identity secrets.
# Three arms, three gates.)
#
# Encapsulation: pure value functions over Strings; no transport, no store, no live
# infra. Mojo 1.0.0b2 (def-only).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from codeworks_api import (
    CODEWORKS_PLANE_UNKNOWN,
    CODEWORKS_PLANE_INFRA,
    CODEWORKS_PLANE_CONTROL,
    CODEWORKS_PLANE_GIT_WIRE,
    CODEWORKS_SURFACE_NONE,
    CODEWORKS_SURFACE_REPO,
    CODEWORKS_SURFACE_REVIEW,
    CODEWORKS_SURFACE_COORDINATOR,
    CODEWORKS_SERVICE,
    CODEWORKS_OWNER_NONE,
    CODEWORKS_OWNER_GIT,
    CODEWORKS_OWNER_REVIEW,
    CODEWORKS_OWNER_COORDINATOR,
    CODEWORKS_RESOURCE_TYPE_REPO,
    CODEWORKS_RESOURCE_TYPE_REVIEW,
    codeworks_plane_for,
    codeworks_control_surface_for,
    codeworks_owner_for,
    codeworks_path_is_git_wire,
    codeworks_git_wire_repo_name,
    codeworks_path_is_repo_control,
    codeworks_path_owned_by_git,
    codeworks_path_owned_by_review,
    codeworks_path_owned_by_coordinator,
    codeworks_path_is_infra,
)


def test_repo_crud_review_and_coordinator_are_ONE_control_plane() raises:
    """The model, asserted directly: repo CRUD, review and the coordinator are
    the SAME plane. Three sub-surfaces, one API plane."""
    var control_paths = List[String]()
    control_paths.append(String("/repos"))  # repo CRUD (create/list)
    control_paths.append(String("/workspaces/w1/reviews"))  # review list
    control_paths.append(String("/workspaces/w1/reviews/r1/verdict"))
    control_paths.append(String("/workspaces/w1/review-policy"))
    control_paths.append(String("/reviews/blob/abc"))
    control_paths.append(String("/v1/reservations"))  # device farm
    control_paths.append(String("/v1/reservations/run-1"))
    control_paths.append(String("/v1/devices"))
    control_paths.append(String("/v1/devices/register"))
    control_paths.append(String("/internal/dispatch/tick"))
    for i in range(len(control_paths)):
        assert_equal(
            codeworks_plane_for(control_paths[i]),
            CODEWORKS_PLANE_CONTROL,
            String("`") + control_paths[i] + String("` is the CONTROL plane"),
        )
        assert_false(
            codeworks_control_surface_for(control_paths[i])
            == CODEWORKS_SURFACE_NONE,
            String("`")
            + control_paths[i]
            + String("` names a control SUB-surface"),
        )

    # ... and each lands on the RIGHT sub-surface.
    assert_equal(
        codeworks_control_surface_for(String("/repos")),
        CODEWORKS_SURFACE_REPO,
        "repo CRUD is the REPO sub-surface",
    )
    assert_equal(
        codeworks_control_surface_for(String("/workspaces/w1/reviews")),
        CODEWORKS_SURFACE_REVIEW,
        "review routes are the REVIEW sub-surface",
    )
    assert_equal(
        codeworks_control_surface_for(String("/v1/devices")),
        CODEWORKS_SURFACE_COORDINATOR,
        "device-farm routes are the COORDINATOR sub-surface",
    )


def test_git_wire_is_a_separate_dataplane_and_repo_crud_is_not_on_it() raises:
    """The git WIRE (`/<repo>.git/...`) is its OWN plane; repo CRUD is NOT on it."""
    var wire_paths = List[String]()
    wire_paths.append(String("/acme-api.git/info/refs"))
    wire_paths.append(String("/acme-api.git/info/refs?service=git-upload-pack"))
    wire_paths.append(String("/acme-api.git/git-upload-pack"))
    wire_paths.append(String("/acme-api.git/git-receive-pack"))
    wire_paths.append(
        String("/acme-api.git/objects/ab/cdef0123456789abcdef0123456789abcdef01")
    )
    for i in range(len(wire_paths)):
        assert_equal(
            codeworks_plane_for(wire_paths[i]),
            CODEWORKS_PLANE_GIT_WIRE,
            String("`") + wire_paths[i] + String("` is the git WIRE dataplane"),
        )
        assert_true(codeworks_path_is_git_wire(wire_paths[i]), "wire predicate")
        # A wire path is NOT on the control plane — it has no control sub-surface.
        assert_equal(
            codeworks_control_surface_for(wire_paths[i]),
            CODEWORKS_SURFACE_NONE,
            "a WIRE path carries no control sub-surface",
        )

    # Repo CRUD is CONTROL, never wire — this is the distinction the model draws.
    assert_true(codeworks_path_is_repo_control(String("/repos")), "repos is control")
    assert_false(
        codeworks_path_is_git_wire(String("/repos")),
        "repo CRUD is NOT the git wire (it is the API that creates the repo)",
    )
    assert_equal(
        codeworks_plane_for(String("/repos")),
        CODEWORKS_PLANE_CONTROL,
        "POST/GET /repos is the CONTROL plane",
    )


def test_wire_wins_over_a_control_lookalike_repo_name() raises:
    """A repo may be NAMED like a control route. The wire is classified FIRST, so a
    repo called `reviews` or `repos` can never be mistaken for the control surface —
    which is what would let a push be gated as (or instead of) a review."""
    assert_equal(
        codeworks_plane_for(String("/reviews.git/git-receive-pack")),
        CODEWORKS_PLANE_GIT_WIRE,
        "a repo named `reviews` is still the WIRE",
    )
    assert_false(
        codeworks_path_owned_by_review(String("/reviews.git/git-receive-pack")),
        "a repo named `reviews` is NOT the review surface",
    )
    assert_equal(
        codeworks_plane_for(String("/repos.git/info/refs")),
        CODEWORKS_PLANE_GIT_WIRE,
        "a repo named `repos` is still the WIRE",
    )
    assert_false(
        codeworks_path_is_repo_control(String("/repos.git/info/refs")),
        "a repo named `repos` is NOT the repo-CRUD control surface",
    )


def test_git_wire_repo_name_is_extracted_in_one_place() raises:
    """The per-repo identity the future WIRE gate keys on (RBAC attach point 2:
    `ResourceRef.from_name(codeworks.repo, <name>)`) comes from ONE extraction, so
    the gate and the router can never authorize different repos."""
    assert_equal(
        codeworks_git_wire_repo_name(String("/acme-api.git/info/refs")),
        String("acme-api"),
        "the repo name drops the `.git` suffix",
    )
    assert_equal(
        codeworks_git_wire_repo_name(
            String("/acme-api.git/info/refs?service=git-upload-pack")
        ),
        String("acme-api"),
        "a query string does not change the repo identity",
    )
    assert_equal(
        codeworks_git_wire_repo_name(String("/acme-api.git")),
        String("acme-api"),
        "the bare mount names the repo too",
    )
    # A non-wire path names NO repo (a gate must not synthesize one).
    assert_equal(
        codeworks_git_wire_repo_name(String("/repos")),
        String(""),
        "a control path names no wire repo",
    )
    assert_equal(
        codeworks_git_wire_repo_name(String("/v1/devices")),
        String(""),
        "a coordinator path names no wire repo",
    )


def test_plane_and_owner_arm_are_different_questions() raises:
    """The CONTROL plane spans ALL THREE arms — which is exactly why 'which plane' and
    'which arm' are answered separately. The arm split follows STORE CUSTODY (repo CRUD
    lives with the object store it mutates), not the API plane."""
    # Same plane, different arms.
    assert_equal(
        codeworks_plane_for(String("/repos")),
        codeworks_plane_for(String("/workspaces/w1/reviews")),
        "repo CRUD and review are the SAME plane",
    )
    assert_equal(
        codeworks_owner_for(String("/repos")),
        CODEWORKS_OWNER_GIT,
        "repo CRUD is owned by the git arm (it has custody of the ODB)",
    )
    assert_equal(
        codeworks_owner_for(String("/workspaces/w1/reviews")),
        CODEWORKS_OWNER_REVIEW,
        "review is owned by the review arm",
    )
    assert_equal(
        codeworks_owner_for(String("/v1/devices")),
        CODEWORKS_OWNER_COORDINATOR,
        "the device farm is owned by the coordinator arm",
    )
    assert_equal(
        codeworks_owner_for(String("/acme-api.git/git-upload-pack")),
        CODEWORKS_OWNER_GIT,
        "the wire is owned by the git arm",
    )


def test_there_is_exactly_one_service_id() raises:
    """★ ONE managed application, ONE service.

    There is no second id: a separate coordinator id would be a catalog record that
    is also another app's SERVICE, which is the one shape the managed-app invariant
    "no catalog app is another app's service" forbids. With one service that
    invariant is satisfied trivially — there is no second id for anything to
    disagree about.

    The token is `codeworks` and it is the SAME token everywhere: app id, service id,
    deployed service, image, bundle `ServiceSpec.name`, binary."""
    assert_equal(String(CODEWORKS_SERVICE), String("codeworks"))


def _owner_predicate_count(path: String) raises -> Int:
    """How many of the THREE arm-ownership predicates claim `path`. Exclusivity means
    this is never > 1; totality means it is exactly 1 for every declared resource
    route (the infra probes are deliberately claimed by NO predicate — see
    `codeworks_path_is_infra`)."""
    var n = 0
    if codeworks_path_owned_by_git(path):
        n += 1
    if codeworks_path_owned_by_review(path):
        n += 1
    if codeworks_path_owned_by_coordinator(path):
        n += 1
    return n


def test_the_fan_is_total_and_exclusive() raises:
    """★ The reason `codeworks_owner_for` exists: the service's composite
    dispatcher (generic over its coordinator, review and git arms) fans every request to
    exactly one of three arms, so the DECLARATION must be a PARTITION.

    TOTALITY — every declared path names an owner arm (never `CODEWORKS_OWNER_NONE`).
    EXCLUSIVITY — no path is claimed by two arm predicates. Without this, which arm a
    request reached would be an artefact of the order the `if`s are written in, and a
    reordering refactor would silently move routes between gates.

    The table is driven twice: once through the predicates (the pairwise-disjointness
    check) and once through `codeworks_owner_for` (the fan the composite runs), so the
    two cannot drift."""
    var paths = List[String]()
    var owners = List[Int]()

    # ── GIT arm: the wire (every shape a git client uses) ─────────────────────
    paths.append(String("/acme-api.git/info/refs"))
    owners.append(CODEWORKS_OWNER_GIT)
    paths.append(String("/acme-api.git/info/refs?service=git-upload-pack"))
    owners.append(CODEWORKS_OWNER_GIT)
    paths.append(String("/acme-api.git/git-upload-pack"))
    owners.append(CODEWORKS_OWNER_GIT)
    paths.append(String("/acme-api.git/git-receive-pack"))
    owners.append(CODEWORKS_OWNER_GIT)
    paths.append(
        String("/acme-api.git/objects/ab/cdef0123456789abcdef0123456789abcdef01")
    )
    owners.append(CODEWORKS_OWNER_GIT)
    paths.append(String("/acme-api.git"))
    owners.append(CODEWORKS_OWNER_GIT)
    # ── GIT arm: repo CRUD (control plane, git custody) ───────────────────────
    paths.append(String("/repos"))
    owners.append(CODEWORKS_OWNER_GIT)
    paths.append(String("/repos/acme-api"))
    owners.append(CODEWORKS_OWNER_GIT)

    # ── REVIEW arm ────────────────────────────────────────────────────────────
    paths.append(String("/workspaces/w1/reviews"))
    owners.append(CODEWORKS_OWNER_REVIEW)
    paths.append(String("/workspaces/w1/reviews/r1/verdict"))
    owners.append(CODEWORKS_OWNER_REVIEW)
    paths.append(String("/workspaces/w1/review-policy"))
    owners.append(CODEWORKS_OWNER_REVIEW)
    paths.append(String("/reviews/blob/abc"))
    owners.append(CODEWORKS_OWNER_REVIEW)

    # ── COORDINATOR arm ───────────────────────────────────────────────────────
    paths.append(String("/v1/reservations"))
    owners.append(CODEWORKS_OWNER_COORDINATOR)
    paths.append(String("/v1/reservations/run-1/release"))
    owners.append(CODEWORKS_OWNER_COORDINATOR)
    paths.append(String("/v1/devices"))
    owners.append(CODEWORKS_OWNER_COORDINATOR)
    paths.append(String("/v1/devices/register"))
    owners.append(CODEWORKS_OWNER_COORDINATOR)
    paths.append(String("/internal/dispatch/tick"))
    owners.append(CODEWORKS_OWNER_COORDINATOR)

    for i in range(len(paths)):
        # TOTALITY through the fan.
        assert_equal(
            codeworks_owner_for(paths[i]),
            owners[i],
            String("`") + paths[i] + String("` fans to exactly its owner arm"),
        )
        # TOTALITY + EXCLUSIVITY through the predicates: exactly one claims it.
        assert_equal(
            _owner_predicate_count(paths[i]),
            1,
            String("`")
            + paths[i]
            + String("` is claimed by EXACTLY ONE arm predicate"),
        )

    # ── The infra probes: owned by an arm for ROUTING, claimed by NO predicate.
    #    `/healthz` + `/livez` are the git arm's declared PUBLIC catalog rows;
    #    `/health` is the coordinator's. ────────────────────────────────────────
    assert_equal(
        codeworks_owner_for(String("/healthz")),
        CODEWORKS_OWNER_GIT,
        "/healthz is the git arm's probe (a GitResourceCatalog PUBLIC row)",
    )
    assert_equal(
        codeworks_owner_for(String("/livez")),
        CODEWORKS_OWNER_GIT,
        "/livez is the git arm's probe (a GitResourceCatalog PUBLIC row)",
    )
    assert_equal(
        codeworks_owner_for(String("/health")),
        CODEWORKS_OWNER_COORDINATOR,
        "/health is the coordinator arm's probe",
    )
    assert_equal(
        _owner_predicate_count(String("/healthz")),
        0,
        "a probe is not a declared RESOURCE route of any arm",
    )
    assert_equal(
        _owner_predicate_count(String("/health")),
        0,
        "a probe is not a declared RESOURCE route of any arm",
    )


def test_a_repo_named_like_another_arm_still_fans_to_git() raises:
    """★ THE SUBTLE CASE THE FAN ALREADY GETS RIGHT, pinned so a reordering cannot
    lose it. The git WIRE is excluded FIRST, so a repository whose NAME collides with
    another arm's route — `reviews.git`, `repos.git`, `health.git`, `v1.git` — reaches
    the GIT arm and its per-repo gate, not the review surface and not a public probe.

    Getting this wrong is not a 404: it would gate a `git push` as (or instead of) a
    review, or serve a repository's refs through a route declared PUBLIC."""
    var wire_lookalikes = List[String]()
    wire_lookalikes.append(String("/reviews.git/git-receive-pack"))
    wire_lookalikes.append(String("/repos.git/info/refs"))
    wire_lookalikes.append(String("/health.git/info/refs"))
    wire_lookalikes.append(String("/healthz.git/git-upload-pack"))
    wire_lookalikes.append(String("/v1.git/info/refs"))
    wire_lookalikes.append(String("/internal.git/git-upload-pack"))
    for i in range(len(wire_lookalikes)):
        assert_equal(
            codeworks_owner_for(wire_lookalikes[i]),
            CODEWORKS_OWNER_GIT,
            String("`")
            + wire_lookalikes[i]
            + String("` is a REPOSITORY — the git arm owns it"),
        )
        assert_equal(
            _owner_predicate_count(wire_lookalikes[i]),
            1,
            String("`") + wire_lookalikes[i] + String("` is claimed only by git"),
        )
        assert_false(
            codeworks_path_is_infra(wire_lookalikes[i]),
            String("`")
            + wire_lookalikes[i]
            + String("` is NOT a probe — a repo cannot name itself public"),
        )


def test_infra_probes_are_declared_public_rows_not_omissions() raises:
    """`/healthz` | `/livez` (the git arm) and `/health` (the coordinator arm) are the
    INFRA plane: declared, and each attributed to the arm that actually serves it."""
    assert_equal(
        codeworks_plane_for(String("/healthz")),
        CODEWORKS_PLANE_INFRA,
        "/healthz is INFRA",
    )
    assert_equal(
        codeworks_plane_for(String("/livez")),
        CODEWORKS_PLANE_INFRA,
        "/livez is INFRA",
    )
    assert_equal(
        codeworks_plane_for(String("/health")),
        CODEWORKS_PLANE_INFRA,
        "/health is INFRA",
    )
    assert_true(codeworks_path_is_infra(String("/healthz")), "infra predicate")
    assert_equal(
        codeworks_owner_for(String("/healthz")),
        CODEWORKS_OWNER_GIT,
        "/healthz is the git arm's probe",
    )
    assert_equal(
        codeworks_owner_for(String("/health")),
        CODEWORKS_OWNER_COORDINATOR,
        "/health is the coordinator arm's probe",
    )
    # INFRA is NOT the control plane (it carries no resource).
    assert_equal(
        codeworks_control_surface_for(String("/healthz")),
        CODEWORKS_SURFACE_NONE,
        "a probe carries no control sub-surface",
    )


def test_undeclared_paths_are_unknown_never_implicitly_control() raises:
    """★ The deny-by-default posture. A path nobody declared is UNKNOWN — not control,
    not public, and claimed by NO arm. A gate denies it, exactly as
    `resource_catalog`'s unrouted request denies.

    ★ `CODEWORKS_OWNER_NONE` is NOT the same fact as "the composite 404s it". The
    composite must send an undeclared request somewhere and sends it to the
    coordinator, its fail-safe default arm, which 404s. This asserts the DECLARATION
    claims nothing — which is what a gate reads."""
    var unknown = List[String]()
    unknown.append(String("/"))
    unknown.append(String(""))
    unknown.append(String("/admin"))
    unknown.append(String("/v2/devices"))  # a version nobody declared
    unknown.append(String("/workspaces/w1"))  # a bare workspace path, not review
    unknown.append(String("/internal/dispatch"))  # not the declared tick route
    unknown.append(String("/acme-api/info/refs"))  # missing `.git` -> not the wire
    for i in range(len(unknown)):
        assert_equal(
            codeworks_plane_for(unknown[i]),
            CODEWORKS_PLANE_UNKNOWN,
            String("`") + unknown[i] + String("` is UNKNOWN, not control"),
        )
        assert_equal(
            codeworks_control_surface_for(unknown[i]),
            CODEWORKS_SURFACE_NONE,
            String("`") + unknown[i] + String("` names no control sub-surface"),
        )
        assert_equal(
            codeworks_owner_for(unknown[i]),
            CODEWORKS_OWNER_NONE,
            String("`") + unknown[i] + String("` is claimed by NO arm"),
        )
        assert_equal(
            _owner_predicate_count(unknown[i]),
            0,
            String("`") + unknown[i] + String("` matches NO arm predicate"),
        )


def test_review_predicate_covers_the_comount_seam_exactly() raises:
    """The app-service composite fans to review on this predicate, so it must match
    the review route families exactly — `/reviews*` AND `/review-policy` (which does
    NOT contain `/reviews`), and a bare `/workspaces/:wid` must NOT match."""
    assert_true(
        codeworks_path_owned_by_review(String("/workspaces/w1/reviews")),
        "the reviews family is review-owned",
    )
    assert_true(
        codeworks_path_owned_by_review(String("/workspaces/w1/review-policy")),
        "review-policy is review-owned (it does NOT contain `/reviews`)",
    )
    assert_true(
        codeworks_path_owned_by_review(String("/reviews/blob/abc")),
        "the top-level reviews family is review-owned",
    )
    assert_false(
        codeworks_path_owned_by_review(String("/workspaces/w1")),
        "a bare workspace path is NOT review",
    )
    assert_false(
        codeworks_path_owned_by_review(String("/v1/devices")),
        "a coordinator route is NOT review",
    )
    # Coordinator ownership is the DECLARED set, not the composite's default arm.
    assert_true(
        codeworks_path_owned_by_coordinator(String("/v1/reservations/run-1/release")),
        "release is a declared coordinator route",
    )
    assert_false(
        codeworks_path_owned_by_coordinator(String("/anything-else")),
        "an undeclared path is NOT a declared coordinator route",
    )


def test_rbac_resource_type_keys_are_declared_for_the_retrofit() raises:
    """The vocabulary the future `ResourceCatalog` conformer declares. Pinned here so
    the gate and the router name the SAME types (a second vocabulary is precisely the
    mistake the generic mechanism exists to prevent). NO authorization is performed."""
    assert_equal(
        String(CODEWORKS_RESOURCE_TYPE_REPO),
        String("codeworks.repo"),
        "the repo resource type key is app-prefixed and stable",
    )
    assert_equal(
        String(CODEWORKS_RESOURCE_TYPE_REVIEW),
        String("codeworks.review"),
        "the review resource type key is app-prefixed and stable",
    )


def main() raises:
    test_repo_crud_review_and_coordinator_are_ONE_control_plane()
    test_git_wire_is_a_separate_dataplane_and_repo_crud_is_not_on_it()
    test_wire_wins_over_a_control_lookalike_repo_name()
    test_git_wire_repo_name_is_extracted_in_one_place()
    test_plane_and_owner_arm_are_different_questions()
    test_there_is_exactly_one_service_id()
    test_the_fan_is_total_and_exclusive()
    test_a_repo_named_like_another_arm_still_fans_to_git()
    test_infra_probes_are_declared_public_rows_not_omissions()
    test_undeclared_paths_are_unknown_never_implicitly_control()
    test_review_predicate_covers_the_comount_seam_exactly()
    test_rbac_resource_type_keys_are_declared_for_the_retrofit()
    print("PASS test_codeworks_api_surface")
