# =============================================================================
# parquet_reader_factory — builds the scan's per-(worker, file) readers
# =============================================================================
#
# `open` builds worker 0's reader of a file from the session footer cache: on
# a hit with no storage I/O at all (footer, preamble and, when the cache pins
# it, the mapping are shared), on a miss with one tail read. Every other
# worker's reader of the file is `clone_reader_for_worker`, which opens and
# maps nothing. `open_footer_only` gives a reader that knows the footer and
# reads nothing, for a file the scan will never decode (a row window outside
# it).
#
# The reader switches (`numeric_dict_vec`, `recycle_codes`) are the factory's
# and reach every reader it builds.
# =============================================================================

from std.memory import ArcPointer

from komira_fs.file_system import FileSystem
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet_api.metadata import FileMetaData
from komira_scan_planning.reader_factory import ReaderFactory

from .parquet_reader import ParquetReader


struct ParquetReaderFactory[cache_o: Origin[mut=True], FSP: FileSystem](ReaderFactory, Movable, Deinitable):
    """The Parquet `ReaderFactory`: a borrow of the session's footer cache
    and the reader switches.

    Fields:
        _cache_ptr: The session's `ParquetMetadataCache`; it must outlive
            every `open` (a reader, once built, does not need it).
        _numeric_dict_vec: Passed to every reader (see `ParquetReader`).
        _recycle_codes: Passed to every reader.
    """

    comptime FS = Self.FSP
    comptime Reader = ParquetReader[Self.FSP]

    var _cache_ptr: Pointer[ParquetMetadataCache, Self.cache_o]
    var _numeric_dict_vec: Bool
    var _recycle_codes: Bool

    def __init__(
        out self,
        cache_ptr: Pointer[ParquetMetadataCache, Self.cache_o],
        numeric_dict_vec: Bool = False,
        recycle_codes: Bool = False,
    ):
        self._cache_ptr = cache_ptr
        self._numeric_dict_vec = numeric_dict_vec
        self._recycle_codes = recycle_codes

    @staticmethod
    def new(
        cache_ptr: Pointer[ParquetMetadataCache, Self.cache_o],
    ) -> ParquetReaderFactory[Self.cache_o, Self.FSP]:
        """A factory over `cache_ptr` with both reader switches off."""
        return ParquetReaderFactory[Self.cache_o, Self.FSP](cache_ptr)

    def open(mut self, mut fs: Self.FSP, path: String) raises -> ParquetReader[Self.FSP]:
        """Worker 0's reader of `path`: footer, preamble and the pinned
        mapping (if any) shared out of the cache; the file system handle is
        a clone of `fs`."""
        var shared = self._cache_ptr[].get_or_parse_shared_via_fs(path, fs, True)
        var file = ParquetFileReader[Self.FSP].open_with_preamble(
            fs.clone(), path, shared.preamble.share(), shared.mmap_share()
        )
        return ParquetReader[Self.FSP](
            _file=file^,
            _meta=ArcPointer[FileMetaData](copy=shared.meta),
            numeric_dict_vec=self._numeric_dict_vec,
            recycle_codes=self._recycle_codes,
        )

    def clone_reader_for_worker(self, reader: ParquetReader[Self.FSP]) raises -> ParquetReader[Self.FSP]:
        """Another worker's reader of the file `reader` opened
        (`ParquetReader.clone_for_worker`)."""
        return reader.clone_for_worker()

    def open_footer_only(mut self, mut fs: Self.FSP, path: String) raises -> ParquetReader[Self.FSP]:
        """A reader of `path` holding only a stripped footer (schema and row
        counts per row group) and no file body. It must never be decoded."""
        var meta = self._cache_ptr[].stripped_footer_via_fs(path, fs)
        var file = ParquetFileReader[Self.FSP].open_footer_only(fs.clone(), path)
        return ParquetReader[Self.FSP](
            _file=file^,
            _meta=ArcPointer[FileMetaData](meta^),
            numeric_dict_vec=self._numeric_dict_vec,
            recycle_codes=self._recycle_codes,
        )
