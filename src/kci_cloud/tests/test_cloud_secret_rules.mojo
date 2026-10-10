# =============================================================================
# test_cloud_secret_rules.mojo
# =============================================================================
#
# The secret primitive in kci_cloud: its catalog row, and the secret rules
# (secrets.mojo) through `graph_findings`, the cloud-independent half of
# validate. No cloud is needed: the fakes in kci_cloud_fake run these graphs
# on every shape.
#
# 1. THE SECRET ROW: field 16, the seventh body arm (after the queue);
#    PORTABLE; exposes NAME only; accepts READ, WRITE and READ_WRITE (not
#    CALL, SEND, RECEIVE or DESCRIBE); retention default KEEP (a written
#    DELETE wins); a reference lands on `<id>/secret`.
# 2. EVERY SECRET REFUSAL, IN ONE PASS, each pinned by resource, field path
#    and reason: `uses` on a secret; a `secret_env` entry naming both a name
#    and a secret, and naming neither; `store` beside `secret`; a `secret`
#    that names an output, a missing resource, or a queue; a `secret` the
#    receiving identity may not READ (a service's own identity with no edge
#    to it, and a job's `run_as` account that holds only WRITE); a variable
#    set by `env` and by a `secret`; ADDRESS read from a secret; CALL asked
#    of a secret by a `uses` line and DESCRIBE by a grant. Nothing else is
#    reported.
# 3. A GOOD SECRET GRAPH IS CLEAN: a service that READs a secret by `uses`
#    and receives it by `secret` (pinned to a version), beside a secret by
#    name and store; a job running as an account that may READ_WRITE a
#    secret by a grant; a WRITE grant from another account; a secret's NAME
#    read as a value; KEEP and DELETE written on secrets.
# 4. THE HELPERS: `secret_of` reads the `secret` arm (empty for a name), and
#    `secret_findings` and `secret_env_findings` find nothing on another
#    type.
# Each test names the defect it catches in its docstring.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    FIELD_QUEUE,
    FIELD_SECRET,
    PORTABLE,
    RETENTION_DELETE,
    RETENTION_KEEP,
    Catalog,
    Finding,
    body_arms,
    effective_retention,
    graph_findings,
    primary_node,
    secret_env_findings,
    secret_findings,
    secret_of,
)


def _list(json: String) raises -> List[Resource]:
    return decode_json[ResourceList](json).resource.copy()


def _lines(findings: List[Finding]) -> List[String]:
    var out = List[String]()
    for i in range(len(findings)):
        out.append(findings[i].resource_id + String("|") + findings[i].field_path + String("|") + findings[i].reason)
    return out^


def _expect(lines: List[String], prefix: String, reason: String) raises:
    """Exactly one finding starts with `prefix` (`id|path|`) and holds
    `reason`."""
    var n = 0
    var all = String("")
    for i in range(len(lines)):
        all += lines[i] + String("\n")
        if lines[i].startswith(prefix) and lines[i].find(reason) >= 0:
            n += 1
    assert_equal(n, 1, String("one finding ") + prefix + String(" ... ") + reason + String(" in:\n") + all)


comptime IMG = '"image":{"digest":"sha256:0011"}'


# ---- 1. the secret row ----------------------------------------------------------


