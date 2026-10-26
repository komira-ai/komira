# Path classification: planes, control sub-surfaces, owner arms, the wire's
# repository name. What each test would catch:
# - control routes (repository and review) are one plane, each on its own
#   sub-surface (a classifier that put repository routes on their own plane, or
#   reviews on the repository surface, fails);
# - the wire is a plane of its own and repository routes are not on it;
# - a repository named like a control route or a probe (`reviews.git`,
#   `repos.git`, `healthz.git`) is still the wire and the git arm's (a classifier
#   that tests the control prefixes before the wire fails);
# - the repository name drops `.git` and a query, and is empty off the wire;
# - every declared route has exactly one arm and the arm predicates never overlap;
# - undeclared paths are unknown, claimed by no arm, with no sub-surface;
# - the review predicate matches `/review-policy`, which lacks `/reviews`.

from std.testing import assert_equal, assert_false, assert_true

from komira_codeworks_api import (
    CODEWORKS_OWNER_GIT,
    CODEWORKS_OWNER_NONE,
    CODEWORKS_OWNER_REVIEW,
    CODEWORKS_PLANE_CONTROL,
    CODEWORKS_PLANE_GIT_WIRE,
    CODEWORKS_PLANE_INFRA,
    CODEWORKS_PLANE_UNKNOWN,
    CODEWORKS_SURFACE_NONE,
    CODEWORKS_SURFACE_REPO,
    CODEWORKS_SURFACE_REVIEW,
    codeworks_control_surface_for,
    codeworks_git_wire_repo_name,
    codeworks_owner_for,
    codeworks_path_is_git_wire,
    codeworks_path_is_infra,
    codeworks_path_is_repo_control,
    codeworks_path_owned_by_git,
    codeworks_path_owned_by_review,
    codeworks_plane_for,
)


def _wire_paths() -> List[String]:
    var p = List[String]()
    p.append("/acme-api.git/info/refs")
    p.append("/acme-api.git/info/refs?service=git-upload-pack")
    p.append("/acme-api.git/git-upload-pack")
    p.append("/acme-api.git/git-receive-pack")
    p.append("/acme-api.git/objects/ab/cdef0123456789abcdef0123456789abcdef01")
    p.append("/acme-api.git")
    p.append("acme-api.git/info/refs")  # no leading slash
    return p^


def test_repository_and_review_routes_are_one_control_plane() raises:
    var repo = List[String]()
    repo.append("/repos")
    repo.append("/repos/acme-api")
    repo.append("/repos?limit=5")
    for i in range(len(repo)):
        assert_equal(codeworks_plane_for(repo[i]), CODEWORKS_PLANE_CONTROL)
        assert_equal(
            codeworks_control_surface_for(repo[i]), CODEWORKS_SURFACE_REPO
        )
        assert_true(codeworks_path_is_repo_control(repo[i]))
    var review = List[String]()
    review.append("/workspaces/w1/reviews")
    review.append("/workspaces/w1/reviews/r1/verdict")
    review.append("/workspaces/w1/review-policy")
    review.append("/reviews/blob/abc")
    for i in range(len(review)):
        assert_equal(codeworks_plane_for(review[i]), CODEWORKS_PLANE_CONTROL)
        assert_equal(
            codeworks_control_surface_for(review[i]), CODEWORKS_SURFACE_REVIEW
        )
        assert_false(codeworks_path_is_repo_control(review[i]))


