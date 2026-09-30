# =============================================================================
# StringDictionaryArray — Arrow-compatible dictionary-encoded string column
# =============================================================================
#
# Arrow DictionaryArray format: an indices array (integer) maps each row to
# an entry in a dictionary array (unique values). This is the representation
# Parquet uses for low-cardinality string columns.
#
# Layout:
#   indices: PrimitiveArray[DType.int32] — row -> dict entry index
#   dictionary: StringArray — unique string values
#
# For dict-aware aggregation, the raw index values can be used directly as
# group IDs without resolving through the dictionary, avoiding string hashing.
# =============================================================================

from .primitive_array import PrimitiveArray
from .string_array import StringArray
from ..io.heap_region import HeapRegion


struct StringDictionaryArray(Movable, Sized):
    """Dictionary-encoded string column: integer indices -> string dictionary.

    The indices array maps each row to a dictionary entry.
    The dictionary stores the unique string values.
    This is the representation Parquet uses for low-cardinality strings.

    Fields:
        indices: PrimitiveArray[DType.int32] mapping each row to a dict entry.
        dictionary: StringArray holding the unique string values.
        length: Number of logical elements (rows).
    """

    var indices: PrimitiveArray[DType.int32]
    var dictionary: StringArray[HeapRegion]
    var length: Int

    # --- Constructors ---

    def __init__(
        out self,
        var indices: PrimitiveArray[DType.int32],
        var dictionary: StringArray[HeapRegion],
        length: Int,
    ):
        """Construct a StringDictionaryArray from indices and dictionary."""
        self.indices = indices^
        self.dictionary = dictionary^
        self.length = length

    @staticmethod
    def from_parts(
        var indices: PrimitiveArray[DType.int32],
        var dictionary: StringArray[HeapRegion],
    ) -> StringDictionaryArray:
        """Create a StringDictionaryArray from pre-built indices and dictionary.

        Args:
            indices: PrimitiveArray[DType.int32] where each value is an index
                into the dictionary. Length determines the number of rows.
            dictionary: StringArray holding the unique string values.

        Returns:
            A new StringDictionaryArray.
        """
        var length = indices.length
        return StringDictionaryArray(indices^, dictionary^, length)

    # --- Destructor ---
    # PrimitiveArray and StringArray handle their own cleanup.

    # --- Element Access ---

    @always_inline
    def __len__(self) -> Int:
        """Return the number of rows in the array."""
        return self.length

    def get(self, index: Int) raises -> String:
        """Resolve the dictionary value for the row at the given index.

        Looks up indices[index] to get the dictionary position, then returns
        dictionary[that_position].

        Args:
            index: Zero-based row index.

        Returns:
            The resolved string value from the dictionary.

        Raises:
            Error if index is out of bounds, or the dictionary index is invalid.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "StringDictionaryArray.get: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        var dict_idx = Int(self.indices.get(index))
        if dict_idx < 0 or dict_idx >= len(self.dictionary):
            raise Error(
                "StringDictionaryArray.get: dictionary index "
                + String(dict_idx)
                + " out of range [0, "
                + String(len(self.dictionary))
                + ")"
            )
        return self.dictionary.get(dict_idx)

    def get_index(self, index: Int) raises -> Int:
        """Return the raw dictionary index for the row at the given position.

        This is useful for dict-aware aggregation where the integer index
        can be used directly as a group ID, avoiding string hashing entirely.

        Args:
            index: Zero-based row index.

        Returns:
            The integer dictionary index (Int32 widened to Int).

        Raises:
            Error if index is out of bounds.
        """
        if index < 0 or index >= self.length:
            raise Error(
                "StringDictionaryArray.get_index: index "
                + String(index)
                + " out of range [0, "
                + String(self.length)
                + ")"
            )
        return Int(self.indices.get(index))

    def dict_size(self) -> Int:
        """Return the number of entries in the dictionary."""
        return len(self.dictionary)
