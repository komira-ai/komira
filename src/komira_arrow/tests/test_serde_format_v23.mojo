# =============================================================================
# Tests for the SerdeFormat / Compression trait architecture
# =============================================================================
#
# Verifies:
#   1. `SerdeFormat` markers are distinct types under `(A == B)`.
#   2. All 8 `Compression` conformers exist with correct `PARQUET_CODEC_ID`.
#   3. `Snappy.compress` + `Snappy.decompress` round-trip works (validates
#      the libsnappy FFI shim).
#   4. `Uncompressed.compress` + `Uncompressed.decompress` round-trip.
#   5. `WholeFileCompressed[Jsonl, Gzip[]]` and `WholeFileCompressed[Csv, Gzip[]]`
#      compile + correct extension detection.
#   6. `Parquet[C: Compression = Snappy]` default-binding compiles, and
#      `Parquet[Snappy]` (explicit) is the SAME type as `Parquet` (default).
#   7. `default_options()` returns the right type per format.
#   8. `detect_extension(path)` matches per format.
# =============================================================================


from komira_arrow.serde_format import CompressionModel, SerdeFormat
from komira_arrow.serde_format_options import (
    ArrowOptions,
    CsvOptions,
    JsonOptions,
    ParquetOptions,
)
from komira_compression.compression import Compression
from komira_compression.compression_codecs import (
    Brotli,
    Gzip,
    Lz4Raw,
    Lzo,
    Snappy,
    Uncompressed,
    Zlib,
    Zstd,
)
from komira_arrow.formats import (
    Arrow,
    Csv,
    Jsonl,
    Parquet,
    WholeFileCompressed,
)
from komira_arrow.quote_styles import Rfc4180


# =============================================================================
# Test 1 — SerdeFormat markers are distinct types
# =============================================================================


def test_format_markers_distinct() raises:
    print("Test 1: SerdeFormat markers are distinct types under _type_is_eq")

    # Pairwise distinctness across the 4 base markers.
    comptime assert not (Parquet[Snappy] == Jsonl), "Parquet[Snappy] and Jsonl must be distinct types"
    comptime assert not (Parquet[Snappy] == Csv[Rfc4180]), "Parquet[Snappy] and Csv[Rfc4180] must be distinct types"
    comptime assert not (Parquet[Snappy] == Arrow[]), "Parquet[Snappy] and Arrow must be distinct types"
    comptime assert not (Jsonl == Csv[Rfc4180]), "Jsonl and Csv[Rfc4180] must be distinct types"
    comptime assert not (Jsonl == Arrow[]), "Jsonl and Arrow must be distinct"
    comptime assert not (Csv[Rfc4180] == Arrow[]), "Csv[Rfc4180] and Arrow must be distinct"

    # Different Parquet[C] specializations are distinct.
    comptime assert not (Parquet[Snappy] == Parquet[Zstd[]]), "Parquet[Snappy] and Parquet[Zstd] must be distinct types"
    comptime assert not (Parquet[Snappy] == Parquet[Uncompressed]), "Parquet[Snappy] and Parquet[Uncompressed] must be distinct types"
    comptime assert not (Parquet[Zstd[]] == Parquet[Gzip[]]), "Parquet[Zstd] and Parquet[Gzip] must be distinct types"

    print("  PASS")


# =============================================================================
# Test 2 — Default Parquet binding `Parquet` == `Parquet[Snappy]`
# =============================================================================


def test_parquet_default_compression_binding() raises:
    """The default parameter `Parquet[C: Compression = Snappy]`.

    `Parquet` (no explicit C) should resolve to `Parquet[Snappy]`.
    """
    print("Test 2: Parquet default-C binding == Parquet[Snappy]")

    comptime assert (Parquet[] == Parquet[Snappy]), "Parquet[] (default-C) must equal Parquet[Snappy] (explicit)"

    print("  PASS")


# =============================================================================
# Test 3 — Compression conformers have correct PARQUET_CODEC_ID
# =============================================================================


