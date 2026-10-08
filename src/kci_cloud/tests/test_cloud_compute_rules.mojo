# =============================================================================
# test_cloud_compute_rules.mojo
# =============================================================================
#
# The workloads in kci_cloud (service, container job, worker): their catalog
# rows, the shared view (workload.mojo) and the workload rules
# (compute.mojo) through `graph_findings`, the cloud-independent half of
# validate. No cloud is needed: the fakes in kci_cloud_fake run these graphs
# on every shape.
#
# 1. THE ROWS: a service (field 10, the first body arm), a container job
#    (11, the second, named `container_job`) and a worker (12, the third);
#    each PORTABLE; a service exposes URL and HOST, the other two nothing; a
#    service and a container job accept CALL only, a worker no verb; none
#    takes retention; a reference to each lands on `<id>/run`.
# 2. EVERY WORKLOAD REFUSAL, IN ONE PASS, each pinned by resource, field
#    path and reason (the list is in the test), with nothing else reported:
#    the image rules, `run_as`, `env`, `secret_env` and `command[0]` on a
#    worker or a container job as on a service; a worker's explicit
#    `replicas: 0`; retention on a worker; CALL on a worker; a worker with
#    `run_as` named as a grant's principal.
# 3. A GOOD COMPUTE GRAPH IS CLEAN: a worker with every field (command, env
#    by literal and by a queue's ADDRESS, a secret by name, three replicas,
#    a `run_as` account that RECEIVEs from the queue), a worker with its own
#    identity that is a grant's principal, a container job with a command
#    that a service may CALL, and a service with a command and GPUs.
# 4. THE HELPERS: `workload_of` (each kind, and none for a bucket),
#    `is_workload`, `worker_replicas` (written, the versioned default 1, and
#    0 for another type), `image_platform` of a worker, and a worker's
#    identity and edges (`holds_own_identity`, `run_as_of`, `edges_of`: its
#    `uses` lines and the implicit cell LOGS WRITE).
# Each test names the defect it catches in its docstring.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_json
from kci_resource_proto.resource import Resource, ResourceList

from kci_cloud import (
    FIELD_BUCKET,
    FIELD_CONTAINER_JOB,
    FIELD_SERVICE,
    FIELD_WORKER,
    PORTABLE,
    WORKER_REPLICAS_DEFAULT,
    Catalog,
    Finding,
    body_arms,
    edges_of,
    graph_findings,
    holds_own_identity,
    image_platform,
    is_workload,
    primary_node,
    run_as_of,
    worker_replicas,
    workload_of,
)

comptime IMG = '"image":{"digest":"sha256:0011"}'


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


# ---- 1. the rows ------------------------------------------------------------------


def test_the_compute_rows() raises:
    """Catches: a row at another field or arm position (a decoded worker or
    job would map to another type), the job's row still named `job`, a
    portability other than PORTABLE, an output a worker or a job does not
    have, a verb a worker would accept (CALL on a worker has no meaning: it
    answers no request and is never started), retention on a workload, and
    a primary role other than `run`."""
    var c = Catalog.v1()
    assert_equal(FIELD_SERVICE, 10)
    assert_equal(FIELD_CONTAINER_JOB, 11)
    assert_equal(FIELD_WORKER, 12)
    var arms = body_arms()
    var fields = [FIELD_SERVICE, FIELD_CONTAINER_JOB, FIELD_WORKER]
    var names = ["service", "container_job", "worker"]
    for i in range(3):
        assert_equal(arms[i].field, fields[i], String(names[i]) + " is arm " + String(i + 1))
        assert_equal(arms[i].name, String(names[i]))
        ref t = c.types[c.index_of(fields[i])]
        assert_equal(t.name, String(names[i]))
        assert_equal(t.portability, PORTABLE, String(names[i]))
        assert_false(t.takes_retention(), String(names[i]) + " is deleted with its resource")
        assert_equal(t.primary_role, "run", String(names[i]) + " lands on run")
    ref svc = c.types[c.index_of(FIELD_SERVICE)]
    assert_equal(len(svc.exposes), 2, "a service exposes URL and HOST")
    assert_true(svc.exposes_output("URL") and svc.exposes_output("HOST"))
    ref job = c.types[c.index_of(FIELD_CONTAINER_JOB)]
    ref w = c.types[c.index_of(FIELD_WORKER)]
    assert_equal(len(job.exposes), 0, "a container job exposes nothing")
    assert_equal(len(w.exposes), 0, "a worker exposes nothing")
    for t in [FIELD_SERVICE, FIELD_CONTAINER_JOB]:
        ref ct = c.types[c.index_of(t)]
        assert_equal(len(ct.accepts), 1, ct.name + " accepts CALL only")
        assert_true(ct.accepts_access("CALL"), ct.name + " accepts CALL")
    assert_equal(len(w.accepts), 0, "a worker accepts no verb")
    var l = _list(
        String('{"resource":[{"id":"api","service":{}},{"id":"nightly","containerJob":{}},')
        + String('{"id":"relay","worker":{}}]}')
    )
    for id in ["api", "nightly", "relay"]:
        assert_equal(primary_node(c, l, String(id)), String(id) + "/run")
    print("  test_the_compute_rows: PASS")