def test_git_wire_is_its_own_plane_and_repository_routes_are_not_on_it() raises:
    var wire = _wire_paths()
    for i in range(len(wire)):
        assert_equal(codeworks_plane_for(wire[i]), CODEWORKS_PLANE_GIT_WIRE)
        assert_true(codeworks_path_is_git_wire(wire[i]))
        assert_equal(
            codeworks_control_surface_for(wire[i]), CODEWORKS_SURFACE_NONE
        )
        assert_false(codeworks_path_is_repo_control(wire[i]))
    assert_false(codeworks_path_is_git_wire("/repos"))
    assert_false(codeworks_path_is_git_wire("/acme-api/info/refs"))
    # `.git` must end the FIRST segment, not appear later in the path
    assert_false(codeworks_path_is_git_wire("/repos/acme.git"))
    assert_false(codeworks_path_is_git_wire("/acme-api/x.git/info/refs"))
    assert_equal(codeworks_owner_for("/repos/acme.git"), CODEWORKS_OWNER_GIT)
    assert_equal(
        codeworks_plane_for("/repos/acme.git"), CODEWORKS_PLANE_CONTROL
    )
    assert_equal(codeworks_plane_for("/acme-api/x.git/y"), CODEWORKS_PLANE_UNKNOWN)


def test_a_repository_named_like_a_route_is_still_the_wire() raises:
    var names = List[String]()
    names.append("/reviews.git/git-receive-pack")
    names.append("/repos.git/info/refs")
    names.append("/healthz.git/git-upload-pack")
    names.append("/livez.git/info/refs")
    names.append("/workspaces.git/info/refs")
    for i in range(len(names)):
        assert_equal(codeworks_plane_for(names[i]), CODEWORKS_PLANE_GIT_WIRE)
        assert_equal(codeworks_owner_for(names[i]), CODEWORKS_OWNER_GIT)
        assert_equal(
            codeworks_control_surface_for(names[i]), CODEWORKS_SURFACE_NONE
        )
        assert_false(codeworks_path_is_infra(names[i]))
        assert_false(codeworks_path_owned_by_review(names[i]))
        assert_false(codeworks_path_is_repo_control(names[i]))


def test_wire_repository_name_is_extracted_without_suffix_or_query() raises:
    assert_equal(
        codeworks_git_wire_repo_name("/acme-api.git/info/refs"), "acme-api"
    )
    assert_equal(
        codeworks_git_wire_repo_name(
            "/acme-api.git/info/refs?service=git-upload-pack"
        ),
        "acme-api",
    )
    assert_equal(codeworks_git_wire_repo_name("/acme-api.git"), "acme-api")
    assert_equal(codeworks_git_wire_repo_name("acme-api.git/x"), "acme-api")
    assert_equal(codeworks_git_wire_repo_name("/acme.v2.git/x"), "acme.v2")
    # a mount with nothing before the suffix names no repository
    assert_equal(codeworks_git_wire_repo_name("/.git/info/refs"), "")
    # off the wire there is no repository to name
    assert_equal(codeworks_git_wire_repo_name("/repos"), "")
    assert_equal(codeworks_git_wire_repo_name("/workspaces/w1/reviews"), "")
    assert_equal(codeworks_git_wire_repo_name("/"), "")
    assert_equal(codeworks_git_wire_repo_name(""), "")
    # the suffix must end the first segment, not sit inside a later one
    assert_equal(codeworks_git_wire_repo_name("/a/b.git"), "")


def test_plane_and_owner_arm_are_separate_questions() raises:
    # same plane, different arms
    assert_equal(
        codeworks_plane_for("/repos"),
        codeworks_plane_for("/workspaces/w1/reviews"),
    )
    assert_equal(codeworks_owner_for("/repos"), CODEWORKS_OWNER_GIT)
    assert_equal(
        codeworks_owner_for("/workspaces/w1/reviews"), CODEWORKS_OWNER_REVIEW
    )
    assert_equal(
        codeworks_owner_for("/reviews/blob/abc"), CODEWORKS_OWNER_REVIEW
    )
    assert_equal(
        codeworks_owner_for("/acme-api.git/git-upload-pack"),
        CODEWORKS_OWNER_GIT,
    )


