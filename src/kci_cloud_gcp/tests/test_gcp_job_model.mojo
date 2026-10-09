# =============================================================================
# kci_cloud_gcp/tests/test_gcp_job_model.mojo
# =============================================================================
#
# Where each field of a container job's run node lands in the Cloud Run job
# kci writes (job_model.mojo), read back by JSON path, not by the model's own
# reader: the image, the command and the arguments in their places and
# order, the environment (a literal and a bound reference, in key order),
# the cpu and memory limits, maxRetries, the timeout, the service account
# and the labels. A field written into the wrong place of the job fails
# here. Then the reader: the model of the job kci wrote is the model it was
# written from (so an apply settles), a failed job reads `ready=false`, and
# the timeout and size conversions both ways.
# =============================================================================

from std.testing import assert_equal, assert_true

from kci_cloud import LoweredNode, Setting
from kci_reconciler import InputRef, Label, RETAIN_DELETE
from komira_json import JsonValue, parse_json_value

from kci_cloud_gcp import (
    KIND_JOB,
    ModelField,
    desired_model,
    job_json,
    live_model,
    lowered_size,
    lowered_timeout,
    model_value,
    size_limits,
    timeout_duration,
    with_kci_labels,
)


comptime _SA = "sa-of-nightly"
comptime _PEER = "the-peer-account"


def _node() -> LoweredNode:
    var d = List[Setting]()
    d.append(Setting(String("img"), String("sha256:aaa@linux/amd64")))
    d.append(Setting(String("cmd"), String("run")))
    d.append(Setting(String("cmd"), String("--all")))
    d.append(Setting(String("arg"), String("x")))
    d.append(Setting(String("container_job.env.MODE"), String("fast")))
    d.append(Setting(String("size"), String("1000m/512MB")))
    d.append(Setting(String("retries"), String("3")))
    d.append(Setting(String("timeout"), String("600s0n")))
    d.append(Setting(String("serves"), String("false")))
    d.append(Setting(String("label.team"), String("data")))
    var refs = List[InputRef]()
    refs.append(InputRef(String("peer/identity"), String("NAME"), String("container_job.env.PEER")))
    var deps = List[String]()
    deps.append(String("nightly/identity"))
    return LoweredNode(String("nightly/run"), String("nightly"), String(KIND_JOB), deps^, refs^, d^)


def _bound() -> List[String]:
    var b = List[String]()
    b.append(String(_PEER))
    return b^


def _labels() -> List[Label]:
    var l = List[Label]()
    l.append(Label(String("kci_managed_by"), String("kci")))
    l.append(Label(String("kci-retention"), String("delete")))
    l.append(Label(String("team"), String("data")))
    l.append(Label(String("owner-team"), String("data")))
    return l^


def _strings(v: JsonValue) raises -> String:
    var out = String("")
    for i in range(v.array_len()):
        if i > 0:
            out += String(",")
        out += v.element_at(i).as_string()
    return out^


def test_each_field_lands_in_its_place() raises:
    var model = desired_model(_node(), _bound(), String(_SA), RETAIN_DELETE)
    var job = parse_json_value(job_json(model, _labels(), String("projects/p/locations/r/jobs/j")))
    assert_equal(job.get("name").as_string(), "projects/p/locations/r/jobs/j")
    var task = job.get("template").get("template")
    var c = task.get("containers").element_at(0)
    assert_equal(c.get("image").as_string(), "sha256:aaa")
    assert_equal(_strings(c.get("command")), "run,--all")
    assert_equal(_strings(c.get("args")), "x")
    var env = c.get("env")
    assert_equal(env.array_len(), 2)
    assert_equal(env.element_at(0).get("name").as_string(), "MODE")
    assert_equal(env.element_at(0).get("value").as_string(), "fast")
    assert_equal(env.element_at(1).get("name").as_string(), "PEER")
    assert_equal(env.element_at(1).get("value").as_string(), _PEER)
    var limits = c.get("resources").get("limits")
    assert_equal(limits.get("cpu").as_string(), "1000m")
    assert_equal(limits.get("memory").as_string(), "512Mi")
    assert_equal(task.get("maxRetries").text, "3")
    assert_equal(task.get("timeout").as_string(), "600s")
    assert_equal(task.get("serviceAccount").as_string(), _SA)
    var labels = job.get("labels")
    assert_equal(labels.get("kci-retention").as_string(), "delete")
    assert_equal(labels.get("team").as_string(), "data")
    assert_equal(labels.get("owner-team").as_string(), "data")
    # The execution template carries kci's labels and the author's, not one
    # the job holds that kci was not handed.
    var tl = job.get("template").get("labels")
    assert_equal(tl.get("kci_managed_by").as_string(), "kci")
    assert_equal(tl.get("kci-retention").as_string(), "delete")
    assert_equal(tl.get("team").as_string(), "data")
    assert_true(not tl.has("owner-team"))
    assert_true(not job.has("terminalCondition"), "kci never writes the service's fields")