# ---- 2. every refusal, in one pass ------------------------------------------------


def test_every_compute_refusal_in_one_pass() raises:
    """Catches: any one rule dropped (its line is missing), a rule that fires
    on the wrong resource or path (a worker's finding reported under
    `service.` or `job.`), a rule that also fires on a good entry or reports
    one defect twice (the total), and a rule that holds for a service but
    was never extended to a worker or a container job."""
    var j = (
        String('{"resource":[')
        + String('{"id":"runner","serviceAccount":{}},')
        + String('{"id":"store","bucket":{}},')
        + String('{"id":"w-noimg","worker":{"replicas":1}},')
        + String('{"id":"w-built","worker":{"image":{"output":{"step":"b","name":"img"}}}},')
        + String('{"id":"w-plat","worker":{"image":{"digest":"sha256:01","platform":"linux"}}},')
        + String('{"id":"w-zero","worker":{') + String(IMG) + String(',"replicas":0}},')
        + String('{"id":"w-cmd","worker":{') + String(IMG) + String(',"command":["","--x"]}},')
        + String('{"id":"j-cmd","containerJob":{') + String(IMG) + String(',"command":[""]}},')
        + String('{"id":"s-cmd","service":{') + String(IMG) + String(',"internal":{},"command":[""]}},')
        + String('{"id":"w-asbkt","worker":{') + String(IMG) + String(',"runAs":{"resource":"store"}}},')
        + String('{"id":"w-asout","worker":{') + String(IMG)
        + String(',"runAs":{"resource":"runner","standard":"NAME"}}},')
        + String('{"id":"w-asgone","worker":{') + String(IMG) + String(',"runAs":{"resource":"nobody"}}},')
        + String('{"id":"w-env","worker":{') + String(IMG)
        + String(',"env":{"P":{"param":"region"},"R":{"ref":{"resource":"ghost","standard":"URL"}}}}},')
        + String('{"id":"w-dup","worker":{') + String(IMG)
        + String(',"env":{"K":{"literal":"v"}},"secretEnv":{"K":{"name":"k"}}}},')
        + String('{"id":"w-keep","retention":"KEEP","worker":{') + String(IMG) + String("}},")
        + String('{"id":"caller","service":{') + String(IMG) + String(',"internal":{}},')
        + String('"uses":[{"target":{"resource":"w-keep"},"access":"CALL"}]},')
        + String('{"id":"w-asacct","worker":{') + String(IMG) + String(',"runAs":{"resource":"runner"}}},')
        + String('{"id":"g","grant":{"principal":{"resource":"w-asacct"},')
        + String('"target":{"resource":"store"},"access":"READ"}}')
        + String("]}")
    )
    var l = _lines(graph_findings(Catalog.v1(), _list(j)))
    _expect(l, "w-noimg|worker.image|", "no image")
    _expect(l, "w-built|worker.image|", "the image is a build output that was not resolved to a digest")
    _expect(l, "w-plat|worker.image.platform|", 'platform "linux" is not <os>/<cpu>')
    _expect(l, "w-zero|worker.replicas|", "a worker runs always, on 1 or more instances: 0 is never legal")
    _expect(l, "w-cmd|worker.command[0]|", "the first entry of a command is the program to run, and it is empty")
    _expect(l, "j-cmd|container_job.command[0]|", "the first entry of a command is the program to run")
    _expect(l, "s-cmd|service.command[0]|", "the first entry of a command is the program to run")
    _expect(l, "w-asbkt|worker.run_as|", 'run_as must name a service_account; "store" is a bucket')
    _expect(l, "w-asout|worker.run_as|", "run_as names an identity, not one of its outputs")
    _expect(l, "w-asgone|worker.run_as|", 'ref to missing resource "nobody"')
    _expect(l, "w-env|worker.env.P|", 'release parameter "region" is unresolved')
    _expect(l, "w-env|worker.env.R|", 'ref to missing resource "ghost"')
    _expect(l, "w-dup|worker.secret_env.K|", "the variable is set by env and by secret_env; set it in one")
    _expect(l, "w-keep|retention|", "a worker takes no retention: it is deleted with its resource")
    _expect(l, "caller|uses[0]|", 'worker "w-keep" does not accept access CALL')
    _expect(
        l, "g|grant.principal|", '"w-asacct" runs as "runner" and has no identity of its own; name "runner"'
    )
    assert_equal(len(l), 16, "no other finding")
    print("  test_every_compute_refusal_in_one_pass: PASS")


# ---- 3. a good compute graph is clean ------------------------------------------------


