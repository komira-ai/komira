# =============================================================================
# ScanParams — the kind-agnostic configuration map on a `ScanBinding`.
# =============================================================================
#
# THE FIELD THAT DECIDES WHETHER A NEW SOURCE KIND MUST EDIT the core packages.
# Three shapes were considered; two lost:
#
#   * a TYPED VARIANT (`ParamsVariant` with a per-kind arm) — this is the
#     closed union again, one level down. A new kind edits core. Rejected.
#   * an OPAQUE BLOB (`List[UInt8]`) — serializable and kind-agnostic, but
#     EXPLAIN cannot render a kind it has never heard of, `fingerprint`
#     becomes hostage to the owning package's codec being byte-deterministic,
#     and generic optimizer rules that READ params (`partition_prune_scans`
#     reads partition values) would need a codec core cannot name. Rejected.
#   * a SORTED KEY -> TYPED-SCALAR MAP — chosen, and implemented here.
#
# WHY TWO PARALLEL `List`s AND NOT A `Dict`. These maps are 1-8 entries. A
# `Dict`'s bucket array costs more to clone than a linear scan costs to search,
# and a `Dict`'s iteration order is not a hashable order. Two sorted parallel
# Lists hash deterministically with no ordering machinery.
#
# ⚠ KEYS ARE SORTED, AND THAT IS LOAD-BEARING. Two constructions of the same
# source that insert keys in a different order MUST fingerprint EQUAL, or the
# plan cache silently misses forever. `put` maintains sorted order by
# insertion; `hash_into` therefore walks a canonical sequence.
#
# COST, STATED PLAINLY: keys are stringly-typed, so a typo is a runtime miss
# rather than a compile error. The mitigation is `ScanKindDescriptor.
# required_params`, validated at bind time — which moves the failure to
# plan-build, naming the missing key.
#
# POINTER DISCIPLINE: `String`, `List`, `Int64`, `Float64`, `UInt8` only. No
# pointer of any kind. This is a value, and it is serializable.
# =============================================================================

from std.memory import bitcast


# -----------------------------------------------------------------------------
# Param value tags.
# -----------------------------------------------------------------------------
comptime PARAM_STR: UInt8 = 0
comptime PARAM_I64: UInt8 = 1
comptime PARAM_U64: UInt8 = 2
comptime PARAM_F64: UInt8 = 3
comptime PARAM_BOOL: UInt8 = 4
comptime PARAM_BYTES: UInt8 = 5
"""Opaque bytes carried as a String. The OWNING PACKAGE owns the codec; core
never interprets it, only hashes and renders it as an opaque length."""


comptime _PARAM_FNV_OFFSET: UInt64 = 14695981039346656037
comptime _PARAM_FNV_PRIME: UInt64 = 1099511628211


@always_inline
def param_hash_string(s: String, seed: UInt64) -> UInt64:
    """FNV-1a fold of a String's bytes into `seed`.

    Shared by `ScanParams` and `ScanBinding` so every identity fold in the
    scan-binding substrate uses ONE hash. Deliberately the same construction
    the concrete sources already use privately (`_arrow_source_hash_string`,
    `_parquet_source_hash_string`) so a migrated arm can reproduce its old
    fingerprint value BYTE-IDENTICALLY.
    """
    var h = seed
    var b = s.as_bytes()
    for i in range(len(b)):
        h = h ^ UInt64(b[i])
        h = h * _PARAM_FNV_PRIME
    return h


@always_inline
def param_hash_combine(a: UInt64, b: UInt64) -> UInt64:
    """FNV-1a hash_combine: order-sensitive 64-bit combine."""
    return (a ^ b) * _PARAM_FNV_PRIME


@fieldwise_init
struct ParamValue(Copyable, Movable, Deinitable):
    """One typed scalar in a `ScanParams` map.

    Flat rather than a nested variant: a `ScanParams` clone is on the plan-clone
    path (dominated by `Schema.copy()`, so params must not become the new
    dominant term), and a flat struct clones with one String copy and two
    scalar copies regardless of tag.
    """

    var tag: UInt8
    var s: String
    """PARAM_STR / PARAM_BYTES payload. Empty for the numeric tags."""
    var i: Int64
    """PARAM_I64 payload; PARAM_U64 bit-cast; PARAM_BOOL as 0/1."""
    var f: Float64
    """PARAM_F64 payload."""

    @staticmethod
    def of_str(var v: String) -> Self:
        return Self(tag=PARAM_STR, s=v^, i=Int64(0), f=Float64(0))

    @staticmethod
    def of_bytes(var v: String) -> Self:
        return Self(tag=PARAM_BYTES, s=v^, i=Int64(0), f=Float64(0))

    @staticmethod
    def of_i64(v: Int64) -> Self:
        return Self(tag=PARAM_I64, s=String(""), i=v, f=Float64(0))

    @staticmethod
    def of_u64(v: UInt64) -> Self:
        # Bit-cast, not a saturating convert: a u64 above Int64.MAX must
        # round-trip through `as_u64()` unchanged, or a broker offset or a
        # search generation silently truncates in the identity fold.
        return Self(
            tag=PARAM_U64, s=String(""), i=bitcast[DType.int64, width=1](v), f=Float64(0)
        )

    @staticmethod
    def of_f64(v: Float64) -> Self:
        return Self(tag=PARAM_F64, s=String(""), i=Int64(0), f=v)

    @staticmethod
    def of_bool(v: Bool) -> Self:
        return Self(
            tag=PARAM_BOOL, s=String(""), i=Int64(1) if v else Int64(0), f=Float64(0)
        )

    def copy(self) -> Self:
        return Self(tag=self.tag, s=String(self.s), i=self.i, f=self.f)

    def as_str(self) -> String:
        return String(self.s)

    def as_i64(self) -> Int64:
        return self.i

    def as_u64(self) -> UInt64:
        return bitcast[DType.uint64, width=1](self.i)

    def as_f64(self) -> Float64:
        return self.f

    def as_bool(self) -> Bool:
        return self.i != Int64(0)

    def hash_into(self, seed: UInt64) -> UInt64:
        """Fold this value into `seed`. Tag participates, so `of_i64(1)` and
        `of_bool(True)` do not alias."""
        var h = param_hash_combine(seed, UInt64(self.tag))
        if self.tag == PARAM_STR or self.tag == PARAM_BYTES:
            return param_hash_string(self.s, h)
        elif self.tag == PARAM_F64:
            return param_hash_combine(h, self.f.to_bits[DType.uint64]())
        return param_hash_combine(h, bitcast[DType.uint64, width=1](self.i))

    def render(self) -> String:
        """EXPLAIN rendering. Works for a kind core has never heard of."""
        if self.tag == PARAM_STR:
            return String(self.s)
        elif self.tag == PARAM_BYTES:
            return String("<") + String(self.s.byte_length()) + String(" bytes>")
        elif self.tag == PARAM_F64:
            return String(self.f)
        elif self.tag == PARAM_BOOL:
            return String("true") if self.i != Int64(0) else String("false")
        elif self.tag == PARAM_U64:
            return String(self.as_u64())
        return String(self.i)