def test_the_model_of_the_written_job_is_the_model() raises:
    var model = desired_model(_node(), _bound(), String(_SA), RETAIN_DELETE)
    var live = live_model(parse_json_value(job_json(model, _labels())), model)
    assert_equal(len(live), len(model))
    for i in range(len(model)):
        assert_equal(live[i].key, model[i].key)
        assert_equal(live[i].value, model[i].value, model[i].key)
    assert_equal(model_value(model, String("img")), "sha256:aaa@linux/amd64")
    assert_equal(model_value(model, String("env.PEER")), _PEER)
    assert_equal(model_value(model, String("label.team")), "data")
    assert_equal(model_value(model, String("retention")), "delete")
    assert_equal(model_value(model, String("ready")), "true")


def test_a_failed_job_reads_not_ready() raises:
    var model = desired_model(_node(), _bound(), String(_SA), RETAIN_DELETE)
    var text = job_json(model, _labels())
    var failed = String(text[byte = 0 : text.byte_length() - 1]) + String(
        ',"terminalCondition":{"type":"Ready","state":"CONDITION_FAILED"}}'
    )
    assert_equal(model_value(live_model(parse_json_value(failed), model), String("ready")), "false")


def test_kci_labels_are_set_and_dropped_in_both_places() raises:
    var text = String('{"labels":{"kci_role":"run","a":"1"},"template":{"labels":{"kci_role":"run","b":"2"},"parallelism":3}}')
    var none = parse_json_value(with_kci_labels(text, List[Label]()))
    assert_equal(none.get("labels").serialize(), '{"a":"1"}')
    assert_equal(none.get("template").get("labels").serialize(), '{"b":"2"}')
    assert_equal(none.get("template").get("parallelism").text, "3")
    var mark = List[Label]()
    mark.append(Label(String("kci_adopted"), String("true")))
    var with_mark = parse_json_value(with_kci_labels(text, mark))
    assert_equal(with_mark.get("labels").serialize(), '{"a":"1","kci_adopted":"true"}')
    assert_equal(with_mark.get("template").get("labels").serialize(), '{"b":"2","kci_adopted":"true"}')


def test_conversions() raises:
    assert_equal(timeout_duration(String("600s0n")), "600s")
    assert_equal(timeout_duration(String("1s5n")), "1.000000005s")
    assert_equal(lowered_timeout(String("600s")), "600s0n")
    assert_equal(lowered_timeout(String("1.000000005s")), "1s5n")
    assert_equal(lowered_timeout(String("1.5s")), "1s500000000n")
    var lim = size_limits(String("2000m/1024MB"))
    assert_equal(lim[0], "2000m")
    assert_equal(lim[1], "1024Mi")
    assert_equal(lowered_size(String("2000m"), String("1024Mi")), "2000m/1024MB")


def main() raises:
    print("test_each_field_lands_in_its_place")
    test_each_field_lands_in_its_place()
    print("test_the_model_of_the_written_job_is_the_model")
    test_the_model_of_the_written_job_is_the_model()
    print("test_a_failed_job_reads_not_ready")
    test_a_failed_job_reads_not_ready()
    print("test_kci_labels_are_set_and_dropped_in_both_places")
    test_kci_labels_are_set_and_dropped_in_both_places()
    print("test_conversions")
    test_conversions()
    print("OK")