comptime _GOOD = (
    '{"resource":['
    '{"id":"runner","serviceAccount":{},"uses":[{"target":{"resource":"work"},"access":"RECEIVE"}]},'
    '{"id":"work","queue":{}},'
    '{"id":"relay","worker":{"image":{"digest":"sha256:0011","platform":"linux/amd64"},'
    '"size":{"cpuMillis":500,"memoryMb":1024,"gpus":1},"args":["--drain"],"command":["/bin/relay"],'
    '"env":{"MODE":{"literal":"drain"},"QUEUE":{"ref":{"resource":"work","standard":"ADDRESS"}}},'
    '"secretEnv":{"TOKEN":{"name":"relay-token"}},"replicas":3,"runAs":{"resource":"runner"}}},'
    '{"id":"sweeper","worker":{"image":{"digest":"sha256:0022"},"command":["/bin/sweep",""]},'
    '"uses":[{"target":{"resource":"work"},"access":"SEND"}]},'
    '{"id":"sweeper-sees","grant":{"principal":{"resource":"sweeper"},'
    '"target":{"resource":"runner"},"access":"DESCRIBE"}},'
    '{"id":"nightly","containerJob":{"image":{"digest":"sha256:0033"},"command":["/bin/report"],'
    '"args":["--full"],"maxRetries":0}},'
    '{"id":"api","service":{"image":{"digest":"sha256:0044"},"internal":{},"command":["/opt/serve"],'
    '"size":{"cpuMillis":4000,"memoryMb":16384,"gpus":2}},'
    '"uses":[{"target":{"resource":"nightly"},"access":"CALL"}]}'
    "]}"
)


def test_a_good_compute_graph_is_clean() raises:
    """Catches: a rule that over-fires on a legal workload (a worker with
    every field, a command with an empty LATER entry, a worker with no
    `replicas`, a worker as a grant's principal, CALL on a container job,
    GPUs on a service), any of which a refusal mutant inverted would
    report."""
    var f = _lines(graph_findings(Catalog.v1(), _list(String(_GOOD))))
    var all = String("")
    for i in range(len(f)):
        all += f[i] + String("\n")
    assert_equal(len(f), 0, all)
    print("  test_a_good_compute_graph_is_clean: PASS")


# ---- 4. the helpers ------------------------------------------------------------------


def test_the_helpers() raises:
    """Catches: `workload_of` reading the wrong arm (or calling a bucket a
    workload), the kind word that prefixes every path, the replicas default
    not 1 (or applied to an explicit value), a worker's platform default
    missing, and a worker whose identity or edges are not those of a
    service (no implicit LOGS edge, a `uses` line dropped)."""
    var l = _list(String(_GOOD))
    var kinds = List[String]()
    for i in range(len(l)):
        var w = workload_of(l[i])
        kinds.append(w.value().kind.copy() if w else String("-"))
    var got = String("")
    for i in range(len(kinds)):
        got += kinds[i] + String(",")
    assert_equal(got, "-,-,worker,worker,-,container_job,service,", "workload_of per resource")
    assert_true(is_workload(FIELD_SERVICE) and is_workload(FIELD_CONTAINER_JOB) and is_workload(FIELD_WORKER))
    assert_false(is_workload(FIELD_BUCKET), "a bucket is not a workload")
    assert_equal(worker_replicas(l[2]), 3, "written")
    assert_equal(worker_replicas(l[3]), WORKER_REPLICAS_DEFAULT, "unset: the versioned default")
    assert_equal(WORKER_REPLICAS_DEFAULT, 1)
    assert_equal(worker_replicas(l[6]), 0, "a service has no replicas")
    assert_equal(image_platform(l[2]), "linux/amd64", "written")
    assert_equal(image_platform(l[3]), "linux/amd64", "unset: the v1 default")
    assert_equal(image_platform(l[1]), "", "a queue has no image")
    assert_equal(workload_of(l[2]).value().gpus(), 1)
    assert_equal(workload_of(l[5]).value().gpus(), 0, "no size: no GPU")
    # Identity: relay runs as runner; sweeper holds its own.
    assert_false(holds_own_identity(l[2]))
    assert_equal(run_as_of(l[2]), "runner")
    assert_true(holds_own_identity(l[3]))
    assert_equal(run_as_of(l[3]), "")
    var e = edges_of(l[3])
    assert_equal(len(e), 2, "sweeper: its uses line, then the implicit LOGS edge")
    assert_equal(e[0].principal, "sweeper")
    assert_equal(e[0].target, "work")
    assert_equal(e[0].access, "SEND")
    assert_true(e[1].implicit and e[1].cell == "LOGS" and e[1].access == "WRITE")
    assert_equal(len(edges_of(l[2])), 0, "relay runs as an account: no edge of its own")
    print("  test_the_helpers: PASS")


def main() raises:
    print("test_cloud_compute_rules")
    test_the_compute_rows()
    test_every_compute_refusal_in_one_pass()
    test_a_good_compute_graph_is_clean()
    test_the_helpers()
    print("ALL kci_cloud COMPUTE RULE TESTS PASSED")