def test_compression_parquet_codec_ids() raises:
    print("Test 3: Compression conformers have correct PARQUET_CODEC_ID")

    if Uncompressed.PARQUET_CODEC_ID != Int8(0):
        raise Error(
            "Uncompressed.PARQUET_CODEC_ID expected 0, got "
            + String(Int(Uncompressed.PARQUET_CODEC_ID))
        )
    if Snappy.PARQUET_CODEC_ID != Int8(1):
        raise Error(
            "Snappy.PARQUET_CODEC_ID expected 1, got "
            + String(Int(Snappy.PARQUET_CODEC_ID))
        )
    if Gzip.PARQUET_CODEC_ID != Int8(2):
        raise Error(
            "Gzip.PARQUET_CODEC_ID expected 2, got "
            + String(Int(Gzip.PARQUET_CODEC_ID))
        )
    if Lzo.PARQUET_CODEC_ID != Int8(3):
        raise Error(
            "Lzo.PARQUET_CODEC_ID expected 3, got "
            + String(Int(Lzo.PARQUET_CODEC_ID))
        )
    if Brotli.PARQUET_CODEC_ID != Int8(4):
        raise Error(
            "Brotli.PARQUET_CODEC_ID expected 4, got "
            + String(Int(Brotli.PARQUET_CODEC_ID))
        )
    if Zstd.PARQUET_CODEC_ID != Int8(6):
        raise Error(
            "Zstd.PARQUET_CODEC_ID expected 6, got "
            + String(Int(Zstd.PARQUET_CODEC_ID))
        )
    if Lz4Raw.PARQUET_CODEC_ID != Int8(7):
        raise Error(
            "Lz4Raw.PARQUET_CODEC_ID expected 7, got "
            + String(Int(Lz4Raw.PARQUET_CODEC_ID))
        )
    if Zlib.PARQUET_CODEC_ID != Int8(8):
        raise Error(
            "Zlib.PARQUET_CODEC_ID expected 8, got "
            + String(Int(Zlib.PARQUET_CODEC_ID))
        )

    print("  PASS (8 conformers, codec ids 0/1/2/3/4/6/7/8 verified)")


# =============================================================================
# Test 4 — Compression conformer NAME / FILE_EXTENSION sanity
# =============================================================================


def test_compression_name_and_extension() raises:
    print("Test 4: Compression NAME + FILE_EXTENSION sanity")

    # NAME values (human-readable)
    if String(Uncompressed.NAME) != "uncompressed":
        raise Error("Uncompressed.NAME wrong: " + String(Uncompressed.NAME))
    if String(Snappy.NAME) != "snappy":
        raise Error("Snappy.NAME wrong: " + String(Snappy.NAME))
    if String(Gzip.NAME) != "gzip":
        raise Error("Gzip.NAME wrong: " + String(Gzip.NAME))
    if String(Zstd.NAME) != "zstd":
        raise Error("Zstd.NAME wrong: " + String(Zstd.NAME))

    # FILE_EXTENSION
    if String(Uncompressed.FILE_EXTENSION) != "":
        raise Error(
            "Uncompressed.FILE_EXTENSION expected empty, got "
            + String(Uncompressed.FILE_EXTENSION)
        )
    if String(Gzip.FILE_EXTENSION) != ".gz":
        raise Error(
            "Gzip.FILE_EXTENSION wrong: " + String(Gzip.FILE_EXTENSION)
        )
    if String(Zstd.FILE_EXTENSION) != ".zst":
        raise Error(
            "Zstd.FILE_EXTENSION wrong: " + String(Zstd.FILE_EXTENSION)
        )

    print("  PASS (NAMEs + extensions for working codecs verified)")


# =============================================================================
# Test 5 — Uncompressed round-trip
# =============================================================================


def test_uncompressed_roundtrip() raises:
    print("Test 5: Uncompressed round-trip")

    var data = List[UInt8]()
    for i in range(64):
        data.append(UInt8(i % 256))

    var compressed = Uncompressed.compress(Span(data))
    if len(compressed) != len(data):
        raise Error(
            "Uncompressed.compress did not preserve length; expected "
            + String(len(data)) + ", got " + String(len(compressed))
        )

    var decompressed = Uncompressed.decompress(
        Span(compressed), len(data)
    )
    if len(decompressed) != len(data):
        raise Error("Uncompressed.decompress did not restore length")
    for i in range(len(data)):
        if decompressed[i] != data[i]:
            raise Error(
                "Uncompressed round-trip mismatch at byte " + String(i)
            )

    print("  PASS (64 bytes round-trip)")


