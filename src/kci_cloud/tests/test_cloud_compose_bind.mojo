# =============================================================================
# test_cloud_compose_bind.mojo
# =============================================================================
#
# BINDINGS AND PRESENCE (compose_bind.mojo, compose.mojo), expanded. Pure: no
# cloud. One definition, `acme.w@1`, holds a service `api`, a container job
# `job` and a schedule `tick` that starts it; its inputs reach them through
# bindings of every type, and `tick` exists only when `cron` is set.
#
# `logs`, a bucket, exists by `cron` too (a declared output reads it).
#
# 1. EVERY TYPE IS WRITTEN, golden: a STRING (`service.health_path`,
#    `schedule.cron`), an INT (`service.port`, `container_job.max_retries`),
#    a BOOL into a flag (`service.public`), an IMAGE (`service.image`,
#    `container_job.image`) and a VALUE_MAP merged into the env the
#    component writes (`service.env`). The expanded list is frozen as proto3
#    JSON, one resource per line.
# 2. AN UNSET INPUT WRITES NOTHING: unbound, `port` leaves the port the
#    component writes, `env` leaves its env, `cron` leaves `tick` ABSENT (no
#    resource, no tree line); `open: false` leaves the service not public.
# 3. AN ABSENT COMPONENT IS REFUSED WHERE IT IS NAMED: through `path` from
#    the top of the list (exported), through `local` from a sibling, and
#    through a declared output read from it; each one finding.
# 4. PASSED DOWN: `acme.outer@1` holds an instance of `acme.w@1` and passes
#    its own IMAGE and VALUE_MAP inputs down with bindings
#    (`composite.image_input.img`, `composite.map_input.env`) and its STRING
#    `cron` as `Value.input`. Set at the top, the nested `tick` exists and
#    the image and the env arrive; unset at the top, the nested `tick` is
#    absent (an input passed down from an unset input is unset).
# 5. A STRING WRITTEN TO A PLAIN FIELD IS A LITERAL: bound to another
#    resource's output, or to a parameter, it is one finding at expansion.
# 6. A VALUE_MAP KEY THE COMPONENT WRITES TOO is one finding.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json, encode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import Catalog, Expansion, expand


