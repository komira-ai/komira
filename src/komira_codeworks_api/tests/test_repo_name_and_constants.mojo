# The legal-repository-name check and the declared constants. What each test
# would catch:
# - names are accepted over exactly [A-Za-z0-9._-] (a class that admits '/',
#   a space, a NUL, '~' or a non-ASCII letter fails; one that rejects '_' or
#   '-' or '.' inside a name fails);
# - an empty name, a leading '.', and any '..' run are rejected, including at
#   the end of the name;
# - nothing is normalised: `acme.git` and mixed case are accepted as given;
# - the resource type keys, service id, marker and route literals keep their
#   spellings, since gates and validators key on the bytes.

from std.testing import assert_equal, assert_false, assert_true

from komira_codeworks_api import (
    CODEWORKS_GIT_SUFFIX,
    CODEWORKS_INFRA_HEALTHZ,
    CODEWORKS_INFRA_LIVEZ,
    CODEWORKS_MARKER_HEADER,
    CODEWORKS_MARKER_VALUE,
    CODEWORKS_REPOS_SEGMENT,
    CODEWORKS_RESOURCE_TYPE_REPO,
    CODEWORKS_RESOURCE_TYPE_REVIEW,
    CODEWORKS_REVIEW_POLICY_SEGMENT,
    CODEWORKS_REVIEW_PREFIX,
    CODEWORKS_REVIEW_SEGMENT,
    CODEWORKS_REVIEW_WORKSPACES_PREFIX,
    CODEWORKS_SERVICE,
    codeworks_repo_name_is_safe,
)


def test_legal_names_are_accepted() raises:
    var names = List[String]()
    names.append("a")
    names.append("acme-api")
    names.append("acme_api")
    names.append("Acme.API")
    names.append("v1.2.3")
    names.append("a.b")
    names.append("0")
    names.append("x-")
    names.append("acme.git")
    names.append("AZaz09._-")
    for i in range(len(names)):
        assert_true(codeworks_repo_name_is_safe(names[i]), names[i])


def test_illegal_names_are_rejected() raises:
    assert_false(codeworks_repo_name_is_safe(""))
    assert_false(codeworks_repo_name_is_safe("."))
    assert_false(codeworks_repo_name_is_safe(".hidden"))
    assert_false(codeworks_repo_name_is_safe(".."))
    assert_false(codeworks_repo_name_is_safe("a..b"))
    assert_false(codeworks_repo_name_is_safe("ab.."))
    assert_false(codeworks_repo_name_is_safe("a/b"))
    assert_false(codeworks_repo_name_is_safe("/a"))
    assert_false(codeworks_repo_name_is_safe("../a"))
    assert_false(codeworks_repo_name_is_safe("a b"))
    assert_false(codeworks_repo_name_is_safe("a\\b"))
    assert_false(codeworks_repo_name_is_safe("a?b"))
    assert_false(codeworks_repo_name_is_safe("a~b"))
    assert_false(codeworks_repo_name_is_safe("a:b"))
    assert_false(codeworks_repo_name_is_safe("a@b"))
    assert_false(codeworks_repo_name_is_safe("a[b"))
    assert_false(codeworks_repo_name_is_safe("a`b"))
    assert_false(codeworks_repo_name_is_safe("a{b"))
    assert_false(codeworks_repo_name_is_safe("a\nb"))
    assert_false(codeworks_repo_name_is_safe(chr(0)))
    assert_false(codeworks_repo_name_is_safe("café"))


def test_declared_constants_keep_their_spellings() raises:
    assert_equal(String(CODEWORKS_SERVICE), "codeworks")
    assert_equal(String(CODEWORKS_RESOURCE_TYPE_REPO), "codeworks.repo")
    assert_equal(String(CODEWORKS_RESOURCE_TYPE_REVIEW), "codeworks.review")
    assert_equal(String(CODEWORKS_MARKER_HEADER), "x-komira-codeworks")
    assert_equal(String(CODEWORKS_MARKER_VALUE), "1")
    # the marker header name is lowercase, so a header map keeps one entry
    assert_equal(
        String(CODEWORKS_MARKER_HEADER).lower(), String(CODEWORKS_MARKER_HEADER)
    )
    assert_equal(String(CODEWORKS_GIT_SUFFIX), ".git")
    assert_equal(String(CODEWORKS_REPOS_SEGMENT), "repos")
    assert_equal(String(CODEWORKS_REVIEW_WORKSPACES_PREFIX), "/workspaces/")
    assert_equal(String(CODEWORKS_REVIEW_PREFIX), "/reviews/")
    assert_equal(String(CODEWORKS_REVIEW_SEGMENT), "/reviews")
    assert_equal(String(CODEWORKS_REVIEW_POLICY_SEGMENT), "/review-policy")
    assert_equal(String(CODEWORKS_INFRA_HEALTHZ), "healthz")
    assert_equal(String(CODEWORKS_INFRA_LIVEZ), "livez")


def main() raises:
    test_legal_names_are_accepted()
    test_illegal_names_are_rejected()
    test_declared_constants_keep_their_spellings()
    print("PASS test_repo_name_and_constants")
