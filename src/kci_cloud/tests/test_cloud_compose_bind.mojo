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
# 7. EACH BINDING LANDS ON ITS OWN INSTANCE: `acme.two@1` passes a different
#    image to each of two instances of `acme.w@1`; an optional IMAGE input
#    left unset writes no image.
# 8. THE BINDING HELPERS, one by one: the type words; a BOOL into a bool
#    field, and into a flag message (true sets it, false removes it, a map
#    refuses both); a
#    VALUE_MAP written in key order; an input no definition declares is not
#    set; which inputs a nested instance sets (a `ref { input }` passed down
#    only when set, every image and map input); a binding into an instance
#    whose definition was not given leaves the finding to the instance.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json, encode_json
from kci_resource_proto.composite import CompositeDefinition
from kci_resource_proto.resource import Resource, ResourceList

from kci_resource_proto.refs import Value
from kci_cloud import Catalog, Expansion, expand, BindValue, bind_field, INPUT_BOOL, INPUT_REF, INPUT_VALUE_MAP
from kci_cloud import literal_value
from kci_cloud.compose_bind import bind_problems, input_type_name, is_set, nested_set_names


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


comptime _TWO = (
    '{"name":"acme.two","version":"1",'
    + '"input":[{"name":"img_a","type":"INPUT_IMAGE","required":true},{"name":"img_b","type":"INPUT_IMAGE","required":true}],'
    + '"component":[{"id":"a","composite":{"definition":"acme.w","version":"1","input":{"open":{"literal":"true"}}}},'
    + '{"id":"b","composite":{"definition":"acme.w","version":"1","input":{"open":{"literal":"false"}}}}],'
    + '"bind":[{"component":"a","field":"composite.image_input.img","input":"img_a"},'
    + '{"component":"b","field":"composite.image_input.img","input":"img_b"}]}'
)


def test_each_binding_lands_on_its_own_instance() raises:
    """Catches: a binding of the enclosing definition applied to every
    nested instance rather than the one it names (a would get b's image),
    and an unset optional IMAGE input that writes something."""
    var top = String('{"resource":[{"id":"t","composite":{"definition":"acme.two","version":"1",')
    top += String('"imageInput":{"img_a":{"digest":"sha256:aa"},"img_b":{"digest":"sha256:bb"}}}}]}')
    var x = expand(Catalog.v1(), _defs(_two_defs(String(_W), String(_TWO))), _list(top))
    assert_equal(len(x.findings), 0, _findings(x))
    var got = _lines(x)
    assert_true(got.find('{"id":"t/a/api","service":{"image":{"digest":"sha256:aa"}') >= 0, got)
    assert_true(got.find('{"id":"t/b/api","service":{"image":{"digest":"sha256:bb"}') >= 0, got)
    var optional = String(_W).replace('{"name":"img","type":"INPUT_IMAGE","required":true}', '{"name":"img","type":"INPUT_IMAGE"}')
    x = expand(Catalog.v1(), _defs(_one_def(optional)), _list(_w_list(String(_ALL), image=False, env=False)))
    assert_equal(len(x.findings), 0, _findings(x))
    got = _lines(x)
    assert_true(got.find('{"id":"w/api","service":{"port":8081,') >= 0, got)
    assert_true(got.find('{"id":"w/job","containerJob":{"maxRetries":0}}') >= 0, got)
    print("  test_each_binding_lands_on_its_own_instance: PASS")


def _svc(body: String) raises -> Resource:
    return decode_json[Resource](String('{"id":"s","service":{"port":1') + body + String("}}"))


def test_the_binding_helpers() raises:
    assert_equal(input_type_name(INPUT_BOOL), "BOOL")
    assert_equal(input_type_name(INPUT_REF), "REF")
    assert_equal(input_type_name(99), "99")
    # A BOOL into a flag message: true sets it, false removes it; a map is no flag.
    var on = BindValue(INPUT_BOOL, String("true"), None, Dict[String, Value]())
    var off = BindValue(INPUT_BOOL, String("false"), None, Dict[String, Value]())
    assert_equal(encode_json(bind_field(_svc(String("")), String("service.public"), on).resource.value()), '{"id":"s","service":{"port":1,"public":{}}}')
    assert_equal(encode_json(bind_field(_svc(String(',"public":{}')), String("service.public"), off).resource.value()), '{"id":"s","service":{"port":1}}')
    var bkt = decode_json[Resource](String('{"id":"b","bucket":{}}'))
    assert_equal(encode_json(bind_field(bkt, String("bucket.versioning"), on).resource.value()), '{"id":"b","bucket":{"versioning":true}}')
    var no = bind_field(_svc(String("")), String("service.env"), on)
    assert_false(Bool(no.resource))
    assert_true(no.err.byte_length() > 0)
    # A VALUE_MAP is written in key order, whatever order it was built in.
    var m = Dict[String, Value]()
    m["B"] = literal_value(String("b"))
    m["A"] = literal_value(String("a"))
    var vm = bind_field(_svc(String("")), String("service.env"), BindValue(INPUT_VALUE_MAP, String(""), None, m^))
    assert_equal(encode_json(vm.resource.value()), '{"id":"s","service":{"port":1,"env":{"A":{"literal":"a"},"B":{"literal":"b"}}}}')
    # What a nested instance sets.
    var d = decode_json[CompositeDefinition](
        String('{"name":"acme.n","version":"1","input":[{"name":"r","type":"INPUT_REF"}],"component":[')
        + String('{"id":"web","composite":{"definition":"acme.w","version":"1","input":{"peer":{"ref":{"input":"r"}}},')
        + String('"imageInput":{"img":{"digest":"sha256:a1"}},"mapInput":{"env":{"value":{}}}}}]}')
    )
    assert_false(is_set(d, List[String](), String("nope")))
    var set_r: List[String] = [String("r")]
    var names = nested_set_names(d, set_r, d.component[0])
    assert_equal(len(names), 3)
    assert_equal(names[0], "peer")
    assert_equal(names[1], "img")
    assert_equal(names[2], "env")
    names = nested_set_names(d, List[String](), d.component[0])
    assert_equal(len(names), 2, "a ref { input } passed down from an unset input is unset")
    # A binding into an instance whose definition was not given: the
    # instance's own finding names it, so the binding adds none.
    var b = decode_json[CompositeDefinition](
        String('{"name":"acme.b","version":"1","input":[{"name":"i","type":"INPUT_IMAGE"}],"component":[')
        + String('{"id":"web","composite":{"definition":"acme.gone","version":"1"}}],')
        + String('"bind":[{"component":"web","field":"composite.image_input.img","input":"i"}]}')
    )
    var nested = List[Optional[CompositeDefinition]]()
    nested.append(None)
    assert_equal(len(bind_problems(Catalog.v1(), b, String("acme.b@1"), nested)), 0)
    print("  test_the_binding_helpers: PASS")


def main() raises:
    print("test_cloud_compose_bind: bindings of every type, presence, passing down")
    test_every_type_is_written()
    test_an_unset_input_writes_nothing()
    test_an_absent_component_is_refused_where_named()
    test_passed_down()
    test_a_plain_field_takes_a_literal()
    test_a_map_key_written_twice()
    test_each_binding_lands_on_its_own_instance()
    test_the_binding_helpers()
    print("ALL kci_cloud COMPOSE BIND TESTS PASSED")
