# Reading native/drive.c's JSON report: what the tests assert and the bench
# summarizes.

from komira_json import JsonValue


def num(v: JsonValue, key: String) raises -> Int:
    return Int(v.get(key).as_int64())


def text(v: JsonValue, key: String) raises -> String:
    return v.get(key).as_string()


def per_thread(r: JsonValue) raises -> List[JsonValue]:
    var t = r.get("per_thread")
    var out = List[JsonValue]()
    for i in range(t.array_len()):
        out.append(t.element_at(i))
    return out^


def processes(r: JsonValue, role: String) raises -> List[JsonValue]:
    """The processes below the engine whose worker role is `role`."""
    var p = r.get("processes")
    var out = List[JsonValue]()
    for i in range(p.array_len()):
        var e = p.element_at(i)
        if text(e, "role") == role:
            out.append(e^)
    return out^


def logs(r: JsonValue) raises -> List[String]:
    var l = r.get("logs")
    var out = List[String]()
    for i in range(l.array_len()):
        out.append(l.element_at(i).as_string())
    return out^


def count_logs(r: JsonValue, part: String) raises -> Int:
    var n = 0
    for line in logs(r):
        if part in line:
            n += 1
    return n


def check_ok(r: JsonValue, what: String) raises:
    """Raises unless the run and every thread succeeded and every argument
    array the engine exported was released."""
    if num(r, "status") != 0:
        raise Error(what + ": status " + String(num(r, "status")) + ": " + text(r, "message"))
    var ts = per_thread(r)
    for i in range(len(ts)):
        ref t = ts[i]
        if num(t, "status") != 0:
            raise Error(what + ": thread " + String(i) + ": " + text(t, "message"))
        if num(t, "exported") != num(t, "released"):
            raise Error(
                what + ": thread " + String(i) + " exported " + String(num(t, "exported")) + " arrays, released "
                + String(num(t, "released"))
            )
        if num(t, "bad_values") != 0:
            raise Error(what + ": thread " + String(i) + ": " + String(num(t, "bad_values")) + " wrong values")


def _field_after(line: String, key: String) raises -> Int:
    """The decimal integer after `key` in `line`."""
    var at = line.find(key)
    if at < 0:
        raise Error("no " + key + " in: " + line)
    var b = line.as_bytes()
    var i = at + key.byte_length()
    var n = 0
    while i < len(b) and b[i] >= 0x30 and b[i] <= 0x39:
        n = n * 10 + Int(b[i] - 0x30)
        i += 1
    return n


@fieldwise_init
struct CallSplit(Copyable, Movable):
    """CALL_BATCH time summed over a run's context workers (the proxy logs
    each at close_context): calls, time in the proxy's call, its wait from
    request sent to reply read, and the worker's own time."""

    var calls: Int
    var call_ns: Int
    var wait_ns: Int
    var worker_ns: Int


def call_split(r: JsonValue) raises -> CallSplit:
    var out = CallSplit(0, 0, 0, 0)
    for line in logs(r):
        if ": calls " in line and "worker ns " in line:
            out.calls += _field_after(line, "calls ")
            out.call_ns += _field_after(line, "call ns ")
            out.wait_ns += _field_after(line, "wait ns ")
            out.worker_ns += _field_after(line, "worker ns ")
    return out^
