# =============================================================================
# test_chat_store_keys.mojo -- the id shape, the subject key, the DM id and
#   the id-list form, with no database.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_chat_store import (
    dm_channel_id,
    is_valid_id,
    join_ids,
    split_ids,
    subject_key,
)


def _ids(*xs: StaticString) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _raised(ids: List[String]) -> String:
    try:
        _ = dm_channel_id(ids)
    except e:
        return String(e)
    return String("<returned>")


def test_id_shape() raises:
    assert_true(is_valid_id(String("u-Alice_09")))
    var max_id = String()
    for _ in range(64):
        max_id += String("a")
    assert_true(is_valid_id(max_id), "64 bytes is the limit")
    assert_false(is_valid_id(max_id + String("a")), "65 bytes is refused")
    assert_false(is_valid_id(String("")), "empty")
    assert_false(is_valid_id(String("a,b")), "the id-list separator")
    assert_false(is_valid_id(String("a.b")), "the DM-id separator")
    assert_false(is_valid_id(String("a/b")), "a document-name separator")
    assert_false(is_valid_id(String("a b")), "a space")
    assert_false(is_valid_id(String("é")), "non-ASCII")


def test_subject_key_is_injective() raises:
    assert_equal(subject_key(String("a"), String("bc")), String("1:abc"))
    assert_equal(subject_key(String("ab"), String("c")), String("2:abc"))
    assert_equal(
        subject_key(String("https://issuer.example"), String("/7")),
        String("22:https://issuer.example/7"),
    )


def test_dm_channel_id_vectors() raises:
    assert_equal(
        dm_channel_id(_ids("u-bob", "u-alice")),
        String("dm-u-alice.u-bob"),
    )
    # Order and repeats do not matter: one set of users has one DM.
    assert_equal(
        dm_channel_id(_ids("u-alice", "u-bob", "u-alice")),
        String("dm-u-alice.u-bob"),
    )
    assert_equal(
        dm_channel_id(_ids("u-carol", "u-alice", "u-bob")),
        String("dm-u-alice.u-bob.u-carol"),
    )


def test_dm_channel_id_refusals() raises:
    assert_equal(
        _raised(_ids("u-alice", "u-alice")),
        String("komira_chat_store: a DM holds 2 to 9 distinct users, not 1"),
    )
    assert_equal(
        _raised(_ids("a", "b", "c", "d", "e", "f", "g", "h", "i", "j")),
        String("komira_chat_store: a DM holds 2 to 9 distinct users, not 10"),
    )
    assert_equal(
        _raised(_ids("u-alice", "u,bob")),
        String('komira_chat_store: invalid user id "u,bob"'),
    )


def test_id_lists() raises:
    assert_equal(len(split_ids(String(""))), 0)
    var xs = split_ids(String("a,b-1,c_2"))
    assert_equal(len(xs), 3)
    assert_equal(xs[1], String("b-1"))
    assert_equal(join_ids(xs), String("a,b-1,c_2"))
    assert_equal(join_ids(List[String]()), String(""))


def main() raises:
    test_id_shape()
    test_subject_key_is_injective()
    test_dm_channel_id_vectors()
    test_dm_channel_id_refusals()
    test_id_lists()
    print("PASS komira_chat_store keys")