# =============================================================================
# Test 6 — Snappy round-trip (validates libsnappy FFI shim)
# =============================================================================


def test_snappy_roundtrip() raises:
    print("Test 6: Snappy round-trip via libsnappy FFI shim")

    var data = List[UInt8]()
    # Pattern with both short-literal and long-literal opportunities for
    # Snappy to exercise different encode paths.
    var pattern_len = 8
    for i in range(256):
        data.append(UInt8(i % pattern_len))
    # Add a run of identical bytes for the COPY path.
    for _ in range(64):
        data.append(UInt8(42))

    var compressed = Snappy.compress(Span(data))
    if len(compressed) >= len(data):
        # On highly-compressible data the compressed should be smaller.
        # Don't fail (could happen on very small input); just print.
        print("  NOTE: compressed >= original; n=" + String(len(data))
            + " vs c=" + String(len(compressed)))

    var decompressed = Snappy.decompress(Span(compressed), 0)
    if len(decompressed) != len(data):
        raise Error(
            "Snappy.decompress wrong length; expected "
            + String(len(data)) + " got " + String(len(decompressed))
        )
    for i in range(len(data)):
        if decompressed[i] != data[i]:
            raise Error(
                "Snappy round-trip mismatch at byte " + String(i)
            )

    print("  PASS (320 bytes round-trip via libsnappy)")


# =============================================================================
# Test 7 — `default_options()` returns the right type per format
# =============================================================================


def test_default_options_per_format() raises:
    print("Test 7: default_options() returns format-specific type")

    # ParquetOptions
    var p_opts = Parquet[Snappy].default_options()
    if p_opts.dictionary != True:
        raise Error("ParquetOptions.dictionary default expected True")
    if p_opts.row_group_target_bytes <= 0:
        raise Error("ParquetOptions.row_group_target_bytes must be > 0")

    # JsonOptions
    var j_opts = Jsonl.default_options()
    if j_opts.lines_mode != False:
        raise Error("JsonOptions.lines_mode default expected False")
    if j_opts.pretty != False:
        raise Error("JsonOptions.pretty default expected False")

    # CsvOptions
    var c_opts = Csv[Rfc4180].default_options()
    if c_opts.delimiter != UInt8(ord(",")):
        raise Error("CsvOptions.delimiter default expected b','")
    if c_opts.header != True:
        raise Error("CsvOptions.header default expected True")
    if c_opts.quote != UInt8(ord('"')):
        raise Error("CsvOptions.quote default expected b'\"'")

    # ArrowOptions (placeholder Bool field)
    var a_opts = Arrow.default_options()
    if a_opts._reserved != False:
        raise Error("ArrowOptions._reserved default expected False")

    print("  PASS (4 Options types per format)")


# =============================================================================
# Test 8 — `detect_extension(path)` per format
# =============================================================================


def test_detect_extension_per_format() raises:
    print("Test 8: detect_extension matches each format's suffix")

    if not Parquet[Snappy].detect_extension(String("foo.parquet")):
        raise Error("Parquet should detect .parquet")
    if not Parquet[Snappy].detect_extension(String("foo.pq")):
        raise Error("Parquet should detect .pq")
    if Parquet[Snappy].detect_extension(String("foo.json")):
        raise Error("Parquet should NOT detect .json")

    if not Jsonl.detect_extension(String("foo.json")):
        raise Error("Jsonl should detect .json")
    if not Jsonl.detect_extension(String("foo.jsonl")):
        raise Error("Jsonl should detect .jsonl")
    if not Jsonl.detect_extension(String("foo.ndjson")):
        raise Error("Jsonl should detect .ndjson")
    if Jsonl.detect_extension(String("foo.parquet")):
        raise Error("Jsonl should NOT detect .parquet")

    if not Csv[Rfc4180].detect_extension(String("foo.csv")):
        raise Error("Csv[Rfc4180] should detect .csv")
    if not Csv[Rfc4180].detect_extension(String("foo.tsv")):
        raise Error("Csv[Rfc4180] should detect .tsv")
    if Csv[Rfc4180].detect_extension(String("foo.json")):
        raise Error("Csv[Rfc4180] should NOT detect .json")

    if not Arrow.detect_extension(String("foo.arrow")):
        raise Error("Arrow should detect .arrow")
    if not Arrow.detect_extension(String("foo.ipc")):
        raise Error("Arrow should detect .ipc")

    print("  PASS")