struct ScanParams(Copyable, Movable, Deinitable):
    """Sorted flat key -> typed-scalar map. See the module header.

    Invariant: `_keys` is strictly ascending and `len(_keys) == len(_vals)`.
    `put` maintains it; nothing else mutates the lists.
    """

    var _keys: List[String]
    var _vals: List[ParamValue]

    def __init__(out self):
        self._keys = List[String]()
        self._vals = List[ParamValue]()

    def copy(self) -> Self:
        var out = Self()
        out._keys = self._keys.copy()
        out._vals = self._vals.copy()
        return out^

    def __len__(self) -> Int:
        return len(self._keys)

    def num_params(self) -> Int:
        """Non-dunder length. `__len__` on a `def` is raising, so it does not
        bind `Sized` and `len(params)` will not compile at a call site."""
        return len(self._keys)

    def _lower_bound(self, key: String) -> Int:
        """Index of the first key >= `key`. Linear: these maps are 1-8 entries
        and a binary search's branch misprediction costs more than the scan."""
        var n = len(self._keys)
        for i in range(n):
            if self._keys[i] >= key:
                return i
        return n

    def put(mut self, var key: String, var value: ParamValue):
        """Insert or overwrite, keeping `_keys` sorted.

        Overwrite (rather than append-duplicate) is what makes the fold
        canonical: a caller that sets `codec` twice must not produce a
        different fingerprint from one that sets it once.
        """
        var at = self._lower_bound(key)
        if at < len(self._keys) and self._keys[at] == key:
            self._vals[at] = value^
            return
        self._keys.insert(at, key^)
        self._vals.insert(at, value^)

    def put_str(mut self, var key: String, var value: String):
        self.put(key^, ParamValue.of_str(value^))

    def put_i64(mut self, var key: String, value: Int64):
        self.put(key^, ParamValue.of_i64(value))

    def put_u64(mut self, var key: String, value: UInt64):
        self.put(key^, ParamValue.of_u64(value))

    def put_bool(mut self, var key: String, value: Bool):
        self.put(key^, ParamValue.of_bool(value))

    def put_f64(mut self, var key: String, value: Float64):
        self.put(key^, ParamValue.of_f64(value))

    def has(self, key: String) -> Bool:
        var at = self._lower_bound(key)
        return at < len(self._keys) and self._keys[at] == key

    def get(self, key: String) -> Optional[ParamValue]:
        var at = self._lower_bound(key)
        if at < len(self._keys) and self._keys[at] == key:
            return Optional(self._vals[at].copy())
        return None

    def get_str(self, key: String, default: String = String("")) -> String:
        var v = self.get(key)
        if v:
            return v.value().as_str()
        return String(default)

    def get_i64(self, key: String, default: Int64 = Int64(0)) -> Int64:
        var v = self.get(key)
        if v:
            return v.value().as_i64()
        return default

    def get_u64(self, key: String, default: UInt64 = UInt64(0)) -> UInt64:
        var v = self.get(key)
        if v:
            return v.value().as_u64()
        return default

    def get_bool(self, key: String, default: Bool = False) -> Bool:
        var v = self.get(key)
        if v:
            return v.value().as_bool()
        return default

    def key_at(self, index: Int) -> String:
        return String(self._keys[index])

    def value_at(self, index: Int) -> ParamValue:
        return self._vals[index].copy()

    def hash_into(self, seed: UInt64) -> UInt64:
        """Fold the whole map into `seed`, in sorted-key order.

        Insertion order CANNOT affect the result — that is the entire reason
        the keys are sorted.
        """
        var h = param_hash_combine(seed, UInt64(len(self._keys)))
        for i in range(len(self._keys)):
            h = param_hash_string(self._keys[i], h)
            h = self._vals[i].hash_into(h)
        return h

    def render(self) -> String:
        """`k=v, k2=v2` in sorted-key order. EXPLAIN uses this for any kind,
        including one core has never heard of — which is why a param map beat
        an opaque blob."""
        var out = String("")
        for i in range(len(self._keys)):
            if i > 0:
                out += String(", ")
            out += self._keys[i]
            out += String("=")
            out += self._vals[i].render()
        return out^
