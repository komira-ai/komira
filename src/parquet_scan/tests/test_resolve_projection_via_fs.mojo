# `resolve_projection_indices` and `resolve_projection_indices_via_fs`: a
# scan's projection names as the leaf indices of a file's footer.
#
# Rows: the names resolve to their columns in the order asked, through the
# local wrapper and through the generic form given a file system; no names
# is every column; a name the footer lacks is refused naming it; the footer
# is read once into the cache under the file system's key (the local key is
# the path) and the second resolution is a hit.
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from async_rt.ops.waker_sink import NoopSink
from fs.local_fs import LocalFs
from parquet.runtime_footer_cache import ParquetMetadataCache
from parquet_scan.parquet_source_options import (
    resolve_projection_indices,
    resolve_projection_indices_via_fs,
)
from runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file


def _file() raises -> String:
    var path = test_tmpdir() + "/projection_via_fs.parquet"
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", [1, 2]))
    cols.append(TestColumn.string("s", ["x", "y"]))
    cols.append(TestColumn.int64("n", [3, 4]))
    write_parquet_file(path, cols, TestFileLayout.single())
    return path^


def _names(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def test_names_resolve_in_the_order_asked() raises:
    var path = _file()
    # A file written just now is trusted at once, so a hit is a hit.
    var cache = ParquetMetadataCache(mmap_revalidate_min_age_ns=0)
    var local = resolve_projection_indices(cache, path, _names("n", "a"))
    assert_equal(len(local.explicit_indices_ref()), 2)
    assert_equal(local.explicit_indices_ref()[0], 2)
    assert_equal(local.explicit_indices_ref()[1], 0)
    var fs = LocalFs[NoopSink].new()
    var generic = resolve_projection_indices_via_fs(cache, path, fs, _names("s", "n"))
    assert_equal(generic.explicit_indices_ref()[0], 1)
    assert_equal(generic.explicit_indices_ref()[1], 2)
    # One footer read, keyed by the local path; the second resolution hit it.
    assert_equal(cache.miss_count(), 1)
    assert_equal(cache.hit_count_for(path), 1)


def test_no_names_is_every_column() raises:
    var cache = ParquetMetadataCache()
    var fs = LocalFs[NoopSink].new()
    var every = resolve_projection_indices_via_fs(cache, _file(), fs, List[String]())
    assert_true(every.project_all)
    # Nothing was read for it.
    assert_equal(cache.miss_count(), 0)


def test_a_name_the_footer_lacks_is_refused() raises:
    var cache = ParquetMetadataCache()
    var fs = LocalFs[NoopSink].new()
    with assert_raises(contains="unknown projection column 'z'"):
        _ = resolve_projection_indices_via_fs(cache, _file(), fs, _names("a", "z"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