def _defs(texts: List[String]) raises -> List[CompositeDefinition]:
    var out = List[CompositeDefinition]()
    for i in range(len(texts)):
        out.append(decode_json[CompositeDefinition](texts[i]))
    return out^


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _one_def(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _two_defs(a: String, b: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    return l^


def _lines(x: Expansion) raises -> String:
    var s = String("")
    for i in range(len(x.resources)):
        s += encode_json(x.resources[i]) + String("\n")
    return s^


def _findings(x: Expansion) -> String:
    var s = String("")
    for i in range(len(x.findings)):
        s += x.findings[i].resource_id + String(" | ") + x.findings[i].field_path + String(" | ") + x.findings[i].reason + String("\n")
    return s^


def _one(x: Expansion, rid: String, field: String, needle: String) raises:
    var got = _findings(x)
    assert_equal(len(x.findings), 1, String("one finding (") + needle + String("), got:\n") + got)
    assert_equal(x.findings[0].resource_id, rid, got)
    assert_equal(x.findings[0].field_path, field, got)
    assert_true(x.findings[0].reason.find(needle) >= 0, String("reason holds ") + needle + String(":\n") + got)


comptime _W = (
    '{"name":"acme.w","version":"1",'
    + '"input":[{"name":"img","type":"INPUT_IMAGE","required":true},'
    + '{"name":"port","type":"INPUT_INT"},'
    + '{"name":"open","type":"INPUT_BOOL","required":true},'
    + '{"name":"health","type":"INPUT_STRING","default":{"literal":"/healthz"}},'
    + '{"name":"env","type":"INPUT_VALUE_MAP"},'
    + '{"name":"retries","type":"INPUT_INT"},'
    + '{"name":"cron","type":"INPUT_STRING"}],'
    + '"component":['
    + '{"id":"api","service":{"port":9000,"env":{"FIXED":{"literal":"1"}}}},'
    + '{"id":"job","containerJob":{}},'
    + '{"id":"tick","schedule":{"target":{"local":"job"}}},'
    + '{"id":"logs","bucket":{}}],'
    + '"bind":['
    + '{"component":"api","field":"service.image","input":"img"},'
    + '{"component":"api","field":"service.port","input":"port"},'
    + '{"component":"api","field":"service.public","input":"open"},'
    + '{"component":"api","field":"service.health_path","input":"health"},'
    + '{"component":"api","field":"service.env","input":"env"},'
    + '{"component":"job","field":"container_job.image","input":"img"},'
    + '{"component":"job","field":"container_job.max_retries","input":"retries"},'
    + '{"component":"tick","field":"schedule.cron","input":"cron"}],'
    + '"presence":[{"component":"tick","ifInput":"cron"},{"component":"logs","ifInput":"cron"}],'
    + '"output":[{"name":"url","from":{"local":"api","standard":"URL"}},'
    + '{"name":"logs_name","from":{"local":"logs","standard":"NAME"}}],'
    + '"export":["api","tick"]}'
)


def _w_list(inputs: String, image: Bool = True, env: Bool = True) -> String:
    var s = String('{"resource":[{"id":"w","composite":{"definition":"acme.w","version":"1","input":{') + inputs + String("}")
    if image:
        s += String(',"imageInput":{"img":{"digest":"sha256:a1"}}')
    if env:
        s += String(',"mapInput":{"env":{"value":{"LEVEL":{"literal":"debug"},"PEER":{"ref":{"resource":"peer","standard":"URL"}}}}}')
    s += String("}}")
    s += String(',{"id":"peer","service":{"image":{"digest":"sha256:b2"},"internal":{}}}]}')
    return s^


comptime _ALL = '"port":{"literal":"8081"},"open":{"literal":"true"},"retries":{"literal":"0"},"cron":{"literal":"0 3 * * *"}'

comptime _GOLDEN_ALL = (
    '{"id":"w/api","service":{"image":{"digest":"sha256:a1"},"port":8081,"env":{"FIXED":{"literal":"1"},"LEVEL":{"literal":"debug"},"PEER":{"ref":{"resource":"peer","standard":"URL"}}},"healthPath":"/healthz","public":{}}}\n'
    + '{"id":"w/job","containerJob":{"image":{"digest":"sha256:a1"},"maxRetries":0}}\n'
    + '{"id":"w/tick","schedule":{"cron":"0 3 * * *","target":{"resource":"w/job"}}}\n'
    + '{"id":"w/logs","bucket":{}}\n'
    + '{"id":"peer","service":{"image":{"digest":"sha256:b2"},"internal":{}}}\n'
)


def test_every_type_is_written() raises:
    """Catches: a binding not applied (N1), a BOOL that cannot write a flag
    message (N2), a VALUE_MAP that replaces the component's env instead of
    adding to it (N3), an INT written as a string (refused by the decoder),
    a STRING default not written, and an explicit zero dropped."""
    var x = expand(Catalog.v1(), _defs(_one_def(String(_W))), _list(_w_list(String(_ALL))))
    assert_equal(len(x.findings), 0, _findings(x))
    assert_equal(_lines(x), String(_GOLDEN_ALL), "the expanded list")
    assert_equal(x.tree.find("w/tick: schedule") >= 0, True, x.tree)
    print("  test_every_type_is_written: PASS")


comptime _GOLDEN_UNSET = (
    '{"id":"w/api","service":{"image":{"digest":"sha256:a1"},"port":9000,"env":{"FIXED":{"literal":"1"}},"healthPath":"/healthz"}}\n'
    + '{"id":"w/job","containerJob":{"image":{"digest":"sha256:a1"}}}\n'
    + '{"id":"peer","service":{"image":{"digest":"sha256:b2"},"internal":{}}}\n'
)


def test_an_unset_input_writes_nothing() raises:
    """Catches: an unset input clearing the field the component writes, a
    false BOOL writing the flag (N4), and a component whose presence input
    is unset expanded anyway (N5)."""
    var x = expand(Catalog.v1(), _defs(_one_def(String(_W))), _list(_w_list(String('"open":{"literal":"false"}'), env=False)))
    assert_equal(len(x.findings), 0, _findings(x))
    assert_equal(_lines(x), String(_GOLDEN_UNSET), "the expanded list")
    assert_equal(x.tree.find("w/tick"), -1, String("an absent component has no tree line:\n") + x.tree)
    for i in range(len(x.produced)):
        assert_true(x.produced[i] != "w/tick", "w/tick is not produced")
    print("  test_an_unset_input_writes_nothing: PASS")


def test_an_absent_component_is_refused_where_named() raises:
    """Catches: a reference to an absent component accepted (it would name a
    resource that is never created) through a path (N6), a sibling's
    `local`, or a declared output."""
    var unset = String('"open":{"literal":"false"}')
    var by_path = _w_list(unset, env=False).replace(
        ',{"id":"peer","service":{"image":{"digest":"sha256:b2"},"internal":{}}}',
        ',{"id":"peer","service":{"image":{"digest":"sha256:b2"},"internal":{}},"uses":[{"target":{"resource":"w","path":"tick"},"access":"READ"}]}',
    )
    var x = expand(Catalog.v1(), _defs(_one_def(String(_W))), _list(by_path))
    _one(x, "peer", "uses[0].target", "component \"w/tick\" is absent: input \"cron\" of acme.w@1 is not set")
    var by_output = _w_list(unset, env=False).replace(
        '"internal":{}}}',
        '"internal":{},"env":{"T":{"ref":{"resource":"w","named":"logs_name"}}}}}',
    )
    x = expand(Catalog.v1(), _defs(_one_def(String(_W))), _list(by_output))
    _one(x, "peer", "service.env.T", "component \"w/logs\" is absent")
    var sibling = String(_W).replace(
        '{"id":"job","containerJob":{}}',
        '{"id":"job","containerJob":{"env":{"T":{"ref":{"local":"logs","standard":"NAME"}}}}}',
    )
    x = expand(Catalog.v1(), _defs(_one_def(sibling)), _list(_w_list(unset, env=False)))
    _one(x, "w/job", "container_job.env.T", "component \"w/logs\" is absent")
    print("  test_an_absent_component_is_refused_where_named: PASS")


comptime _OUTER = (
    '{"name":"acme.outer","version":"1",'
    + '"input":[{"name":"web_image","type":"INPUT_IMAGE","required":true},'
    + '{"name":"web_env","type":"INPUT_VALUE_MAP"},'
    + '{"name":"cron","type":"INPUT_STRING"}],'
    + '"component":[{"id":"web","composite":{"definition":"acme.w","version":"1",'
    + '"input":{"open":{"literal":"true"},"cron":{"input":"cron"}}}}],'
    + '"bind":[{"component":"web","field":"composite.image_input.img","input":"web_image"},'
    + '{"component":"web","field":"composite.map_input.env","input":"web_env"}]}'
)


def _outer_list(cron: Bool) -> String:
    var s = String('{"resource":[{"id":"o","composite":{"definition":"acme.outer","version":"1",')
    if cron:
        s += String('"input":{"cron":{"literal":"0 3 * * *"}},')
    s += String('"imageInput":{"web_image":{"digest":"sha256:c3"}},')
    s += String('"mapInput":{"web_env":{"value":{"LEVEL":{"literal":"info"}}}}}}]}')
    return s^


def test_passed_down() raises:
    """Catches: an IMAGE or VALUE_MAP binding into a nested instance not
    passed (N7: the nested required `img` is then reported unbound, or the
    env does not arrive), and an input passed down from an unset input
    counted as set (N8: the nested `tick` would exist, with no cron)."""
    var x = expand(Catalog.v1(), _defs(_two_defs(String(_W), String(_OUTER))), _list(_outer_list(True)))
    assert_equal(len(x.findings), 0, _findings(x))
    var got = _lines(x)
    assert_true(got.find('{"id":"o/web/api","service":{"image":{"digest":"sha256:c3"}') >= 0, got)
    assert_true(got.find('"LEVEL":{"literal":"info"}') >= 0, got)
    assert_true(got.find('{"id":"o/web/tick","schedule":{"cron":"0 3 * * *","target":{"resource":"o/web/job"}}}') >= 0, got)
    x = expand(Catalog.v1(), _defs(_two_defs(String(_W), String(_OUTER))), _list(_outer_list(False)))
    assert_equal(len(x.findings), 0, _findings(x))
    got = _lines(x)
    assert_equal(got.find("o/web/tick"), -1, String("unset at the top, the nested tick is absent:\n") + got)
    assert_true(got.find('"containerJob":{"image":{"digest":"sha256:c3"}}') >= 0, got)
    print("  test_passed_down: PASS")


def test_a_plain_field_takes_a_literal() raises:
    """Catches: a STRING bound to another resource's output or to a
    parameter written into a plain field (N9: the reference would be lost,
    or the decoder handed a message where it reads a string)."""
    var by_ref = _w_list(String('"open":{"literal":"false"},"cron":{"ref":{"resource":"peer","standard":"HOST"}}'), env=False)
    var x = expand(Catalog.v1(), _defs(_one_def(String(_W))), _list(by_ref))
    _one(x, "w/tick", "bind[7] schedule.cron", "is another resource's output: a binding writes a literal into a plain field")
    var by_param = _w_list(String('"open":{"literal":"false"},"cron":{"param":"nightly"}'), env=False)
    x = expand(Catalog.v1(), _defs(_one_def(String(_W))), _list(by_param))
    _one(x, "w/tick", "bind[7] schedule.cron", "is a parameter")
    print("  test_a_plain_field_takes_a_literal: PASS")


def test_a_map_key_written_twice() raises:
    """Catches: a VALUE_MAP entry silently replacing (or silently dropped
    beside) the entry of the same key the component writes (N10)."""
    var twice = _w_list(String('"open":{"literal":"false"}')).replace('"LEVEL":{"literal":"debug"}', '"FIXED":{"literal":"2"}')
    var x = expand(Catalog.v1(), _defs(_one_def(String(_W))), _list(twice))
    _one(x, "w/api", "bind[4] service.env", "key \"FIXED\" is written by the component and by the input")
    print("  test_a_map_key_written_twice: PASS")


def main() raises:
    print("test_cloud_compose_bind: bindings of every type, presence, passing down")
    test_every_type_is_written()
    test_an_unset_input_writes_nothing()
    test_an_absent_component_is_refused_where_named()
    test_passed_down()
    test_a_plain_field_takes_a_literal()
    test_a_map_key_written_twice()
    print("ALL kci_cloud COMPOSE BIND TESTS PASSED")