def test_the_secret_row() raises:
    """Catches: the row at another field or arm position (a decoded secret
    would map to another type), a portability other than PORTABLE, an output
    or a verb the design does not give a secret (ADDRESS; CALL, SEND,
    RECEIVE, DESCRIBE), a default other than KEEP (a removed secret would
    take every version of its value with it), and a primary role other than
    `secret`."""
    var c = Catalog.v1()
    assert_equal(FIELD_SECRET, 16)
    ref t = c.types[c.index_of(FIELD_SECRET)]
    assert_equal(t.name, "secret")
    assert_equal(t.portability, PORTABLE)
    assert_equal(body_arms()[6].field, FIELD_SECRET, "the seventh arm, after the queue")
    assert_equal(body_arms()[5].field, FIELD_QUEUE, "the queue stays the sixth")
    assert_equal(len(t.exposes), 1, "a secret exposes NAME only")
    assert_true(t.exposes_output(String("NAME")))
    assert_false(t.exposes_output(String("ADDRESS")))
    assert_equal(len(t.accepts), 3, "READ, WRITE and READ_WRITE")
    for verb in ["READ", "WRITE", "READ_WRITE"]:
        assert_true(t.accepts_access(String(verb)), String(verb))
    for verb in ["CALL", "SEND", "RECEIVE", "DESCRIBE"]:
        assert_false(t.accepts_access(String(verb)), String(verb))
    assert_equal(t.retention_default, RETENTION_KEEP, "a secret is kept by default")
    assert_equal(t.primary_role, "secret")
    var l = _list(String('{"resource":[{"id":"db","secret":{}},{"id":"tmp","retention":"DELETE","secret":{}}]}'))
    assert_equal(effective_retention(c, l[0]), RETENTION_KEEP, "unset: KEEP")
    assert_equal(effective_retention(c, l[1]), RETENTION_DELETE, "written DELETE")
    assert_equal(primary_node(c, l, String("db")), "db/secret")
    print("  test_the_secret_row: PASS")


# ---- 2. every refusal, in one pass ------------------------------------------------


