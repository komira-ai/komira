# =============================================================================
# komira_placement/k8s_quantity.mojo — the ONE parser for the Kubernetes
#   resource quantities a job's CPU / memory (and therefore
#   `ContainerSpec.cpu` / `.memory`) are written in.
# =============================================================================
#
# ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────
# A job's default CPU and memory are written as `"256m"` and `"512Mi"` —
# KUBERNETES millicore / mebibyte syntax — and those strings are carried,
# unchanged, onto `ContainerSpec.cpu` / `.memory` by every placement path.
#
# A job's CPU is therefore a CROSS-CLOUD field in ONE unit system, and each
# cloud conformer owes a translation into its own:
#
#   * Cloud Run speaks Kubernetes quantities NATIVELY (`ResourceRequirements
#     .limits` is a map of quantity STRINGS), so the GCP arm needs no unit
#     conversion — but it does need to know `256m < 1 vCPU`, because gen2
#     REJECTS a sub-1-vCPU finite job. That predicate reads its number from
#     here.
#   * ECS/Fargate does NOT. `RegisterTaskDefinition`'s `cpu` is a plain
#     integer string in FARGATE CPU UNITS (1024 units == 1 vCPU) drawn from a
#     CLOSED set, paired with a `memory` in whole MiB drawn from a per-cpu
#     range. `"256m"` is not a small number there, it is a DIFFERENT UNIT
#     SYSTEM, and AWS answers `InvalidParameterException: Invalid 'cpu'
#     setting for task`. The mapping is `komira_aws_bridge`'s Fargate task
#     size table.
#
# ⛔ ONLY THE PARSE IS SHARED, DELIBERATELY. A function that emitted both
#   clouds' wire formats would have to know both, and the two problems are not
#   the same one: Fargate's is a CLOSED SET with (cpu, memory) PAIRING rules;
#   Cloud Run's is a MINIMUM. Sharing the emit would make one cloud's
#   constraint table a dependency of the other's render.
#
# ⛔ AND THE PARSE RAISES. A hand-rolled millicore reader whose contract is
#   "unparseable -> do not rewrite" is the right contract for a FLOOR and the
#   wrong one for a TRANSLATION — an AWS conformer that treats an unparseable
#   quantity as "leave it alone" ships the unparseable string to AWS. So this
#   file RAISES, and the GCP predicate catches; the two policies are stated at
#   their own call sites instead of being baked into the reader.
#
# ── WHY IT LIVES IN `komira_placement` ──────────────────────────────────────
# It is the package that DEFINES the currency: `PlacementSpec`/`ContainerSpec`
# are here, and every cloud bridge already depends on this package for the
# `PodManager` trait. Putting the parser in either bridge would force the other
# bridge to depend on it — a cloud-to-cloud edge that must not be created for a
# string reader.
#
# ENCAPSULATION: pure value functions. No pointer, no origin, no I/O, no DB.
# =============================================================================


# The byte values this file compares against. Spelled once; a `chr` comparison
# written inline five times is five places for an off-by-one.
comptime _B_0: UInt8 = UInt8(ord("0"))
comptime _B_9: UInt8 = UInt8(ord("9"))
comptime _B_DOT: UInt8 = UInt8(ord("."))
comptime _B_M_LOWER: UInt8 = UInt8(ord("m"))

# 1 vCPU expressed in Kubernetes millicores. The unit this file's CPU half
# returns, chosen because it is the FINEST precision Kubernetes itself admits
# (it rejects anything below 1m), so an Int in these units is lossless for
# every legal input and needs no float anywhere in the chain.
comptime K8S_MILLICORES_PER_CPU: Int = 1000

comptime _BYTES_PER_KI: Int = 1024
comptime _BYTES_PER_MI: Int = 1024 * 1024
comptime _BYTES_PER_GI: Int = 1024 * 1024 * 1024
comptime _BYTES_PER_TI: Int = 1024 * 1024 * 1024 * 1024
comptime _BYTES_PER_K: Int = 1000
comptime _BYTES_PER_M: Int = 1000 * 1000
comptime _BYTES_PER_G: Int = 1000 * 1000 * 1000
comptime _BYTES_PER_T: Int = 1000 * 1000 * 1000 * 1000


