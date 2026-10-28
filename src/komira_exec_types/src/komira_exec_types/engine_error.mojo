# =============================================================================
# EngineError -- Structured error types for the engine
# =============================================================================
#
# Structured error codes and context instead of plain string errors.
#
# Mojo uses `raises` for error propagation, which carries a single `Error`
# value (effectively a string). This module provides:
#
#   1. `EngineError` struct -- typed error with code + context + optional
#      detail fields, convertible to/from Mojo's `Error` via `to_error()`
#      and `from_error()`.
#
#   2. Error code constants, one per `EngineError` variant.
#
#   3. Factory functions for each error variant (e.g., `io_error(msg)`,
#      `schema_error(msg)`) that produce properly-tagged `EngineError`.
#
# Usage:
#   raise io_error("file not found: " + path).to_error()
#
#   # Or use the convenience raise helpers:
#   raise_engine_error(io_error("..."))
# =============================================================================


# =============================================================================
# Error code constants
# =============================================================================

# Arrow/columnar error.
comptime ERR_ARROW: Int = 1

# I/O error.
comptime ERR_IO: Int = 2

# Processor/operator error.
comptime ERR_PROCESSOR: Int = 3

# Encode pool error.
comptime ERR_ENCODE_POOL: Int = 4

# Writer error.
comptime ERR_WRITER: Int = 5

# Schema mismatch/validation error.
comptime ERR_SCHEMA: Int = 6

# Reader thread panicked.
comptime ERR_READER_PANIC: Int = 7

# Writer thread panicked.
comptime ERR_WRITER_PANIC: Int = 8

# Format (Parquet, IPC, etc.) error.
comptime ERR_FORMAT: Int = 9

# Invalid argument.
comptime ERR_INVALID_ARGUMENT: Int = 10

# UDF error.
comptime ERR_UDF: Int = 11

# UDF panic.
comptime ERR_UDF_PANIC: Int = 12

# UDF row count mismatch.
comptime ERR_UDF_ROW_COUNT: Int = 13

# Join predicate error.
comptime ERR_JOIN_PREDICATE: Int = 14

# Join predicate panic.
comptime ERR_JOIN_PREDICATE_PANIC: Int = 15

# Join predicate row count mismatch.
comptime ERR_JOIN_PREDICATE_ROW_COUNT: Int = 16


# =============================================================================
# Error code to name mapping
# =============================================================================

def _write_error_code_name[W: Writer](mut writer: W, code: Int):
    """WRITE the value `_error_code_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so that no string constant is ever SELECTED and
    returned: a literal-returning ladder lowers to two parallel (pointer,
    length) constant arrays whose two call-site references an `--emit
    shared-lib` link binds INDEPENDENTLY, and a shared library can bind
    such a pair CROSSED (the name of one code with the length of another)."""
    if code == ERR_ARROW:
        writer.write("Arrow")
        return
    if code == ERR_IO:
        writer.write("IO")
        return
    if code == ERR_PROCESSOR:
        writer.write("Processor")
        return
    if code == ERR_ENCODE_POOL:
        writer.write("EncodePool")
        return
    if code == ERR_WRITER:
        writer.write("Writer")
        return
    if code == ERR_SCHEMA:
        writer.write("Schema")
        return
    if code == ERR_READER_PANIC:
        writer.write("ReaderPanic")
        return
    if code == ERR_WRITER_PANIC:
        writer.write("WriterPanic")
        return
    if code == ERR_FORMAT:
        writer.write("Format")
        return
    if code == ERR_INVALID_ARGUMENT:
        writer.write("InvalidArgument")
        return
    if code == ERR_UDF:
        writer.write("UDF")
        return
    if code == ERR_UDF_PANIC:
        writer.write("UDFPanic")
        return
    if code == ERR_UDF_ROW_COUNT:
        writer.write("UDFRowCount")
        return
    if code == ERR_JOIN_PREDICATE:
        writer.write("JoinPredicate")
        return
    if code == ERR_JOIN_PREDICATE_PANIC:
        writer.write("JoinPredicatePanic")
        return
    if code == ERR_JOIN_PREDICATE_ROW_COUNT:
        writer.write("JoinPredicateRowCount")
        return
    writer.write("Unknown(" + String(code) + ")")
    return


def _error_code_name(code: Int) -> String:
    """Human-readable name for an error code."""
    var out = String()
    _write_error_code_name(out, code)
    return out^


# =============================================================================
# EngineError
# =============================================================================

