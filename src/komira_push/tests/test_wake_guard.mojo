# =============================================================================
# komira_push/tests/test_wake_guard.mojo
#   A wake carries id, kind and source, and nothing else.
# =============================================================================
#
# test_wake_trigger_has_only_the_three_fields reads WakeTrigger's fields by
# reflection: a field added to it (a `title`, a `body`) turns it red. The
# struct guard is also shown refusing a struct with an extra field, so the
# check is seen to fire, not only to pass.
#
# The plaintext is pinned byte for byte, and the payload guard refuses each
# way a plaintext can leave the shape: an extra member, a non-string value, a
# duplicate member, a non-object. Each message is asserted exactly; none
# quotes a value.
# =============================================================================

from std.testing import assert_equal

from komira_push import (
    WakeTrigger,
    check_wake_fields,
    check_wake_payload,
    check_wake_trigger_shape,
)


struct _WithTitle:
    var id: String
    var kind: String
    var source: String
    var title: String


struct _Subset:
    var id: String
    var kind: String


def _err_fields[T: AnyType]() -> String:
    try:
        check_wake_fields[T]()
    except e:
        return String(e)
    return String("<accepted>")


def _err_payload(text: String) -> String:
    try:
        check_wake_payload(text)
    except e:
        return String(e)
    return String("<accepted>")


def test_wake_trigger_has_only_the_three_fields() raises:
    check_wake_trigger_shape()
    assert_equal(reflect[WakeTrigger].field_count(), 3)


def test_a_struct_with_a_title_is_refused() raises:
    assert_equal(
        _err_fields[_WithTitle](),
        String(
            "komira_push: a wake carries only id, kind and source; the type"
            " has a field named title"
        ),
    )


def test_a_subset_of_the_fields_is_accepted() raises:
    assert_equal(_err_fields[_Subset](), String("<accepted>"))


def test_the_plaintext_byte_for_byte() raises:
    var w = WakeTrigger(String("item-7"), String("failed"), String("jobs"))
    var text = w.payload_json()
    assert_equal(text, String('{"id":"item-7","kind":"failed","source":"jobs"}'))
    check_wake_payload(text)


def test_the_plaintext_escapes_quotes() raises:
    var w = WakeTrigger(String('a"b'), String("k\\"), String("s"))
    var text = w.payload_json()
    assert_equal(text, String('{"id":"a\\"b","kind":"k\\\\","source":"s"}'))
    check_wake_payload(text)


def test_an_empty_field_is_refused() raises:
    var msg = String("<accepted>")
    try:
        _ = WakeTrigger(String("i"), String("k"), String("")).payload_json()
    except e:
        msg = String(e)
    assert_equal(msg, String("komira_push: the wake source is empty"))


def _err_wake(id: String, kind: String, source: String) -> String:
    try:
        _ = WakeTrigger(id.copy(), kind.copy(), source.copy()).payload_json()
    except e:
        return String(e)
    return String("<accepted>")


def test_an_empty_id_or_kind_is_refused() raises:
    # Each field is checked on its own: a wake missing only its id, or only
    # its kind, names that field (the other two are present).
    assert_equal(
        _err_wake(String(""), String("k"), String("s")),
        String("komira_push: the wake id is empty"),
    )
    assert_equal(
        _err_wake(String("i"), String(""), String("s")),
        String("komira_push: the wake kind is empty"),
    )


def test_an_extra_member_is_refused() raises:
    assert_equal(
        _err_payload(
            String('{"id":"i","kind":"k","source":"s","title":"secret"}')
        ),
        String(
            "komira_push: a wake payload carries only id, kind and source; it"
            " has a member named title"
        ),
    )


def test_a_non_string_member_is_refused() raises:
    assert_equal(
        _err_payload(String('{"id":"i","kind":{"text":"secret"}}')),
        String("komira_push: the wake payload member kind is not a string"),
    )


def test_a_duplicate_member_is_refused() raises:
    assert_equal(
        _err_payload(String('{"id":"i","id":"j"}')),
        String("komira_push: the wake payload member id appears twice"),
    )
    assert_equal(
        _err_payload(String('{"kind":"a","kind":"b"}')),
        String("komira_push: the wake payload member kind appears twice"),
    )
    assert_equal(
        _err_payload(String('{"source":"a","source":"b"}')),
        String("komira_push: the wake payload member source appears twice"),
    )


def test_a_non_object_is_refused() raises:
    assert_equal(
        _err_payload(String('["i","k","s"]')),
        String("komira_push: a wake payload is a JSON object"),
    )


def test_a_subset_payload_is_accepted() raises:
    assert_equal(_err_payload(String('{"id":"i"}')), String("<accepted>"))


def main() raises:
    test_wake_trigger_has_only_the_three_fields()
    test_a_struct_with_a_title_is_refused()
    test_a_subset_of_the_fields_is_accepted()
    test_the_plaintext_byte_for_byte()
    test_the_plaintext_escapes_quotes()
    test_an_empty_field_is_refused()
    test_an_empty_id_or_kind_is_refused()
    test_an_extra_member_is_refused()
    test_a_non_string_member_is_refused()
    test_a_duplicate_member_is_refused()
    test_a_non_object_is_refused()
    test_a_subset_payload_is_accepted()
    print("PASS komira_push wake guard")
