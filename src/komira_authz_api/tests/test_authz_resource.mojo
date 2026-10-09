# =============================================================================
# test_authz_resource.mojo — `AuthzResource` is a kind, an opaque id and an
# attribute map, and nothing else.
# =============================================================================
#
#   - both constructors keep `kind` and `id` exactly as given (an empty id, for
#     an action on the kind as a whole, included);
#   - the two-field constructor starts with no attributes; the three-field one
#     keeps the map it is given;
#   - `with_attribute` adds a key, replaces an existing key in place, and keeps
#     `kind` and `id`;
#   - a copy is independent: an attribute set on the copy does not reach the
#     original.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_authz_api import AuthzResource
from komira_http_server.middleware import Claims


def test_kind_and_id_are_kept() raises:
    var r = AuthzResource(kind=String("mail.mailbox"), id=String("mb-7"))
    assert_equal(r.kind, String("mail.mailbox"))
    assert_equal(r.id, String("mb-7"))
    assert_equal(r.attributes.len(), 0, "no attributes unless set")

    var whole = AuthzResource(kind=String("repo"), id=String(""))
    assert_equal(whole.kind, String("repo"))
    assert_equal(whole.id, String(""))


def test_attributes_constructor_and_with_attribute() raises:
    var a = Claims()
    a.set(String("label"), String("draft"))
    var r = AuthzResource(
        kind=String("document"), id=String("d-1"), attributes=a^
    )
    assert_equal(r.attributes.len(), 1)
    assert_equal(r.attributes.get(String("label")).value(), String("draft"))

    var s = r^.with_attribute(String("size"), String("3")).with_attribute(
        String("label"), String("final")
    )
    assert_equal(s.kind, String("document"))
    assert_equal(s.id, String("d-1"))
    assert_equal(s.attributes.len(), 2, "replacing a key adds no entry")
    assert_equal(s.attributes.key_at(0), String("label"), "first-set order kept")
    assert_equal(s.attributes.value_at(0), String("final"))
    assert_equal(s.attributes.get(String("size")).value(), String("3"))


def test_copy_is_independent() raises:
    var r = AuthzResource(kind=String("repo"), id=String("r-1"))
    var c = r.copy().with_attribute(String("k"), String("v"))
    assert_true(c.attributes.has(String("k")))
    assert_false(r.attributes.has(String("k")), "the original is unchanged")


def main() raises:
    test_kind_and_id_are_kept()
    test_attributes_constructor_and_with_attribute()
    test_copy_is_independent()
    print("PASS komira_authz_api AuthzResource")