def test_probes_are_declared_infra_owned_by_the_git_arm() raises:
    var probes = List[String]()
    probes.append("/healthz")
    probes.append("/livez")
    probes.append("healthz")
    probes.append("/livez?x=1")
    for i in range(len(probes)):
        var p = probes[i]
        assert_equal(codeworks_plane_for(p), CODEWORKS_PLANE_INFRA)
        assert_true(codeworks_path_is_infra(p))
        assert_equal(codeworks_owner_for(p), CODEWORKS_OWNER_GIT)
        assert_equal(codeworks_control_surface_for(p), CODEWORKS_SURFACE_NONE)
        # a probe is no arm's declared resource route
        assert_false(codeworks_path_owned_by_git(p))
        assert_false(codeworks_path_owned_by_review(p))
    assert_false(codeworks_path_is_infra("/health"))
    assert_false(codeworks_path_is_infra("/healthzz"))


def _claims(path: String) -> Int:
    var n = 0
    if codeworks_path_owned_by_git(path):
        n += 1
    if codeworks_path_owned_by_review(path):
        n += 1
    return n


def test_every_declared_route_has_exactly_one_owner() raises:
    var paths = List[String]()
    var owners = List[Int]()
    var wire = _wire_paths()
    for i in range(len(wire)):
        paths.append(wire[i])
        owners.append(CODEWORKS_OWNER_GIT)
    paths.append("/repos")
    owners.append(CODEWORKS_OWNER_GIT)
    paths.append("/repos/acme-api")
    owners.append(CODEWORKS_OWNER_GIT)
    paths.append("/workspaces/w1/reviews")
    owners.append(CODEWORKS_OWNER_REVIEW)
    paths.append("/workspaces/w1/reviews/r1/verdict")
    owners.append(CODEWORKS_OWNER_REVIEW)
    paths.append("/workspaces/w1/review-policy")
    owners.append(CODEWORKS_OWNER_REVIEW)
    paths.append("/reviews/blob/abc")
    owners.append(CODEWORKS_OWNER_REVIEW)
    for i in range(len(paths)):
        assert_equal(codeworks_owner_for(paths[i]), owners[i])
        assert_equal(_claims(paths[i]), 1)


def test_undeclared_paths_are_unknown_and_unclaimed() raises:
    var unknown = List[String]()
    unknown.append("/")
    unknown.append("")
    unknown.append("/admin")
    unknown.append("/v1/devices")
    unknown.append("/workspaces/w1")  # a bare workspace is not review
    unknown.append("/workspaces")
    unknown.append("/review-policy")  # only under /workspaces/
    unknown.append("/reviewsx")
    unknown.append("/acme-api/info/refs")  # no .git: not the wire
    unknown.append("/a/repos")  # repos is only a first segment
    for i in range(len(unknown)):
        assert_equal(codeworks_plane_for(unknown[i]), CODEWORKS_PLANE_UNKNOWN)
        assert_equal(
            codeworks_control_surface_for(unknown[i]), CODEWORKS_SURFACE_NONE
        )
        assert_equal(codeworks_owner_for(unknown[i]), CODEWORKS_OWNER_NONE)
        assert_equal(_claims(unknown[i]), 0)


def test_review_predicate_matches_the_policy_route_and_not_a_bare_workspace() raises:
    assert_true(codeworks_path_owned_by_review("/workspaces/w1/reviews"))
    assert_true(codeworks_path_owned_by_review("/workspaces/w1/review-policy"))
    assert_true(codeworks_path_owned_by_review("/reviews/blob/abc"))
    assert_false(codeworks_path_owned_by_review("/workspaces/w1"))
    assert_false(codeworks_path_owned_by_review("/repos"))


def main() raises:
    test_repository_and_review_routes_are_one_control_plane()
    test_git_wire_is_its_own_plane_and_repository_routes_are_not_on_it()
    test_a_repository_named_like_a_route_is_still_the_wire()
    test_wire_repository_name_is_extracted_without_suffix_or_query()
    test_plane_and_owner_arm_are_separate_questions()
    test_probes_are_declared_infra_owned_by_the_git_arm()
    test_every_declared_route_has_exactly_one_owner()
    test_undeclared_paths_are_unknown_and_unclaimed()
    test_review_predicate_matches_the_policy_route_and_not_a_bare_workspace()
    print("PASS test_surface")
