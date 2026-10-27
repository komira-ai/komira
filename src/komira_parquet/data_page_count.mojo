# =============================================================================
# data_page_count — how many data pages a column chunk holds
# =============================================================================
#
# `count_data_pages(chunk)` walks a column chunk's page headers (no
# decompression: each step parses a header and jumps over its compressed
# body) and counts the DATA_PAGE and DATA_PAGE_V2 pages. The selection
# decode (`gather.decode_column_with_selection`) takes one mask flag per
# data page; a caller that skips no page sizes an all-True mask with this
# count.
#
# A header whose compressed size is negative or runs past the chunk ends
# the walk: the pages counted so far are returned, and the decode that
# follows walks the same bytes and refuses them.
# =============================================================================

from komira_parquet_api.types import PageType

from .page_header_parser import _parse_page_header


def count_data_pages(chunk: Span[UInt8, _]) raises -> Int:
    """The number of DATA_PAGE and DATA_PAGE_V2 pages in `chunk`.

    Args:
        chunk: The column chunk: page headers and their bodies.

    Raises:
        Error if a page header does not parse.
    """
    var offset = 0
    var count = 0
    var n = len(chunk)
    while offset < n:
        var hdr_result = _parse_page_header(chunk[offset:])
        offset += hdr_result.bytes_consumed
        ref hdr = hdr_result.header
        var compressed = hdr.compressed_page_size
        if compressed < 0 or compressed > n - offset:
            return count
        if hdr.type == PageType.DATA_PAGE or hdr.type == PageType.DATA_PAGE_V2:
            count += 1
        offset += compressed
    return count


def all_pages_mask(chunk: Span[UInt8, _]) raises -> List[Bool]:
    """A page mask that selects every data page of `chunk`."""
    var n = count_data_pages(chunk)
    var mask = List[Bool](capacity=n)
    for _ in range(n):
        mask.append(True)
    return mask^
