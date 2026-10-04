# =============================================================================
# Tests for Field/Schema explicit Copyable (auto-synthesized .copy())
#
#   Field + Schema are `Copyable, Deinitable` so that downstream (DataFrame
#   copies, plan-IR copy walks) can deep-clone them. They are not
#   ImplicitlyCopyable because List[String] is Copyable but not
#   ImplicitlyCopyable; Copyable + .copy() works.
#
#   These tests verify:
#     1) Field.copy() preserves all 9 fields (5 distinct fields covered).
#     2) Schema.copy() preserves all field-attribute lists.
#     3) Mutating the cloned Schema's underlying state (via SchemaBuilder
#        round-trip) leaves the original unchanged — ownership independence.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false


from komira_arrow.schema import Schema, Field, SchemaBuilder
from komira_arrow.arrow_types import ArrowType


def test_field_copy_preserves_simple_fields() raises:
    """Field.copy() preserves name, dtype, arrow_type, nullable."""
    var f1 = Field("score", ArrowType.FLOAT64, nullable=True)
    var f2 = f1.copy()
    assert_equal(f1.name, f2.name)
    assert_equal(f1.dtype, f2.dtype)
    assert_true(f1.arrow_type == f2.arrow_type)
    assert_equal(f1.nullable, f2.nullable)


def test_field_copy_preserves_metadata() raises:
    """Field.copy() deep-copies the metadata key/value lists."""
    var f1 = Field("col_with_meta", ArrowType.INT64, nullable=False)
    f1.set_metadata(String("source"), String("upstream"))
    f1.set_metadata(String("encoding"), String("utf8"))
    var f2 = f1.copy()
    assert_equal(f2.metadata_count(), 2)
    var v0 = f2.get_metadata(String("source"))
    assert_true(v0 is not None)
    assert_equal(v0.value(), String("upstream"))
    var v1 = f2.get_metadata(String("encoding"))
    assert_true(v1 is not None)
    assert_equal(v1.value(), String("utf8"))


def test_field_copy_metadata_independence() raises:
    """Mutating the copy's metadata does not affect the original."""
    var f1 = Field("x", ArrowType.INT32, nullable=True)
    f1.set_metadata(String("k"), String("v"))
    var f2 = f1.copy()
    f2.set_metadata(String("k"), String("mutated"))
    f2.set_metadata(String("new_key"), String("new_val"))
    # f1 unchanged
    assert_equal(f1.metadata_count(), 1)
    var orig = f1.get_metadata(String("k"))
    assert_true(orig is not None)
    assert_equal(orig.value(), String("v"))
    # f2 has the mutation + extra key
    assert_equal(f2.metadata_count(), 2)


def test_field_copy_preserves_children() raises:
    """Field.copy() deep-copies the child name/type/nullable lists."""
    var f1 = Field("nested", ArrowType.STRUCT, nullable=False)
    f1.add_child(String("c0"), ArrowType.INT64, nullable=False)
    f1.add_child(String("c1"), ArrowType.STRING, nullable=True)
    var f2 = f1.copy()
    assert_equal(f2.num_children(), 2)
    assert_equal(f2.child_name(0), String("c0"))
    assert_true(f2.child_arrow_type(0) == ArrowType.INT64)
    assert_false(f2.child_nullable(0))
    assert_equal(f2.child_name(1), String("c1"))
    assert_true(f2.child_arrow_type(1) == ArrowType.STRING)
    assert_true(f2.child_nullable(1))


def test_field_copy_distinct_arrow_types() raises:
    """Cover 5+ Field shapes via .copy(): BOOL, INT32, FLOAT64, STRING, DATE32."""
    var fb = Field("flag", ArrowType.BOOL, nullable=True).copy()
    assert_true(fb.arrow_type == ArrowType.BOOL)
    var fi = Field("count", ArrowType.INT32, nullable=False).copy()
    assert_true(fi.arrow_type == ArrowType.INT32)
    var ff = Field("ratio", ArrowType.FLOAT64, nullable=True).copy()
    assert_true(ff.arrow_type == ArrowType.FLOAT64)
    var fs = Field("name", ArrowType.STRING, nullable=False).copy()
    assert_true(fs.arrow_type == ArrowType.STRING)
    var fd = Field("when", ArrowType.DATE32, nullable=False).copy()
    assert_true(fd.arrow_type == ArrowType.DATE32)


def test_schema_copy_preserves_fields() raises:
    """Schema.copy() preserves names, arrow_types, dtypes, nullables for 5 fields."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, nullable=False))
    sb.add_field(Field("b", ArrowType.FLOAT64, nullable=True))
    sb.add_field(Field("c", ArrowType.STRING, nullable=False))
    sb.add_field(Field("d", ArrowType.BOOL, nullable=True))
    sb.add_field(Field("e", ArrowType.DATE32, nullable=False))
    var s1 = sb.build()
    var s2 = s1.copy()
    assert_equal(s2.num_columns(), 5)
    assert_equal(s2.field_name(0), String("a"))
    assert_true(s2.field_arrow_type(0) == ArrowType.INT64)
    assert_false(s2.field_nullable(0))
    assert_equal(s2.field_name(1), String("b"))
    assert_true(s2.field_arrow_type(1) == ArrowType.FLOAT64)
    assert_true(s2.field_nullable(1))
    assert_equal(s2.field_name(2), String("c"))
    assert_true(s2.field_arrow_type(2) == ArrowType.STRING)
    assert_equal(s2.field_name(3), String("d"))
    assert_true(s2.field_arrow_type(3) == ArrowType.BOOL)
    assert_equal(s2.field_name(4), String("e"))
    assert_true(s2.field_arrow_type(4) == ArrowType.DATE32)


def test_schema_copy_preserves_metadata() raises:
    """Schema.copy() preserves schema-level metadata."""
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, nullable=False))
    var s1 = sb.build()
    s1.set_metadata(String("origin"), String("test"))
    s1.set_metadata(String("ver"), String("1"))
    var s2 = s1.copy()
    assert_equal(s2.metadata_count(), 2)
    var v = s2.get_metadata(String("origin"))
    assert_true(v is not None)
    assert_equal(v.value(), String("test"))


def test_schema_copy_metadata_independence() raises:
    """Mutating the cloned Schema's metadata does not affect the original."""
    var sb = SchemaBuilder()
    sb.add_field(Field("col", ArrowType.INT64, nullable=False))
    var s1 = sb.build()
    s1.set_metadata(String("k"), String("orig"))
    var s2 = s1.copy()
    s2.set_metadata(String("k"), String("mutated"))
    s2.set_metadata(String("new"), String("val"))
    assert_equal(s1.metadata_count(), 1)
    var orig = s1.get_metadata(String("k"))
    assert_true(orig is not None)
    assert_equal(orig.value(), String("orig"))
    assert_equal(s2.metadata_count(), 2)


def main() raises:
    var suite = TestSuite()
    suite.test[test_field_copy_preserves_simple_fields]()
    suite.test[test_field_copy_preserves_metadata]()
    suite.test[test_field_copy_metadata_independence]()
    suite.test[test_field_copy_preserves_children]()
    suite.test[test_field_copy_distinct_arrow_types]()
    suite.test[test_schema_copy_preserves_fields]()
    suite.test[test_schema_copy_preserves_metadata]()
    suite.test[test_schema_copy_metadata_independence]()
    suite^.run()