# =============================================================================
# §1 — the shared mantissa reader.
# =============================================================================
def _read_mantissa_milli(text: String, what: String, whole: String) raises -> Int:
    """Read `text` — a decimal with AT MOST three fractional digits — and return
    it multiplied by 1000, as an Int.

    THE x1000 IS NOT A CPU DETAIL, IT IS HOW THE FRACTION SURVIVES. Both halves
    of this file need `0.5` to be an exact value; carrying it as a Float would
    put a rounding decision inside the parser, where neither caller can see it.
    A CPU caller reads the result directly (millicores); a MEMORY caller
    multiplies by the suffix's byte count and divides by 1000, rounding UP —
    which is the correct direction for a REQUEST and is stated at that call
    site, not here.

    ⛔ MORE THAN THREE FRACTIONAL DIGITS IS A REFUSAL, NOT A ROUNDING.
    Kubernetes itself refuses a CPU quantity finer than `1m`, and a parser that
    silently rounded `0.0001` to `0` would turn a typo into a request for no
    CPU at all — which schedules, and starves.

    `what` names the field (`cpu` / `memory`) and `whole` the ORIGINAL string,
    so a refusal can be read without the caller re-quoting either."""
    var n = text.byte_length()
    if n == 0:
        raise Error(
            String("k8s quantity: REFUSED ")
            + what
            + String(" '")
            + whole
            + String(
                "' — it carries a unit suffix but NO number before it. There is"
                " no defensible default for an absent number: 0 would schedule"
                " a container that cannot run, and any other value would be one"
                " this process invented."
            )
        )
    var b = text.as_bytes()
    var int_part = 0
    var frac_milli = 0
    var frac_digits = 0
    var seen_dot = False
    var seen_digit = False
    for i in range(n):
        var c = b[i]
        if c == _B_DOT:
            if seen_dot:
                raise Error(
                    String("k8s quantity: REFUSED ")
                    + what
                    + String(" '")
                    + whole
                    + String("' — two decimal points.")
                )
            seen_dot = True
            continue
        if c < _B_0 or c > _B_9:
            raise Error(
                String("k8s quantity: REFUSED ")
                + what
                + String(" '")
                + whole
                + String(
                    "' — it is not a number. The accepted CPU forms are"
                    " '<n>m' (millicores, e.g. '256m'), a whole number of"
                    " cores ('1', '2') or a decimal ('0.5'); the accepted"
                    " MEMORY forms are a plain byte count or a number with one"
                    " of Ki/Mi/Gi/Ti (binary) or k/M/G/T (decimal), e.g."
                    " '512Mi'."
                )
            )
        var digit = Int(c - _B_0)
        seen_digit = True
        if seen_dot:
            if frac_digits >= 3:
                raise Error(
                    String("k8s quantity: REFUSED ")
                    + what
                    + String(" '")
                    + whole
                    + String(
                        "' — more than three fractional digits. Kubernetes'"
                        " finest CPU precision is 1m (0.001), so a fourth digit"
                        " cannot be honoured, and rounding it away here would"
                        " turn a typo into a request this process invented."
                    )
                )
            frac_digits += 1
            if frac_digits == 1:
                frac_milli += digit * 100
            elif frac_digits == 2:
                frac_milli += digit * 10
            else:
                frac_milli += digit
        else:
            int_part = int_part * 10 + digit
    if not seen_digit:
        raise Error(
            String("k8s quantity: REFUSED ")
            + what
            + String(" '")
            + whole
            + String("' — no digits at all.")
        )
    return int_part * 1000 + frac_milli


# =============================================================================
# §2 — CPU.
# =============================================================================
def parse_k8s_cpu_millicores(spec: String) raises -> Int:
    """The Kubernetes CPU quantity `spec` in MILLICORES (1000 == 1 vCPU).

        "256m" -> 256      "1"  -> 1000      "0.5" -> 500      "2" -> 2000

    ⛔ EMPTY IS A REFUSAL, NOT A ZERO. An empty `ContainerSpec.cpu` means "this
    placement stated no request", which is a decision for the CONFORMER (Cloud
    Run applies its own default; the Fargate conformer falls back to the
    environment's configured task size). Answering 0 here would collapse
    "unstated" onto "asked for none", and those get different treatment in both
    clouds. Callers test for empty BEFORE calling.

    ⛔ AND EVERY OTHER UNPARSEABLE INPUT IS A REFUSAL TOO, INCLUDING THE FORMS
    KUBERNETES ITSELF WOULD TAKE. `1e3` and `1k` are legal Kubernetes
    quantities and are refused here by name rather than mis-read, because this
    value is about to become a number of CPUs on a bill."""
    var n = spec.byte_length()
    if n == 0:
        raise Error(
            String(
                "k8s quantity: REFUSED an EMPTY cpu. 'unstated' and 'asked for"
                " none' are different requests — a conformer decides which"
                " default applies, so this reader will not collapse them."
            )
        )
    var b = spec.as_bytes()
    if b[n - 1] == _B_M_LOWER:
        # `<n>m` — already millicores. A FRACTIONAL millicore is refused: it is
        # below the precision Kubernetes admits, so honouring it is impossible
        # and dropping it is silent.
        var milli_x1000 = _read_mantissa_milli(
            String(spec[byte=0 : n - 1]), String("cpu"), spec
        )
        if milli_x1000 % 1000 != 0:
            raise Error(
                String("k8s quantity: REFUSED cpu '")
                + spec
                + String(
                    "' — a fractional millicore. 1m is the finest CPU precision"
                    " Kubernetes admits."
                )
            )
        return milli_x1000 // 1000
    # A whole number of cores, or a decimal fraction of one. `_read_mantissa_milli`
    # already returns cores x1000, which IS millicores.
    return _read_mantissa_milli(spec, String("cpu"), spec)