# =============================================================================
# Test 9 — `WholeFileCompressed[Jsonl, Gzip[]]` compiles + detects .jsonl.gz
# =============================================================================


def test_whole_file_compressed_jsonl_gzip() raises:
    print("Test 9: WholeFileCompressed[Jsonl, Gzip[]] composition")

    # Detect .jsonl.gz
    if not WholeFileCompressed[Jsonl, Gzip[]].detect_extension(
        String("data.jsonl.gz")
    ):
        raise Error("WholeFileCompressed[Jsonl, Gzip[]] should detect .jsonl.gz")
    if not WholeFileCompressed[Jsonl, Gzip[]].detect_extension(
        String("data.json.gz")
    ):
        raise Error("WholeFileCompressed[Jsonl, Gzip[]] should detect .json.gz")

    # Should NOT detect .gz alone (inner detect must also match)
    if WholeFileCompressed[Jsonl, Gzip[]].detect_extension(String("data.gz")):
        raise Error(
            "WholeFileCompressed[Jsonl, Gzip[]] should NOT detect bare .gz"
        )

    # Should NOT detect .parquet.gz (Jsonl's detect_extension rejects .parquet)
    if WholeFileCompressed[Jsonl, Gzip[]].detect_extension(
        String("data.parquet.gz")
    ):
        raise Error(
            "WholeFileCompressed[Jsonl, Gzip[]] should NOT detect .parquet.gz"
        )

    # Options associated type aliases inner.
    var opts = WholeFileCompressed[Jsonl, Gzip[]].default_options()
    if opts.lines_mode != False:
        raise Error("WholeFileCompressed Inner Options not threaded")

    print("  PASS")


# =============================================================================
# Test 10 — `WholeFileCompressed[Csv, Gzip[]]` and others compile
# =============================================================================


def test_whole_file_compressed_csv_gzip() raises:
    print("Test 10: WholeFileCompressed[Csv, Gzip[]] + composition extras")

    if not WholeFileCompressed[Csv[Rfc4180], Gzip[]].detect_extension(
        String("data.csv.gz")
    ):
        raise Error(
            "WholeFileCompressed[Csv[Rfc4180], Gzip[]] should detect .csv.gz"
        )

    # Csv[Rfc4180] + Zstd composes
    if not WholeFileCompressed[Csv[Rfc4180], Zstd[]].detect_extension(
        String("data.csv.zst")
    ):
        raise Error(
            "WholeFileCompressed[Csv[Rfc4180], Zstd[]] should detect .csv.zst"
        )

    # Distinct types
    comptime assert not (WholeFileCompressed[Jsonl, Gzip[]] == WholeFileCompressed[Csv[Rfc4180], Gzip[]]), "WFC[Jsonl,Gzip] and WFC[Csv[Rfc4180],Gzip] must be distinct types"
    comptime assert not (WholeFileCompressed[Jsonl, Gzip[]] == WholeFileCompressed[Jsonl, Zstd[]]), "WFC[Jsonl,Gzip] and WFC[Jsonl,Zstd] must be distinct types"

    print("  PASS")


# =============================================================================
# Test 11 — Scaffold conformers raise clear errors (not silently no-op)
# =============================================================================


