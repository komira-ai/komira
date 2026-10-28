# =============================================================================
# test_cloud_compose_map_keys.mojo
# =============================================================================
#
# A MAP KEY IS NOT A REFERENCE FIELD (compose_refs.unrewritten). Expansion
# raises when a rewritten primitive still holds a `local`, `input` or `path`
# field: a reference position `_walk` does not know. A key of `labels`,
# `env` or `secret_env` is author data, written in proto3 JSON the same way
# as a field name, so an environment variable `path` or a label key `input`
# must not trip the guard. Pure: no cloud.
#
# 1. EXPAND: a top-level service with an env variable `path`, `input` or
#    `local`, a bucket with a label key `input`, `local` or `path`, and a
#    service with a secret_env variable `local`, each expand to themselves
#    with no finding. Red before the fix: expand raised "expansion left a
#    composite reference ("path":) in "api"".
# 2. THE GUARD STILL SEES A REFERENCE: `unrewritten` on a primitive that
#    holds a composite-form reference returns its field, also when that
#    reference is the VALUE of a map entry (an env value `{"input":..}`, a
#    secret_env secret `{"local":..}`) or sits in `uses`. Skipping a map's
#    keys must not skip its values.
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import decode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import Catalog, expand, unrewritten


def _one(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](String('{"resource":[') + json + String("]}")).resource.copy()


def _expands_to_itself(json: String, what: String) raises:
    var list = _one(json)
    var x = expand(Catalog.v1(), List[CompositeDefinition](), list)
    assert_equal(len(x.findings), 0, what + String(": no finding"))
    assert_equal(len(x.resources), 1, what + String(": one primitive"))
    assert_equal(x.resources[0].id, "api", what + String(": the same id"))


comptime _SVC_HEAD = '{"id":"api","service":{"image":{"digest":"sha256:a1"},"port":8080,"internal":{}'


def test_a_map_key_spelled_like_a_reference_field_expands() raises:
    for key in [String("path"), String("input"), String("local")]:
        _expands_to_itself(
            String(_SVC_HEAD) + String(',"env":{"') + key + String('":{"literal":"/usr/bin"}}}}'),
            String("env ") + key,
        )
        _expands_to_itself(
            String('{"id":"api","labels":{"') + key + String('":"x"},"bucket":{}}'),
            String("label ") + key,
        )
    _expands_to_itself(
        String(_SVC_HEAD) + String(',"secret_env":{"local":{"name":"db-password"}}}}'),
        String("secret_env local"),
    )


def test_the_guard_still_sees_a_reference() raises:
    var env_value = _one(String(_SVC_HEAD) + String(',"env":{"path":{"input":"zone"}}}}'))
    assert_equal(unrewritten(env_value[0]), '"input":', "an env value of the composite form")
    var secret = _one(String(_SVC_HEAD) + String(',"secret_env":{"input":{"secret":{"local":"db"}}}}}'))
    assert_equal(unrewritten(secret[0]), '"local":', "a secret_env secret of the composite form")
    var uses = _one('{"id":"api","bucket":{},"uses":[{"target":{"resource":"db","path":"x"},"access":"READ"}]}')
    assert_equal(unrewritten(uses[0]), '"path":', "a path in uses")
    var plain = _one('{"id":"api","labels":{"path":"x"},"bucket":{}}')
    assert_equal(unrewritten(plain[0]), "", "a label key path alone")


def main() raises:
    print("test_cloud_compose_map_keys: a map key is not a reference field")
    test_a_map_key_spelled_like_a_reference_field_expands()
    test_the_guard_still_sees_a_reference()
    print("ALL kci_cloud COMPOSE MAP KEY TESTS PASSED")
