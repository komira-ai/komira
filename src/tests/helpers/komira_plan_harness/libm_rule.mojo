"""The rule an oracle comparison applies to an answer a transcendental function
computes.

The expected answers come from the pinned DuckDB, which is built for and run on
linux-x86_64 only (`sql_oracle`, tools/build/sql/defs.bzl). For a transcendental
function DuckDB calls the C library's libm, and the engine calls the platform's
libm too (src/column_kernels/scalar_math.mojo), so on Linux both sides answer
glibc's bits and the comparison is bit-exact.

On another platform the engine's libm is not glibc. libm is not correctly
rounded: glibc's `cbrt`, for one, is up to about 3 ulp from the exact root on
inputs that macOS's libm rounds correctly, so the two answer different doubles
for the same input. DuckDB built for that platform would answer that platform's
bits too, so the difference is in the oracle's platform, not in the engine.
There, and only for a query that calls one of `TRANSCENDENTAL_FUNCTIONS`, the
comparison accepts an answer within `OFF_ORACLE_HOST_ULPS` units in the last
place of the expected one. Every other answer, and every answer on Linux, stays
bit-exact.
"""

from std.sys.info import CompilationTarget

from .float_text import FloatTolerance


# Every SQL function whose answer a libm transcendental computes: the ones
# scalar_math.mojo sends to `external_call` (`pow`, `log`, `exp`, `log10`,
# `log2`, `tan`, `atan`, `acos`, `cbrt`, `sinh`, `cosh`, `tanh`, `acosh`,
# `asinh`, `atanh`, `tgamma`; `cot` is `1/tan`) and the ones it takes from
# `std.math` (`sin`, `cos`, `asin`, `atan2`). `sqrt`, `ceil` and `floor` are
# correctly rounded everywhere, and `degrees` and `radians` are one
# multiplication, so they are not here.
comptime TRANSCENDENTAL_FUNCTIONS: List[String] = [
    "acos",
    "acosh",
    "asin",
    "asinh",
    "atan",
    "atan2",
    "atanh",
    "cbrt",
    "cos",
    "cosh",
    "cot",
    "exp",
    "gamma",
    "ln",
    "log",
    "log10",
    "log2",
    "pow",
    "power",
    "sin",
    "sinh",
    "tan",
    "tanh",
]

# The bound off the oracle's platform. glibc's double functions are documented
# within a few ulp, and the largest distance of glibc's `cbrt` from the exact
# root measured over 40000 inputs is under 3 ulp.
comptime OFF_ORACLE_HOST_ULPS = 4


def _is_ident_byte(b: UInt8) -> Bool:
    return (
        (b >= 97 and b <= 122)
        or (b >= 65 and b <= 90)
        or (b >= 48 and b <= 57)
        or b == 95
    )


def _lower(b: UInt8) -> UInt8:
    if b >= 65 and b <= 90:
        return b + 32
    return b


def _calls_at(sql: String, start: Int, name: String) -> Bool:
    """Is `name(` (any case, blanks allowed before the parenthesis) a whole
    word at byte `start` of `sql`?"""
    var bs = sql.as_bytes()
    var nb = name.as_bytes()
    if start + len(nb) > len(bs):
        return False
    if start > 0 and _is_ident_byte(bs[start - 1]):
        return False
    for i in range(len(nb)):
        if _lower(bs[start + i]) != nb[i]:
            return False
    var j = start + len(nb)
    while j < len(bs) and (bs[j] == 32 or bs[j] == 9 or bs[j] == 10):
        j += 1
    return j < len(bs) and bs[j] == 40


def calls_transcendental(sql: String) -> Bool:
    """Does the query text call one of `TRANSCENDENTAL_FUNCTIONS`? A name
    counts only as a whole word followed by `(`, so a column `cbrt_x` or a
    function `xcos(` does not."""
    var names = materialize[TRANSCENDENTAL_FUNCTIONS]()
    for start in range(sql.byte_length()):
        for k in range(len(names)):
            if _calls_at(sql, start, names[k]):
                return True
    return False


def transcendental_tolerance(sql: String, on_oracle_host: Bool) -> FloatTolerance:
    """The tolerance for the DOUBLE answers of the query `sql`: bit-exact on
    the oracle's platform (`on_oracle_host`) and for a query that calls no
    transcendental function; `OFF_ORACLE_HOST_ULPS` otherwise."""
    if on_oracle_host or not calls_transcendental(sql):
        return FloatTolerance()
    return FloatTolerance.of_ulps(OFF_ORACLE_HOST_ULPS)


def is_oracle_host() -> Bool:
    """Is this build's platform one whose libm is the oracle's (glibc, Linux)?"""
    comptime if CompilationTarget.is_linux():
        return True
    else:
        return False