struct EngineError(Copyable, Movable, Writable):
    """Structured engine error with code, message, and optional context.

    Covers 16 error variants. Mojo does not have enums with associated
    data, so we use an error code + string fields.

    Fields:
        code: One of the ERR_* constants above.
        message: Human-readable error description.
        name: Optional name context (UDF name, predicate name).
        detail: Optional detail (row counts, etc.).
    """

    var code: Int
    var message: String
    var name: String
    var detail: String

    # --- Constructors --------------------------------------------------------

    def __init__(out self, code: Int, message: String):
        """Create an error with code and message."""
        self.code = code
        self.message = message
        self.name = String("")
        self.detail = String("")

    def __init__(
        out self, code: Int, message: String, name: String
    ):
        """Create an error with code, message, and name context."""
        self.code = code
        self.message = message
        self.name = name
        self.detail = String("")

    def __init__(
        out self, code: Int, message: String, name: String, detail: String
    ):
        """Create an error with all fields."""
        self.code = code
        self.message = message
        self.name = name
        self.detail = detail

    # --- Conversion to Mojo Error -------------------------------------------

    def to_error(self) -> Error:
        """Convert to a Mojo Error for use with `raise`.

        Format: "[ErrorCodeName] message" or
                "[ErrorCodeName] 'name': message" when name is set.
        """
        var prefix = "[" + _error_code_name(self.code) + "] "
        if self.name.byte_length() > 0:
            return Error(prefix + "'" + self.name + "': " + self.message)
        return Error(prefix + self.message)

    @staticmethod
    def from_error(err: Error) -> EngineError:
        """Wrap a generic Mojo Error as ERR_PROCESSOR.

        Use when catching errors from downstream code that does not produce
        structured EngineErrors.
        """
        return EngineError(ERR_PROCESSOR, String(err))

    # --- Predicates ----------------------------------------------------------

    @always_inline
    def is_io(self) -> Bool:
        return self.code == ERR_IO

    @always_inline
    def is_schema(self) -> Bool:
        return self.code == ERR_SCHEMA

    @always_inline
    def is_format(self) -> Bool:
        return self.code == ERR_FORMAT

    @always_inline
    def is_panic(self) -> Bool:
        return self.code == ERR_READER_PANIC or self.code == ERR_WRITER_PANIC

    @always_inline
    def is_udf(self) -> Bool:
        return (
            self.code == ERR_UDF
            or self.code == ERR_UDF_PANIC
            or self.code == ERR_UDF_ROW_COUNT
        )

    @always_inline
    def is_join_predicate(self) -> Bool:
        return (
            self.code == ERR_JOIN_PREDICATE
            or self.code == ERR_JOIN_PREDICATE_PANIC
            or self.code == ERR_JOIN_PREDICATE_ROW_COUNT
        )

    # --- Writable ------------------------------------------------------------

    def write_to[W: Writer](self, mut writer: W):
        writer.write(
            "EngineError(code=",
            _error_code_name(self.code),
            ", message=\"",
            self.message,
            "\"",
        )
        if self.name.byte_length() > 0:
            writer.write(", name=\"", self.name, "\"")
        if self.detail.byte_length() > 0:
            writer.write(", detail=\"", self.detail, "\"")
        writer.write(")")


# =============================================================================
# Factory functions (one per variant)
# =============================================================================

def arrow_error(message: String) -> EngineError:
    """Construct EngineError::Arrow(message)."""
    return EngineError(ERR_ARROW, message)


def io_error(message: String) -> EngineError:
    """Construct EngineError::Io(message)."""
    return EngineError(ERR_IO, message)


def processor_error(message: String) -> EngineError:
    """Construct EngineError::Processor(message)."""
    return EngineError(ERR_PROCESSOR, message)


def encode_pool_error(message: String) -> EngineError:
    """Construct EngineError::EncodePool(message)."""
    return EngineError(ERR_ENCODE_POOL, message)


def writer_error(message: String) -> EngineError:
    """Construct EngineError::Writer(message)."""
    return EngineError(ERR_WRITER, message)


def schema_error(message: String) -> EngineError:
    """Construct EngineError::Schema(message)."""
    return EngineError(ERR_SCHEMA, message)


def reader_panic_error() -> EngineError:
    """Construct EngineError::ReaderPanic."""
    return EngineError(ERR_READER_PANIC, "Reader thread panicked")


def writer_panic_error() -> EngineError:
    """Construct EngineError::WriterPanic."""
    return EngineError(ERR_WRITER_PANIC, "Writer thread panicked")


def format_error(message: String) -> EngineError:
    """Construct EngineError::Format(message)."""
    return EngineError(ERR_FORMAT, message)


def invalid_argument_error(message: String) -> EngineError:
    """Construct EngineError::InvalidArgument(message)."""
    return EngineError(ERR_INVALID_ARGUMENT, message)


def udf_error(name: String, message: String) -> EngineError:
    """Construct EngineError::Udf { name, message }."""
    return EngineError(ERR_UDF, message, name)


def udf_panic_error(udf_name: String, message: String) -> EngineError:
    """Construct EngineError::UdfPanic { udf_name, message }."""
    return EngineError(ERR_UDF_PANIC, message, udf_name)


def udf_row_count_error(
    udf_name: String, input_rows: Int, output_rows: Int
) -> EngineError:
    """Construct EngineError::UdfRowCountMismatch { udf_name, input_rows, output_rows }."""
    var msg = (
        "expected "
        + String(input_rows)
        + " output rows, got "
        + String(output_rows)
    )
    var detail = (
        "input_rows=" + String(input_rows) + ", output_rows=" + String(output_rows)
    )
    return EngineError(ERR_UDF_ROW_COUNT, msg, udf_name, detail)


def join_predicate_error(
    predicate_name: String, message: String
) -> EngineError:
    """Construct EngineError::JoinPredicate { predicate_name, message }."""
    return EngineError(ERR_JOIN_PREDICATE, message, predicate_name)


def join_predicate_panic_error(
    predicate_name: String, message: String
) -> EngineError:
    """Construct EngineError::JoinPredicatePanic { predicate_name, message }."""
    return EngineError(ERR_JOIN_PREDICATE_PANIC, message, predicate_name)


def join_predicate_row_count_error(
    predicate_name: String, input_rows: Int, output_rows: Int
) -> EngineError:
    """Construct EngineError::JoinPredicateRowCountMismatch."""
    var msg = (
        "expected "
        + String(input_rows)
        + " result rows, got "
        + String(output_rows)
    )
    var detail = (
        "input_rows=" + String(input_rows) + ", output_rows=" + String(output_rows)
    )
    return EngineError(
        ERR_JOIN_PREDICATE_ROW_COUNT, msg, predicate_name, detail
    )