def test_every_secret_refusal_in_one_pass() raises:
    """Catches: any one rule dropped (its line is missing), a rule that fires
    on the wrong resource or path, a reference accepted without a READ edge
    (or with WRITE taken for READ), a `run_as` account's edges not counted
    for a job, a READ finding about a `run_as` identity missing from the
    list (the total), and a rule that fires on a good entry (the total)."""
    var g = _list(
        String('{"resource":[')
        + String('{"id":"db","secret":{}},')
        + String('{"id":"other","secret":{}},')
        + String('{"id":"q","queue":{}},')
        + String('{"id":"s-uses","secret":{},"uses":[{"target":{"resource":"db"},"access":"READ"}]},')
        + String('{"id":"api","service":{') + String(IMG) + String(',"internal":{},')
        + String('"env":{"DUP":{"literal":"x"},"ADDR":{"ref":{"resource":"db","standard":"ADDRESS"}}},')
        + String('"secretEnv":{')
        + String('"BOTH":{"name":"legacy","secret":{"resource":"db"}},')
        + String('"NONE":{},')
        + String('"STORE":{"store":"primary","secret":{"resource":"db"}},')
        + String('"OUT":{"secret":{"resource":"db","standard":"NAME"}},')
        + String('"GONE":{"secret":{"resource":"nope"}},')
        + String('"QUEUE":{"secret":{"resource":"q"}},')
        + String('"NOREAD":{"secret":{"resource":"other"}},')
        + String('"DUP":{"secret":{"resource":"db"}}}},')
        + String('"uses":[{"target":{"resource":"db"},"access":"READ"},')
        + String('{"target":{"resource":"other"},"access":"CALL"}]},')
        + String('{"id":"wr","serviceAccount":{},"uses":[{"target":{"resource":"other"},"access":"WRITE"}]},')
        + String('{"id":"cron","containerJob":{') + String(IMG) + String(',"runAs":{"resource":"wr"},')
        + String('"secretEnv":{"K":{"secret":{"resource":"other"}}}}},')
        + String('{"id":"lost","containerJob":{') + String(IMG) + String(',"runAs":{"resource":"nobody"},')
        + String('"secretEnv":{"K":{"secret":{"resource":"db"}}}}},')
        + String('{"id":"g-describe","grant":{"principal":{"resource":"wr"},"target":{"resource":"db"},')
        + String('"access":"DESCRIBE"}}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), g))
    _expect(l, "s-uses|uses|", "a secret runs as no identity")
    _expect(l, "api|service.secret_env.BOTH|", "with both a name and a secret names two secrets")
    _expect(l, "api|service.secret_env.NONE|", "a secret reference with no name and no secret")
    _expect(l, "api|service.secret_env.STORE.store|", "a secret resource is in the store its cloud puts it in")
    _expect(l, "api|service.secret_env.OUT.secret|", "names a secret, not one of its outputs")
    _expect(l, "api|service.secret_env.GONE.secret|", 'ref to missing resource "nope"')
    _expect(l, "api|service.secret_env.QUEUE.secret|", 'must name a secret; "q" is not one')
    _expect(
        l,
        "api|service.secret_env.NOREAD.secret|",
        'identity "api" may not READ secret "other": the reference is not a grant',
    )
    _expect(l, "api|service.secret_env.DUP|", "the variable is set by env and by secret_env")
    _expect(l, "api|service.env.ADDR|", '"db" (secret) does not expose ADDRESS')
    _expect(l, "api|uses[1]|", 'secret "other" does not accept access CALL')
    _expect(l, "cron|container_job.secret_env.K.secret|", 'identity "wr" may not READ secret "other"')
    _expect(l, "g-describe|grant|", 'secret "db" does not accept access DESCRIBE')
    # a `run_as` naming no resource is refused once, on run_as; the READ rule
    # does not add a second finding about an identity that does not exist
    _expect(l, "lost|container_job.run_as|", 'ref to missing resource "nobody"')
    assert_equal(len(l), 14, "no other finding")
    print("  test_every_secret_refusal_in_one_pass: PASS")


# ---- 3. a good graph is clean -----------------------------------------------------


comptime _GOOD = (
    '{"resource":['
    '{"id":"db","secret":{}},'
    '{"id":"token","retention":"DELETE","secret":{}},'
    '{"id":"seed","retention":"KEEP","secret":{}},'
    '{"id":"api","service":{"image":{"digest":"sha256:0011"},"internal":{},'
    '"env":{"DB_NAME":{"ref":{"resource":"db","standard":"NAME"}}},'
    '"secretEnv":{"DB":{"secret":{"resource":"db"},"version":"3"},'
    '"LEGACY":{"name":"legacy","store":"primary"}}},'
    '"uses":[{"target":{"resource":"db"},"access":"READ"}]},'
    '{"id":"rot","serviceAccount":{}},'
    '{"id":"cron","containerJob":{"image":{"digest":"sha256:0011"},"runAs":{"resource":"rot"},'
    '"secretEnv":{"T":{"secret":{"resource":"token"}}}}},'
    '{"id":"rot-token","grant":{"principal":{"resource":"rot"},"target":{"resource":"token"},'
    '"access":"READ_WRITE"}},'
    '{"id":"writer","serviceAccount":{},"uses":[{"target":{"resource":"seed"},"access":"WRITE"}]}'
    "]}"
)


def test_a_good_secret_graph_is_clean() raises:
    """Catches: a READ edge by `uses` or a READ_WRITE grant not counted, a
    version refused beside `secret`, a reference by name and store refused
    beside one by `secret`, a `run_as` account's grant not counted for its
    job, WRITE refused on a secret, NAME refused as a secret's output, and
    KEEP or DELETE refused on a secret."""
    var l = _lines(graph_findings(Catalog.v1(), _list(String(_GOOD))))
    var all = String("")
    for i in range(len(l)):
        all += l[i] + String("\n")
    assert_equal(len(l), 0, String("a good secret graph is clean:\n") + all)
    print("  test_a_good_secret_graph_is_clean: PASS")


# ---- 4. the helpers -----------------------------------------------------------------


def test_the_helpers() raises:
    """Catches: `secret_of` reading the name (or nothing), and the secret
    rules firing on another type."""
    var g = _list(String(_GOOD))
    ref api = g[3]
    assert_equal(secret_of(api.service.value().secret_env["DB"]), "db")
    assert_equal(secret_of(api.service.value().secret_env["LEGACY"]), "", "a reference by name")
    assert_equal(len(secret_findings(FIELD_QUEUE, g[0])), 0, "asked as another type: nothing")
    assert_equal(len(secret_env_findings(g, g[0])), 0, "a secret has no secret_env")
    assert_equal(len(secret_env_findings(g, g[4])), 0, "a service account has no secret_env")
    print("  test_the_helpers: PASS")


def main() raises:
    print("test_cloud_secret_rules")
    test_the_secret_row()
    test_every_secret_refusal_in_one_pass()
    test_a_good_secret_graph_is_clean()
    test_the_helpers()
    print("ALL kci_cloud SECRET RULES TESTS PASSED")