def test_scaffold_codecs_raise() raises:
    print("Test 11: Scaffold codecs (Lzo/Brotli/Zlib) raise clearly")
    # Lz4Raw is not a scaffold: it is implemented over liblz4's
    # LZ4_compress_default / LZ4_decompress_safe, so Lz4Raw.compress() succeeds
    # and must NOT be asserted to raise. The scaffold (raise-on-compress)
    # conformers are Lzo / Brotli / Zlib.

    var data = List[UInt8]()
    data.append(UInt8(1))

    var saw_lzo = False
    try:
        _ = Lzo.compress(Span(data))
    except _:
        saw_lzo = True
    if not saw_lzo:
        raise Error("Lzo.compress should raise (scaffold)")

    var saw_brotli = False
    try:
        _ = Brotli.compress(Span(data))
    except _:
        saw_brotli = True
    if not saw_brotli:
        raise Error("Brotli.compress should raise (scaffold)")

    var saw_zlib = False
    try:
        _ = Zlib.compress(Span(data))
    except _:
        saw_zlib = True
    if not saw_zlib:
        raise Error("Zlib.compress should raise (scaffold)")

    print("  PASS (3 scaffold conformers raise on compress)")


# =============================================================================
# Test 12 — COMPRESSION_MODEL discriminator per format
# =============================================================================


def test_compression_model_per_format() raises:
    """Verifies each SerdeFormat conformer declares the correct
    `COMPRESSION_MODEL` for the format factory dispatch.

    Parquet:           InternalRequired (codec lives in footer + page header)
    Jsonl, Csv:        ExternalOnly (no internal codec; WholeFileCompressed)
    Arrow:             InternalOptional (spec supports both)
    WholeFileCompressed: ExternalOnly (the wrapper IS the external wrap)
    """
    print("Test 12: COMPRESSION_MODEL discriminator per format")

    # Parquet — InternalRequired
    if Parquet[].COMPRESSION_MODEL != CompressionModel.InternalRequired:
        raise Error(
            "Parquet[].COMPRESSION_MODEL expected InternalRequired, got "
            + String(Int(Parquet[].COMPRESSION_MODEL.value))
        )
    if Parquet[Zstd[]].COMPRESSION_MODEL != CompressionModel.InternalRequired:
        raise Error("Parquet[Zstd[]] should be InternalRequired")

    # Jsonl, Csv — ExternalOnly
    if Jsonl.COMPRESSION_MODEL != CompressionModel.ExternalOnly:
        raise Error("Jsonl.COMPRESSION_MODEL expected ExternalOnly")
    if Csv[Rfc4180].COMPRESSION_MODEL != CompressionModel.ExternalOnly:
        raise Error("Csv[Rfc4180].COMPRESSION_MODEL expected ExternalOnly")

    # Arrow — InternalOptional
    if Arrow.COMPRESSION_MODEL != CompressionModel.InternalOptional:
        raise Error("Arrow.COMPRESSION_MODEL expected InternalOptional")

    # WholeFileCompressed — ExternalOnly (the wrap *is* the external)
    if (
        WholeFileCompressed[Jsonl, Gzip[]].COMPRESSION_MODEL
        != CompressionModel.ExternalOnly
    ):
        raise Error("WFC[Jsonl, Gzip[]] expected ExternalOnly")
    if (
        WholeFileCompressed[Csv[Rfc4180], Zstd[]].COMPRESSION_MODEL
        != CompressionModel.ExternalOnly
    ):
        raise Error("WFC[Csv[Rfc4180], Zstd[]] expected ExternalOnly")

    # CompressionModel equality / inequality
    if CompressionModel.InternalRequired == CompressionModel.ExternalOnly:
        raise Error("InternalRequired == ExternalOnly (should be !=)")
    if CompressionModel.InternalRequired != CompressionModel.InternalRequired:
        raise Error("InternalRequired != InternalRequired (should be ==)")

    print("  PASS (5 format markers + WFC wrapper + Eq/NotEq verified)")


def main() raises:
    print("=" * 60)
    print("SerdeFormat / Compression trait architecture")
    print("=" * 60)
    test_format_markers_distinct()
    test_parquet_default_compression_binding()
    test_compression_parquet_codec_ids()
    test_compression_name_and_extension()
    test_uncompressed_roundtrip()
    test_snappy_roundtrip()
    test_default_options_per_format()
    test_detect_extension_per_format()
    test_whole_file_compressed_jsonl_gzip()
    test_whole_file_compressed_csv_gzip()
    test_scaffold_codecs_raise()
    test_compression_model_per_format()
    print("=" * 60)
    print("SerdeFormat / Compression: ALL TESTS PASS (12/12)")
    print("=" * 60)