# =============================================================================
# §3 — MEMORY.
# =============================================================================
def _memory_suffix_bytes(spec: String, suffix_len: Int) raises -> Int:
    """The byte multiplier for the LAST `suffix_len` bytes of `spec`."""
    var n = spec.byte_length()
    var s = String(spec[byte = n - suffix_len : n])
    if s == String("Ki"):
        return _BYTES_PER_KI
    if s == String("Mi"):
        return _BYTES_PER_MI
    if s == String("Gi"):
        return _BYTES_PER_GI
    if s == String("Ti"):
        return _BYTES_PER_TI
    if s == String("k") or s == String("K"):
        return _BYTES_PER_K
    if s == String("M"):
        return _BYTES_PER_M
    if s == String("G"):
        return _BYTES_PER_G
    if s == String("T"):
        return _BYTES_PER_T
    return -1


def parse_k8s_memory_bytes(spec: String) raises -> Int:
    """The Kubernetes memory quantity `spec` in BYTES.

        "512Mi" -> 536870912      "1Gi" -> 1073741824      "512" -> 512

    ⚠ A BARE NUMBER IS BYTES, NOT MEBIBYTES — that is Kubernetes' rule and it
    is the single most expensive thing to get wrong here in the quiet
    direction: reading `"512"` as 512 MiB would hand a container 1,048,576x
    what was asked for and nothing would fail. It is spelled out because the
    CPU half of this file reads a bare number as CORES (a 1000x scale), so the
    two halves genuinely disagree about what a bare number means, and they
    disagree because the two Kubernetes conventions do.

    ⛔ EMPTY IS A REFUSAL for the same reason `parse_k8s_cpu_millicores`'s is."""
    var n = spec.byte_length()
    if n == 0:
        raise Error(
            String(
                "k8s quantity: REFUSED an EMPTY memory. 'unstated' and 'asked"
                " for none' are different requests — a conformer decides which"
                " default applies, so this reader will not collapse them."
            )
        )
    var mult = 1
    var mantissa_len = n
    if n >= 3:
        var two = _memory_suffix_bytes(spec, 2)
        if two > 0:
            mult = two
            mantissa_len = n - 2
    if mult == 1 and n >= 2:
        var one = _memory_suffix_bytes(spec, 1)
        if one > 0:
            mult = one
            mantissa_len = n - 1
    var milli = _read_mantissa_milli(
        String(spec[byte=0:mantissa_len]), String("memory"), spec
    )
    # ROUND UP. A memory quantity is a REQUEST — a floor — so a value that does
    # not land on a whole byte must resolve UPWARD or the container is handed
    # less than it asked for. `1.5Ki` -> 1536 exactly; `0.0005Ki` -> 1.
    return (milli * mult + 999) // 1000


def k8s_memory_mib_ceil(spec: String) raises -> Int:
    """`spec` in whole MEBIBYTES, rounded UP.

    The unit every cloud's task-size table is written in, and the rounding
    direction is the same argument as above: a request is a floor, so a
    fractional MiB becomes the next whole one. `"512Mi"` -> 512; `"600"` (600
    BYTES) -> 1, never 0 — a container asked for memory and 0 is not a smaller
    amount of memory, it is a different request."""
    var bytes = parse_k8s_memory_bytes(spec)
    if bytes <= 0:
        return 0
    return (bytes + _BYTES_PER_MI - 1) // _BYTES_PER_MI
