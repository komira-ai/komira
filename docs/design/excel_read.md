# Reading an Excel (.xlsx) sheet as a table

Status: design, not built. Issue: komira-ai/komira#2336. What the engine, SQL and Python do today is in
[What exists today](#what-exists-today). Every other statement here is about the reader this design
specifies, which has no code yet. When this document describes DuckDB, it says whether the statement was
read in DuckDB's documentation, read in the source of DuckDB's excel extension, or inferred. An inferred
statement is measured on DuckDB v1.5.6 in slice 4: the author runs DuckDB over the committed fixtures
by hand and records each answer in the fixtures' README (see [Testing](#6-testing-with-no-real-excel)).
If a recorded answer disagrees with this document, the document is wrong and slice 4 corrects it.

## The answer

1. **What the user gets.** In SQL, `read_xlsx('book.xlsx', sheet = 'Q3', header = true, range = 'A1:D200')`
   reads one sheet of a workbook as a table, as DuckDB's `read_xlsx` does. `FROM 'book.xlsx'` does the
   same with every option left at its default. In Python, `komira.read_excel("book.xlsx",
   sheet_name="Q3", header=0, usecols="A:D", nrows=199)` gives a pandas-shaped frame. Any other argument
   is refused by name.
2. **Format scope.** komira reads `.xlsx` (and the same parts inside an `.xlsm`) and nothing else.
   `.xlsb`, `.ods` and Strict Open XML workbooks are each refused by name. `.xls` and
   password-protected workbooks are both OLE2 compound files, so they share one refusal, and its message
   names both.
3. **No foreign library.** A new Mojo `zip` library reads the container. `zlib` gains one additive
   streaming inflater. `xml` gains one additive way to feed `XmlReader` in pieces. A new Mojo `xlsx`
   library holds the workbook model, the cell rules and the row reader. `fs`, `datetime` and the Arrow
   builders are reused as they are.
4. **Memory has a known bound before any cell is read.** Every part is streamed: a fixed read window, a
   fixed inflate window, an XML window capped at one token, and, for the sheet, one batch of rows. No
   part is ever held whole. What the reader keeps from the small parts and the shared strings table has
   an upper bound computed from each part's uncompressed size in the zip directory, and the inflater
   never writes past that size. The scan reserves the sum from the query's memory reservation once, at
   open. If the reservation is denied, the query fails with a named error before the first cell is read.
   There is no watchdog and no counter that trips part-way through.
5. **Types follow DuckDB.** One row decides each column's type. Numbers are DOUBLE. Date, time and
   timestamp come from the cell's number format. Text is VARCHAR. TRUE and FALSE are BOOLEAN. A formula
   reads as its cached value, an error cell reads as its text, and a merged range keeps its value in the
   top-left cell only.
6. **Two choices go to the owner**, because they are komira's own and not DuckDB's or pandas':
   [D1](#d1-dates-that-duckdb-reads-differently-from-excel), dates that DuckDB may read differently from
   Excel, and [D2](#d2-what-the-pandas-skin-answers), what the pandas skin answers where pandas and
   DuckDB differ.
7. **Seven pull requests**, one per slice, in [Slices](#slices). The common-task page for rank 26 lands
   with the last one.

## What exists today

| Fact (main) | Where |
|---|---|
| No Excel reader in the engine, in SQL or in Python. `read_excel` is not defined: `komira.read_excel` raises Python's own `AttributeError` (`module 'komira' has no attribute 'read_excel'`) | `git grep -i 'xlsx\|read_excel'` over `src/` and `python/` finds no reader |
| `DataFrame.to_excel` is refused: `.to_excel() is pandas' own: run with materialize(), then call to_pandas().to_excel()` | `python/komira/_refusals.py` (the `FRAME` table) |
| Rank 26, "How do I read an Excel file?", is a `gap` blocked by komira-ai/komira#2336, and has no directory under `python/docs/tasks/` | `docs/tasks/catalogue.json` |
| No ZIP container reader in any language that ships. The two in the tree (`tools/build/package/wheel/zip.zig`, `tools/build/mojo/tools/archive_files.zig`) are Zig build tools, not Mojo libraries, so the new `zip` library cannot reuse them | `git grep -i 'central directory\|0x06054b50\|zip64'` |
| `zlib` inflates one whole stream into one buffer the caller sized (`zlib_inflate_into`). `zlib_inflate_once` is one `inflate` call on a fresh stream, so calling it again does not continue a stream. No state survives between calls to any public entry. The one place that loops over a single `z_stream` is the private `_zlib_skip_stream_ffi`, which does it inside one call and throws its output away. The README says: "There is no incremental streaming API" | `src/zlib/src/zlib/zlib_ffi.mojo`, `src/zlib/README.md` |
| `xml` has a strict XML 1.0 pull parser, `XmlReader`. It refuses every DTD and every entity other than the five predefined ones, and keeps a depth limit of 512 (`XML_MAX_DEPTH`). It takes the whole document as one `List[UInt8]` (`__init__`, `from_string`), validates all of it on the first `next_event`, and its events are offsets into that buffer. It scans with scalar byte loops. Outside its tests, its only caller is `parse_xml`, which every AWS and Azure client in the tree reaches | `src/xml/src/xml/xml_reader.mojo`, `src/xml/src/xml/xml_tree.mojo` |
| In-memory `FileSystem` conformers exist only as private `_MemFs` structs, each declared again inside its own parquet test file, so another package's tests cannot import one | `src/parquet/tests/test_file_reader_object_store.mojo` and two other parquet tests |
| The `FileSystem` trait reads ranges of a local file or an object (`read_at`, `read_footer`, `file_size`), with conformers for local files, S3, GCS and Azure Blob | `src/fs/file_system.mojo`, `src/objectstore_s3/s3_fs.mojo`, `src/objectstore_gcs/gcs_fs.mojo`, `src/azure_blob/azure_fs.mojo` |
| `datetime` turns a day count into a civil date and back (`civil_from_days`, `days_from_civil`); its day 0 is 1970-01-01 | `src/datetime/src/datetime/civil.mojo` |
| SQL table functions `read_parquet`, `read_csv`, `read_json`, `read_avro` and `iceberg_scan`. An unknown option is refused with `SQL not supported: <fn> option '<key>' is not implemented. It is REJECTED rather than ignored — an ignored option can change the result silently.` A `FROM '<path>'` whose extension is not `.parquet`, `.csv`, `.json`, `.jsonl` or `.ndjson` is refused | `src/sql/sql_parser.mojo` (`_parse_tvf_options`, `_refuse_option_for_kind`), `src/sql/sql_tvf_options.mojo` (`_replacement_scan_kind`) |
| A file format without a footer reaches the plan as a `WireScanBinding` with a kind name (`komira.csv`, `komira.json`, `komira.avro`) and its params, so adding a kind adds no proto field | `src/plan_proto/plan.proto` (`WireScanBinding`), `src/scan_source/scan_binding.mojo`, [optimized_plan_sources.md §15.4](optimized_plan_sources.md#154-source-kinds) |
| Python readers `read_parquet`, `read_csv` and `read_json` take a local path and `session=` as a keyword. `read_csv` asks libkomira for the binding (`komira_csv_binding`), and the engine infers the schema then | `python/komira/_frame.py`, `src/so/_c_abi.mojo` |
| JSON lines is the one reader that reads a file in chunks with a hard cap on what it carries between chunks (`MAX_JSONL_LINE_BYTES`). CSV reads the whole file | `src/jsonl/streaming_source.mojo`, `src/json_index/input_limits.mojo`, `src/csv/reader.mojo` |

## What is it for, and what is out of scope?

The goal: a user reads one sheet of an `.xlsx` workbook as a table, choosing the sheet, whether the first
row is a header, and which cell range to read. It works from SQL, from the pandas-shaped frames, and
on a workbook larger than memory.

Out of scope, each refused by name where a user could ask for it:

- **Writing a workbook.** `COPY ... TO 'x.xlsx'` and `DataFrame.to_excel` stay refused. A writer is a
  separate design.
- **Macros.** The data of an `.xlsm` is read. Its `vbaProject.bin` is never opened or run.
- **Encrypted and password-protected files.** A password-protected `.xlsx` is an OLE2 compound file, not
  a zip. A zip whose members are encrypted (flag bit 0) is refused too (`XLSX_ZIP_ENCRYPTED`).
- **Charts, chart sheets, images, drawings, comments, pivot tables, conditional formats, data
  validation, external links and Excel tables (named list objects).** None of these is read. Naming a
  chart sheet as the `sheet` is refused.
- **Evaluating formulas.** A formula cell reads as the value Excel cached when it last calculated
  ([section 4](#4-types-per-column)).
- **Display formatting.** A number read as VARCHAR is the number as written in the file, not as Excel
  displays it. Number formats are used only to tell dates and times from numbers.
- **Several sheets in one call.** pandas' `sheet_name=None` and lists are refused (section 5).
- **`.xls`, `.xlsb` and `.ods`**, see section 1.

## What the user sees

These are specified, not built:

```sql
-- One sheet, every option at its default: the first sheet, a header if the first row is all text,
-- the range found from the first row that holds data.
SELECT * FROM 'sales.xlsx';

-- The sheet named Q3, the first row always the header, cells A1 to D200 only.
SELECT region, sum(amount) FROM read_xlsx('sales.xlsx', sheet = 'Q3', header = true, range = 'A1:D200')
GROUP BY region ORDER BY region;

-- Every cell as text.
SELECT * FROM read_xlsx('sales.xlsx', all_varchar = true);
```

```python
import komira

df = komira.read_excel("sales.xlsx", sheet_name="Q3")           # header=0 is pandas' default
df = komira.read_excel("sales.xlsx", sheet_name=1, usecols="A:D", skiprows=2, nrows=100)
komira.read_excel("sales.xlsx", sheet_name=None)
# UnsupportedOperation: read_excel(sheet_name=None) reads every sheet into a dict, which komira does not:
# read each sheet with its own read_excel(path, sheet_name=...) call
```

## 1. Format scope

### Which files

| File | What it is | komira |
|---|---|---|
| `.xlsx` | Office Open XML (ECMA-376), Transitional conformance: a zip of XML parts | read |
| `.xlsm` | the same package with a macro part | read as `.xlsx`. The macro part is never opened |
| `.xlsx` saved as Strict Open XML | the same parts, under the namespaces ECMA-376 defines for Strict conformance instead of the Transitional ones | refused: `XLSX_STRICT_OOXML`. See [Decisions](#decisions-taken-here) |
| `.xlsb` | a zip of the same package shape, but with binary record parts (`xl/workbook.bin`) | refused: `XLSX_BINARY_WORKBOOK` |
| `.xls` | BIFF8 in an OLE2 compound file (magic `D0 CF 11 E0 A1 B1 1A E1`) | refused: `XLSX_COMPOUND_FILE` |
| password-protected `.xlsx` | an OLE2 compound file holding `EncryptionInfo` and `EncryptedPackage` | refused: `XLSX_COMPOUND_FILE` |
| `.ods` | OpenDocument, a different XML vocabulary | refused: `XLSX_NOT_A_WORKBOOK` (a zip with no `_rels/.rels` officeDocument relationship) |

The file is recognised by its first bytes and its parts, never by its name. A zip starts with
`PK\x03\x04`, and an OLE2 file starts with the compound-file magic. A file with neither is refused
(`XLSX_NOT_A_ZIP`). A legacy `.xls` and a
password-protected `.xlsx` look the same until the compound file's directory is read. komira does not
read that directory, so one message covers both: "an OLE2 compound file: a legacy .xls workbook or a
password-protected .xlsx; komira reads neither". DuckDB's documentation says ".xls files are not
supported" (DuckDB documentation, "Excel Extension"), so refusing `.xls` matches it.

### Which parts are read

A reader opens the zip directory first. Then it reads these parts, in this order, and no others:

| Part | Why | If missing |
|---|---|---|
| `_rels/.rels` | the `officeDocument` relationship names the workbook part (usually `xl/workbook.xml`) | `XLSX_NOT_A_WORKBOOK` |
| the workbook part | `<sheets>`: each sheet's `name`, `r:id` and `state`. `<workbookPr date1904=...>`: the date system | `XLSX_PART_MISSING` |
| the workbook's rels (`xl/_rels/workbook.xml.rels`) | maps each sheet's `r:id` to its part, and gives the relationship type (worksheet or chartsheet). The shared strings and styles parts are found here too | `XLSX_PART_MISSING` |
| the styles part (`xl/styles.xml`) | `<numFmts>` and `<cellXfs>`: which style indexes are dates or times | optional: every cell is then a plain number or text |
| the shared strings part (`xl/sharedStrings.xml`) | the strings that `t="s"` cells index | optional: a `t="s"` cell then fails with `XLSX_SHARED_STRING_INDEX` |
| the chosen worksheet part | `<sheetData>`, streamed | `XLSX_PART_MISSING` |

`[Content_Types].xml` is not read. Every part is found through relationships, and their types say what
each part is. A relationship target is resolved against its source part's folder, or taken from the
package root if it starts with `/`. Part names are compared case-insensitively, as Open Packaging
Conventions part names are. The sheet number in a file name such as `sheet3.xml` means nothing: the
relationship decides.

### How a date is recognised

The cell XML has no date type in Transitional files. A date is a number whose style has a date number
format:

1. The cell's `s` attribute indexes `<cellXfs>` in the styles part. A missing `s` means style 0.
2. That `<xf>`'s `numFmtId` is either a built-in format id or the id of a `<numFmt formatCode=...>` in
   `<numFmts>`.
3. Built-in ids 14 to 22 and 45 to 47 are date and time formats (ECMA-376 Part 1, §18.8.30). The
   locale-dependent ids 27 to 36 and 50 to 58 are dates in East Asian locales. The slice that builds the
   style table checks these ranges against the standard's text before it relies on them, and cites the
   clause it checked.
4. A custom format code is scanned for date and time tokens after quoted text (`"..."`), escaped
   characters (`\x`) and bracketed sections are removed. The tokens are `y`, `m`, `d`, `h`, `s` and
   `AM/PM`. Elapsed-time brackets `[h]`, `[m]` and `[s]` count as time tokens. A colour or condition
   bracket such as `[Red]` or `[<0]` does not count. An `m` is a month unless it follows an `h` or
   comes before an `s`, in which case it is minutes.
5. A format with date tokens only is a DATE. Time tokens only make a TIME. Both make a TIMESTAMP.
   DuckDB's documentation says only that "TIMESTAMP, TIME, DATE, and BOOLEAN types are inferred when
   possible based on the format applied to the cell". The split above and the token scan in step 4 are
   inferred, and slice 4 measures them.

A cell with `t="d"` holds an ISO 8601 date-time as text. Excel does not write it to Transitional files,
but other writers do. It reads as a DATE when it has no time part, and as a TIMESTAMP when it has one.

**The serial number.** A date cell's value is a count of days, with the time of day as the fraction.
With `days` the whole part and day 0 being 1970-01-01 (as in `datetime`):

The rows below cover every real serial `s`. `floor(s)` is the day, and `s - floor(s)` is the time of
day.

| Date system | Serial `s` | What Excel shows | Day, counted from 1970-01-01 |
|---|---|---|---|
| 1900 (the default) | `61 <= s` | the date | `floor(s) - 25569` (the epoch is 1899-12-30) |
| 1900 | `60 <= s < 61` | 1900-02-29, a day that does not exist: Lotus 1-2-3 counted 1900 as a leap year, and Excel kept that for compatibility | none |
| 1900 | `1 <= s < 60` | the date | `floor(s) - 25568` (Excel counts 1900-01-01 as day 1, so the epoch here is 1899-12-31) |
| 1900 | `0 <= s < 1` | a time of day, with the date shown as 1900-01-00 | none: a TIME format reads it as a time, and a date format has no date to give |
| 1904 (`date1904="1"`) | `0 <= s` | the date | `floor(s) - 24107` (the epoch is 1904-01-01). The two systems are 1462 days apart |
| either | `s < 0`, or a day after 9999-12-31 | no date | none |

DuckDB's rule, read in duckdb-excel's `src/excel/xlsx/read_xlsx.cpp`: `ExcelToEpochUS` multiplies the
serial by 86,400 to get seconds, and rounds to the whole second when it is within 1e-3 of one. It
subtracts `DAYS_BETWEEN_1900_AND_1970 = 25569` days, converts to microseconds, and clamps to the
`int64` range. Nothing in the files read handles `date1904` or serials below 61. If that holds,
DuckDB gives the 1900 row `61 <= s` everywhere. Serial 60 then reads as 1900-02-28, serial 59 as
1900-02-27 where Excel shows 1900-02-28, and every date of a 1904 workbook comes out 1462 days early.
That DuckDB has no other code for these cases is inferred. Slice 4 measures it on the `dates_1900` and
`dates_1904` fixtures. What komira does with those cells is owner decision
[D1](#d1-dates-that-duckdb-reads-differently-from-excel).

## 2. Library: what is reused and what is new

| Piece | Reused or new | Package |
|---|---|---|
| Reading byte ranges of a local file or an object | reused: `FileSystem.read_footer`, `read_at`, `file_size` | `fs` and its cloud conformers |
| Raw deflate | reused: `zlib_inflate_into(..., ZLIB_WINDOW_BITS_RAW)` for `zip`'s whole-member read (`xlsx` streams every part instead), and `zlib_crc32` | `zlib` |
| Streaming raw deflate | **new, additive**: `ZlibInflater`, a struct that owns one `z_stream` across calls (`init`, `step(src, dst) -> (read, written, done)`, freed when it is destroyed). Its public API takes `Span`s and holds no pointer. The FFI stays in `zlib_ffi.mojo` with the `# FFI-BOUNDARY:` note rule M9 asks for | `zlib` |
| The zip container | **new**: `zip`, which reads only. It covers the end-of-central-directory record (found in the last 65,557 bytes), the zip64 locator and record, the central directory, the local-header check, stored (method 0) and deflate (method 8) members, data descriptors (flag bit 3: sizes come from the central directory), and a CRC-32 and size check on every member. A member can be read whole into a buffer of its declared size, or streamed through `ZlibInflater` | `zip` (new) |
| XML tokens | reused: `XmlReader`'s strictness (UTF-8, characters, the DTD refusal, the five entities) and its events | `xml` |
| Feeding XML in pieces | **new, additive**: `XmlReader` gets a constructor over a byte source. The reader keeps a window and refills it, offsets become window-relative with a base, the UTF-8 check runs per piece with the trailing bytes of a split sequence carried over, and a token cut by the window edge is completed by refilling before its event is returned. The open-element stack keeps its own copy of each name, so compacting the window cannot invalidate it. A token longer than the cap the caller passes is refused (`xml: token longer than <cap> bytes`). The existing whole-buffer constructors become the one-piece case with no cap, so `parse_xml` and every caller keep the same code path, and the existing tests keep holding it | `xml` |
| Day counts to dates | reused: `civil_from_days`, `days_from_civil` | `datetime` |
| Columns and batches | reused: the Arrow builders (`FLOAT64`, `STRING`, `BOOL`, `DATE32`, `TIME64_US`, `TIMESTAMP_US`) | `arrow` |
| Workbook model, styles, shared strings, cell references and ranges, date rules, header and range detection, type inference, the row reader | **new** | `xlsx` (new) |
| The SQL table function, the replacement scan and the `komira.xlsx` scan kind | **new arms** in existing code | `sql`, `scan_source`, `dispatch_scan` |
| The libkomira describe call `komira_xlsx_binding` and Python `read_excel` | **new**, shaped like `komira_csv_binding` and `read_csv` | `so`, `python/komira` |

**Why not a foreign library.** Readers exist in C, C++ and Rust (calamine is one). We do not bind one,
for four reasons:

- **They read files, not `FileSystem`.** They would read a local path, or the whole file from memory.
  komira's scans read local files and object stores through one trait. A foreign reader would need the
  whole object downloaded first, which is the memory problem this design exists to avoid.
- **Their types are not DuckDB's.** Section 4's rules (one inference row, DOUBLE for numbers, dates from
  formats, errors as text) would have to be re-derived from each library's cell model, and a library
  upgrade could change an answer without warning. B21 asks for the same result as DuckDB.
- **Native code adds risk.** It needs a new conda-forge native dependency per platform, an FFI surface
  that hands back pointers (rules M1, M9), and a C or Rust XML and zip stack whose memory use and
  refusals (DTDs, entity expansion, zip bombs) are its own.
- **Most of the work is already in the tree.** komira has strict XML, inflate, CRC-32 and range reads.
  What is missing is a small zip reader and two additive streaming entries, all in Mojo, all at 99%
  coverage and tested in the tree.

The cost of this choice is that `XmlReader` scans with scalar byte loops (What exists today). How fast
a large sheet reads has not been measured. The slice that streams the sheet measures it, with a sheet the
test writer generates, and records the figure in the `xlsx` README. That figure is a measurement in a
document, not a test bound (rule T10).

## 3. Streaming: a sheet larger than memory

### The path of one sheet

```
FileSystem.read_footer ─► zip directory (EOCD, zip64, central directory)
each part: FileSystem.read_at in fixed chunks ─► ZlibInflater (stops at the declared size) ─► XmlReader (window)
  workbook, rels, styles ─► the few facts kept (sheet list, relationships, date flags per style)
  shared strings          ─► the strings table
  the sheet               ─► row reader ─► column builders ─► RecordBatch every N rows
```

No part is ever inflated whole into one buffer.

A worksheet part is one deflate stream, and deflate cannot be split, so one sheet decodes on one worker.
The scan reports one partition. Operators above the scan still run in parallel on its batches.

### Every buffer and its bound

| Buffer | Bound | Why it holds |
|---|---|---|
| The zip directory | the central directory's size, from the end record | read once, and its entries are parsed into a list of parts. A workbook has tens of parts |
| Read chunk | a fixed constant, `XLSX_READ_CHUNK_BYTES` | each `read_at` asks for at most that many bytes |
| Inflate output window | a fixed constant, `XLSX_INFLATE_WINDOW_BYTES` | `ZlibInflater.step` writes into it and the XML reader drains it |
| XML window | at most `XLSX_XML_TOKEN_CAP_BYTES` (1 MiB), plus one inflate window | the window holds the token being read and is compacted after each event. A longer token is refused (`XLSX_TOKEN_TOO_LONG`). The cap is set above the longest token Excel writes. Microsoft's "Excel specifications and limits" give 32,767 characters per cell, which is at most 32,767 UTF-16 units. A unit costs at most 10 bytes in the file (`&#x10FFFF;` stands for two units, and `_xHHHH_` for one in 7 bytes), so a cell's text token is at most 327,670 bytes, and its tags add a few dozen. Another writer can exceed Excel's limit, and its file is then refused by name |
| One batch | `morsel_rows` rows × the columns of the range | at most 16,384 columns (`XFD`). A cell reference past `XFD1048576` is refused (`XLSX_CELL_REFERENCE_INVALID`) |
| Styles | one flag per `<xf>`, `8 × U_styles / 5` bytes at most | the part is streamed. A flag is kept for each `<xf>`, and the shortest `<xf/>` is 5 bytes, so there are at most `U_styles / 5` of them. A custom format's code is classified as it is read and not kept |
| Workbook | `U_workbook` bytes at most | the part is streamed. Only each sheet's name, `r:id` and state are kept, and they are shorter than the part |
| Workbook rels | `U_rels` bytes at most | the same, for each relationship's id, type and target |
| Shared strings | `U + 8 × U / 5` bytes at most (below) | held, because a `t="s"` cell may index any string at any row |

`U_x` is part x's uncompressed size in the zip directory. The window sizes are compile-time parameters
of the reader with these defaults, not settings. Tests instantiate the reader with small windows to put
every buffer edge inside a token ([section 6](#6-testing-with-no-real-excel)).

### The shared strings table, bounded by construction

The table is one byte buffer of decoded text plus one `Int64` end offset per string. Both have an upper
bound that is known from the zip directory before the part is read:

- **The text is never longer than the part.** Decoding only shrinks text. `&amp;` (5 bytes) becomes 1
  byte. `&#x10FFFF;` (10 bytes) becomes 4. `_xHHHH_` (7 bytes) becomes at most 3. Markup and `<rPh>`
  text are dropped. So the text bytes are at most `U`, the part's uncompressed size in the central
  directory.
- **There are at most `U / 5` strings.** The shortest string element is `<si/>`, which is 5 bytes. So
  the offsets take at most `8 × U / 5` bytes.
- **The bound holds even when the file lies.** The inflater counts what it writes and stops at `U`. A
  stream that wants to write more is refused (`XLSX_ZIP_CORRUPT`, "member inflates past its declared
  size"), and so is one that ends short or fails its CRC-32. A small file that inflates to a huge part
  (a zip bomb) therefore costs at most the size it declares.

The part is streamed through the windowed `XmlReader` like the sheet, so the table is the only thing
that grows while it is read, and it never passes the bound.

When the scan opens, it reserves the sum of the bounds in the table above, styles, workbook, rels and
shared strings, from the query's memory reservation
([lowering_and_pipeline.md](lowering_and_pipeline.md), the root reservation and `try_grow`). If that is
denied, the query fails before any part is read, with `XLSX_PARTS_OVER_BUDGET`, naming each part's `U`
and the bytes asked for. This is a single check when the scan opens. Nothing watches memory while the
workbook is read, because nothing grows past what was reserved: each kept structure has its bound, the
table is complete before the first row is read, and every other buffer has a fixed size.

`<sst count= uniqueCount=>` is not trusted for sizing. A `t="s"` index at or past the number of strings
actually read is refused (`XLSX_SHARED_STRING_INDEX`).

### Binding reads a prefix, the scan reads the rest

The schema is needed when the query is bound, as it is for CSV (`komira_csv_binding`). At bind time,
the binder opens the zip directory and streams the workbook, rels and styles parts. Then it streams
the sheet until the inference row has been read, and stops. If the header or the inference row holds
`t="s"` cells, it streams the shared strings part and keeps only the strings those cells index. That is
at most 32,768 strings (two rows of 16,384 columns), and never more bytes than the part itself (`U`).
So binding builds no whole table. It holds at most what the scan's table would hold, and usually far
less. Binding takes no reservation of its own. The binding records the sheet's part name, its
CRC-32 and its sizes from the central directory, the file's modification time (as CSV's pin does), and
the resolved range and header. When the scan opens, it checks the CRC-32 and sizes again. A workbook
that changed between bind and scan is refused (`XLSX_CHANGED_SINCE_BIND`) rather than read under the
wrong schema.

### Object stores

A remote workbook is read by the same code through its `FileSystem`. That means one suffix read for the
end record and the directory (one `read_footer`, with a second exact read if the directory does not fit
in the window, as Parquet's footer reader does), one `read_at` per small part, and sequential
fixed-size `read_at`s for the sheet. No object is downloaded whole.

## 4. Types per column

### The cell kinds

| Cell XML | What it reads as | DuckDB (source of the statement) |
|---|---|---|
| `t` absent or `t="n"`, `<v>` a number, style not a date | DOUBLE | duckdb-excel `GetDuckDBType`: a number with no date format is "Default to double" |
| the same, style a date, time or timestamp format | DATE, TIME or TIMESTAMP (section 1) | the DuckDB documentation's sentence on formats |
| `t="s"` | VARCHAR, the shared string | `SHARED_STRING` maps to VARCHAR |
| `t="inlineStr"`, `<is>` | VARCHAR, the concatenated `<t>` text | `INLINE_STRING` maps to VARCHAR |
| `t="str"` (a formula's string result) | VARCHAR | `FORMULA_STRING` maps to VARCHAR |
| `t="b"`, `<v>` 0 or 1 | BOOLEAN | `BOOLEAN` maps to BOOLEAN |
| any text cell whose text is `true` or `false`, in any case | BOOLEAN | `GetDuckDBType` checks the data case-insensitively for every cell type |
| `t="e"`, `<v>` such as `#DIV/0!` or `#N/A` | VARCHAR, the error's text | `ERROR` maps to VARCHAR |
| `t="d"`, ISO 8601 text | DATE or TIMESTAMP | `DATE` maps to DATE (the TIMESTAMP case is inferred) |
| `<f>` with a cached `<v>` | the cached value, typed by the rows above | the worksheet parser reads text only inside `<v>` and `<t>`, so the formula is ignored |
| `<f>` with no `<v>` | NULL | inferred: an empty cell |
| no element for the cell, or an element with no value | NULL | an empty non-string cell becomes NULL |

Strings: an `<si>` or `<is>` is the concatenation of its `<t>` elements in order, rich-text runs
included, with phonetic runs (`<rPh>`) left out. `_xHHHH_` is decoded to the UTF-16 code unit `HHHH`
(as ECMA-376 escapes characters XML cannot carry), and `_x005F_` stands for `_`. A high surrogate
escape followed directly by a low one (`_xD83D__xDE00_`) is one character. A lone surrogate has no
UTF-8 form, and Arrow strings are UTF-8, so it is refused by name (`XLSX_INVALID_ESCAPE`, naming the
string's index). Whitespace is kept as written, whether or not `xml:space="preserve"` is present.

### Inference

DuckDB decides each column's type from one row, the first data row: the row after the header if there
is one, otherwise the first row of the range (DuckDB documentation, "Excel Extension"). komira does the
same:

- **Mixed cells.** A column is the type of its cell in the inference row. A later cell of another kind
  is converted to that type, from its text in the file (`<v>`, or the string). If it does not convert,
  the query fails with `XLSX_CELL_CAST`, naming the cell (for example `B7`) and the target type, as
  DuckDB's `read_xlsx: Failed to parse cell '%s'` does. With `ignore_errors = true` the cell is NULL
  instead. A number in a VARCHAR column is its text as written in the file, for example `0.1`. That it
  is the text as written, and not a reformatted double, is inferred from DuckDB keeping each cell's raw
  text and casting it.
- **Empty cells.** An empty cell in the inference row makes the column DOUBLE, or VARCHAR with
  `empty_as_varchar = true`. An empty cell anywhere is NULL.
- **Booleans** come from `t="b"` cells and from text cells reading `true` or `false`.
- **Formulas** are never evaluated. A workbook written by a program that does not calculate (no `<v>`)
  reads its formula cells as NULL. Excel writes the cached values.
- **Errors** are VARCHAR text in a VARCHAR column. In a DOUBLE or date column they do not convert, so
  they fail or are NULL under `ignore_errors`.
- **`all_varchar = true`** skips inference, and every cell is its text. For a date cell that is the
  serial number as written, which is inferred and measured in slice 4.

### Where the rows and columns come from

- **Header.** With `header` not given, the first row is a header only when every one of its cells is a
  non-empty string (`t="s"` or `t="inlineStr"`). This is DuckDB's header sniffer
  (duckdb-excel, `src/excel/include/xlsx/parsers/worksheet_parser.hpp`). `header = true` and `false`
  force it. Header names are the cells' text. Repeats are renamed as DuckDB renames them
  (`QueryResult::DeduplicateColumns`, [query_semantics.md](query_semantics.md)). With no header, the
  names come from the cell positions of the range's first row, through DuckDB's `XLSXCellPos::ToString()`
  or `GetColumnName()` (read in `read_xlsx.cpp` and `worksheet_parser.hpp`). Those functions' bodies
  were not in the files read, so whether a name looks like `A` or `A1` is measured in slice 4. With no
  header and no range, when no row is found, DuckDB fails with "No rows found in xlsx file", and so does
  komira (`XLSX_NO_ROWS`).
- **Range.** With `range` not given, the range starts at the first row that holds data. It spans from
  that row's first non-empty cell to the cell before its first gap, and runs down to the end of the
  sheet (the same header file). `stop_at_empty` defaults to true then, so the first empty row ends the
  table. With a range given, `stop_at_empty` defaults to false. Empty rows inside the range are then
  rows of NULLs, and the range is padded with empty rows up to its last row.
- **Sparse rows and cells.** A row's `r` and a cell's `r` are optional. A missing row `r` is the
  previous row plus one, and a missing cell `r` is the previous column plus one. Missing cells are NULL.
- **Order.** Streaming relies on rows ascending and cells ascending within a row, which is how Excel
  and every writer we know write them. A row or cell that goes backwards is refused
  (`XLSX_CELL_REFERENCE_INVALID`), never re-sorted in memory. See [Decisions](#decisions-taken-here).
- **The `<dimension>` element** is not used. It is optional, and writers get it wrong.

### Merged cells and hidden things

- **Merged cells.** Excel stores a merged range's value in its top-left cell only, and `<mergeCells>`
  comes after `<sheetData>`, so a streaming reader learns of the merge only after the rows have gone.
  komira reads the stored cells: the top-left cell has the value, and the others are NULL. DuckDB's
  reader has no merge handling in the files read, and pandas' openpyxl engine also gives None for
  those cells. The merge list is never read.
- **Hidden and very hidden sheets** are read when named. With `sheet` not given, the sheet read is the
  first worksheet in workbook order, whatever its state. That is DuckDB's rule in `read_xlsx.cpp`: it
  keeps only relationships whose type ends in `/worksheet`, and the first sheet in `<sheets>` that
  matches one becomes the primary sheet. The code read checks no `state`, so a hidden first sheet is
  inferred to be the default, and slice 4 measures it on the `hidden` fixture.
- **Hidden rows and columns** are ordinary rows and columns. Being hidden is only a display flag.
- **A chart sheet or dialog sheet** is not a worksheet. It is skipped when the default sheet is chosen
  and is not counted by position. Naming one as `sheet` fails as an unknown name does, since DuckDB's
  map holds worksheets only, but komira's message says it is a chart sheet (`XLSX_NOT_A_WORKSHEET`).

### Arrow types

| DuckDB type | Arrow type in komira |
|---|---|
| DOUBLE | `FLOAT64` |
| VARCHAR | `STRING` |
| BOOLEAN | `BOOL` |
| DATE | `DATE32` |
| TIME | `TIME64_US` |
| TIMESTAMP | `TIMESTAMP_US`, no time zone |

A timestamp or time is converted as DuckDB's `ExcelToEpochUS` does (section 1). The serial is turned
into seconds and rounded to the whole second when it is within 1e-3 of one. Then the epoch is taken
off, and the result is in microseconds, truncated toward zero by the conversion to an integer. A DATE
is the day of that timestamp. Slice 4 checks both against DuckDB on the `dates_1900` fixture.

## 5. The SQL and Python surfaces

### SQL: `read_xlsx`

`read_xlsx(path, ...)` mirrors DuckDB's, whose parameters are listed on the "Excel Extension" page of
DuckDB's documentation. It holds the same seven parameters for DuckDB 1.5 and 2.0. komira's reference is
DuckDB v1.5.6 ([query_semantics.md](query_semantics.md)).

| Parameter | Type, DuckDB's default | komira |
|---|---|---|
| `sheet` | VARCHAR, the first sheet | supported. An unknown name fails with `XLSX_SHEET_NOT_FOUND`, which lists the sheet names |
| `header` | BOOLEAN, inferred | supported (section 4) |
| `all_varchar` | BOOLEAN, false | supported |
| `ignore_errors` | BOOLEAN, false | supported |
| `range` | VARCHAR, inferred | supported in the form `<col><row>:<col><row>`, such as `A1:D200`. Another form is refused (`XLSX_RANGE_INVALID`) until slice 4 records which other forms DuckDB accepts |
| `stop_at_empty` | BOOLEAN, false with a range, true without | supported |
| `empty_as_varchar` | BOOLEAN, false | supported |
| any other name | — | refused with the table functions' existing message, `SQL not supported: read_xlsx option '<key>' is not implemented. It is REJECTED rather than ignored ...`. That includes `normalize_names`, which duckdb-excel's source has but DuckDB 1.5's documentation does not list |

`FROM 'x.xlsx'` maps to `read_xlsx` with every option at its default. DuckDB's documentation reads a
`.xlsx` the same way ("Reading a .xlsx file is as simple as just SELECTing from it"). Only the `.xlsx`
extension maps: `FROM 'x.xlsm'` keeps today's refusal, which tells the user to spell the reader. The
path is a string literal, as for the other table functions. DuckDB's excel extension also needs no
`LOAD` when it is autoloaded, and komira has nothing to load.

The plan carries a `WireScanBinding` of kind `komira.xlsx`, whose params are `path`, `sheet` (the
resolved part name and the sheet name), `range` (resolved), `header`, `all_varchar`, `ignore_errors`,
`stop_at_empty` and `empty_as_varchar`, plus the schema and the pin (section 3). Its descriptor is
committed as data beside the kind ([optimized_plan_sources.md §15.4.6](optimized_plan_sources.md#1546-kind-descriptors-are-published-data)).
The orientation is row, the snapshot policy is pinned, and no filter or projection is pushed into the
reader in the first slices.

### Python: `komira.read_excel`

```python
komira.read_excel(io, sheet_name=0, *, header=0, usecols=None, nrows=None, skiprows=None, dtype=None, session=None)
```

It mirrors `pandas.read_excel` (pandas' reference page for `read_excel`), shaped like the other readers:
a local path, `session` as a keyword, and the schema found by the engine when the reader is called
([dataframe_surface.md §4](dataframe_surface.md#4-readers-sessions-and-in-memory-data)).

| pandas argument | komira | maps to |
|---|---|---|
| `io` | a local path (`str` or `os.PathLike`). A file object, bytes or URL is refused, as the other readers refuse them | `path` |
| `sheet_name` | a `str` is the sheet's name. An `int` is its 0-based position among worksheets, hidden sheets included and chart sheets not counted, as pandas counts. `None` and lists are refused (they return a dict) | `sheet` |
| `header` | `0` means the first row left after `skiprows` is the header, and `None` means there is none. An `int` `k > 0` means the `k`-th row after the skipped ones (counting from 0) is the header, and the rows between are dropped. A list (a column MultiIndex) is refused | `header`, and the range's first row |
| `usecols` | a string of one column span such as `"A:D"`, or one letter: those become the range's columns. A list of names or of 0-based positions becomes a projection above the scan, since no projection is pushed into the reader in these slices. A string of several spans (`"A,C:D"`) and a callable are refused | the range's columns, or a projection |
| `skiprows` | an `int`: that many rows are skipped at the top of the area. A list or a callable is refused | the range's first row |
| `nrows` | an `int`: at most that many data rows after the header | the range's last row |
| `dtype` | `str` reads every cell as text. A dict, `object` (in pandas it keeps each cell's value as stored, which a typed column cannot hold) and any other type are refused: cast after reading with `astype` | `all_varchar` |
| `names`, `index_col`, `engine` (other than `None`), `converters`, `true_values`, `false_values`, `na_values`, `keep_default_na`, `na_filter`, `verbose`, `parse_dates`, `date_format`, `thousands`, `decimal`, `comment`, `skipfooter`, `storage_options`, `dtype_backend`, `engine_kwargs` | refused by name, `UnsupportedOperation: read_excel(<arg>=...) is not supported by komira`, with what to do instead where there is something | — |

**How the row arguments combine.** pandas applies `skiprows` first, then `header`, then `nrows`. Let
`F` be the area's first row in sheet numbering (D2 says where the area starts). Then:

- With `header=k`, the header is row `F + skiprows + k`. Data starts on the row after it, and its last
  row is the header row plus `nrows`.
- With `header=None`, data starts on row `F + skiprows`, and its last row is that row plus `nrows - 1`.

In the first example of [What the user sees](#what-the-user-sees), with `F = 1`, `header=0` and
`nrows=199`, that is rows 1 to 200. The slice checks every combination against pandas on the fixtures.

The pandas skin always passes `header` to the engine as `true` or `false`, never leaving it to DuckDB's
sniffing, because pandas' default is a header in row 0. `ignore_errors`, `empty_as_varchar` and
`stop_at_empty` have no pandas spelling. Python does not expose them. The skin sets them itself where
D2 says it must. Where the pandas answer and the engine's answer differ (pandas reads whole numbers as
`int64` and dates as `datetime64`, and keeps empty rows inside the area), the skin either builds pandas'
answer or lists a departure. Which one is owner decision [D2](#d2-what-the-pandas-skin-answers).

The polars skin gets no Excel reader in these slices. polars' `read_excel` is eager and needs a
third-party engine, and `komira.pl` has only lazy `scan_*` readers. Today `kpl.read_excel` raises the
plain `AttributeError`, because the polars skin's refusal table (`python/komira/pl/_names.py`) has no
entry for it. Slice 7 adds one there, worded like the eager readers' entries and naming the pandas
skin's `komira.read_excel`.

### Errors

Every refusal has a token and a message naming what was found. SQL and Python show the same text: SQL
through the engine's error, Python as `UnsupportedOperation` for an argument it refuses and as the
engine's error for a file.

| Token | When |
|---|---|
| `XLSX_NOT_A_ZIP` | the file starts with neither the zip nor the OLE2 magic (a text file named `.xlsx`, say) |
| `XLSX_COMPOUND_FILE` | an OLE2 compound file: a legacy `.xls` or a password-protected `.xlsx` |
| `XLSX_ZIP_CORRUPT` | no end record; a directory, zip64 record or local header that disagrees with another; a member that ends short, inflates past its declared size, or fails its CRC-32 |
| `XLSX_ZIP_ENCRYPTED` | a member with the encryption flag (bit 0) |
| `XLSX_ZIP_METHOD_UNSUPPORTED` | a member compressed with a method other than stored (0) or deflate (8) |
| `XLSX_NOT_A_WORKBOOK` | a zip with no `officeDocument` relationship in `_rels/.rels` (an `.ods`, say) |
| `XLSX_BINARY_WORKBOOK` | the workbook part is `.bin` (an `.xlsb`) |
| `XLSX_STRICT_OOXML` | the workbook uses the Strict namespaces |
| `XLSX_PART_MISSING` | a relationship names a part the zip does not hold, or a required part is absent |
| `XLSX_SHEET_NOT_FOUND` | `sheet` (or `sheet_name`) names no sheet, or its position is past the last worksheet. The message lists the worksheet names |
| `XLSX_NOT_A_WORKSHEET` | `sheet` names a chart sheet or dialog sheet |
| `XLSX_RANGE_INVALID` | a `range` value not of the form `<col><row>:<col><row>`, or with its end before its start |
| `XLSX_NO_ROWS` | no row holds data and no range was given |
| `XLSX_CELL_REFERENCE_INVALID` | a malformed cell reference, one past `XFD1048576`, or a row or cell that goes backwards |
| `XLSX_SHARED_STRING_INDEX` | a `t="s"` index past the strings read, or a `t="s"` cell with no shared strings part |
| `XLSX_INVALID_ESCAPE` | an `_xHHHH_` lone surrogate |
| `XLSX_TOKEN_TOO_LONG` | an XML token longer than `XLSX_XML_TOKEN_CAP_BYTES` |
| `XLSX_PARTS_OVER_BUDGET` | the query's memory reservation denies the bound of section 3 |
| `XLSX_CELL_CAST` | a cell that does not convert to its column's type, without `ignore_errors` |
| `XLSX_CHANGED_SINCE_BIND` | the sheet part's CRC-32 or sizes differ from the binding's |
| `XLSX_DATE_DIFFERS_FROM_DUCKDB` | only if D1 is decided as A |

An XML error from `XmlReader` (bad UTF-8, a DTD, a mismatched tag) keeps its own `xml:` message, with the
part's name in front.

### What komira would invent

Three things here are komira's own, neither DuckDB's nor pandas':

- the error tokens (`XLSX_*`), which follow the tree's existing refusal style;
- the treatment of dates DuckDB reads differently from Excel (D1);
- the pandas skin's departures (D2).

The owner decides D1 and D2. Everything else mirrors DuckDB or pandas, or refuses.

## 6. Testing with no real Excel

No test runs Excel, LibreOffice or DuckDB. The Mojo tests run no Python. The Python tests belong to the
Python SDK, which rule T11 allows, and they make their workbooks with Python's standard `zipfile`.
Workbooks reach the Mojo tests in two ways.

### A tiny writer, used only in tests

Two Mojo libraries hold the test writers. Neither has a release package, and only test targets can see
them.

- `zip_testing` (slice 1) writes a zip archive into a buffer, with stored or deflated members, data
  descriptors, zip64 records, and a member whose declared size or CRC-32 is wrong. It also holds a
  `FileSystem` conformer over buffers in memory.
- `xlsx_testing` (slice 4) builds on `zip_testing` and writes a workbook:
  - **Parts:** the workbook, rels, styles and shared strings parts and any number of sheets, written
    with `XmlWriter`.
  - **Members:** each one stored or deflated, through `zip_testing`.
  - **Its options are exactly the cases sections 1 and 4 list:** shared or inline strings, number
    formats (built-in and custom), `date1904`, sheet states, chart sheets, formulas with and without
    cached values, error cells, rich text and phonetic runs, `_xHHHH_` escapes and surrogates, rows and
    cells without `r` or out of order, merged ranges, Strict namespaces, and an `.xlsb`-shaped package.

A test writes into its scratch directory from `test_tmpdir()`, or reads the buffer through
`zip_testing`'s in-memory `FileSystem`. A generated sheet of any length is how the streaming and bound
tests get a large input without committing one.

The writer and the reader are both ours, so a misreading of the standard shared by both would pass.
The fixtures below guard against that.

### Small workbooks checked in

`src/xlsx/tests/fixtures/` holds a few workbooks of a few KiB each, written by LibreOffice Calc, an
open-source program that runs headless. Each fixture's source is committed beside it as a flat
OpenDocument file (`.fods`, plain XML). Its README table names each file, the LibreOffice version, the
one conversion command, what the workbook holds, and the DuckDB v1.5.6 result of `SELECT *` over it
with the excel extension, plus each other query section 4 says is measured. An author runs that
command and those queries by hand when a fixture is added, and records the results in the README. No
target runs them, so no target depends on LibreOffice, DuckDB or Python (rule B5). This follows the
committed-fixture convention of `src/arrow_ipc/tests/fixtures/arrow_ipc/README.md`. `test_xlsx_fixtures`
takes its expected values from that record and from the fixture's source, written out by hand, never
read off komira's own decode.

| Fixture | Holds | Proves |
|---|---|---|
| `basic.xlsx` | header, text, numbers, an empty cell | header sniffing, DOUBLE and VARCHAR, NULL for an empty cell, a real producer's zip and parts |
| `dates_1900.xlsx` | dates, times, timestamps, serials 1, 59, 60 and 61, a fractional second | date formats, the serial rule, the leap-year cases (D1), rounding |
| `dates_1904.xlsx` | the same dates in the 1904 system | `date1904` (D1) |
| `formulas.xlsx` | numeric, string and error formulas, and a boolean | cached values, `t="str"`, `t="e"`, `t="b"` |
| `hidden.xlsx` | a hidden first sheet, a visible second, a chart sheet | the default sheet, `sheet=` by name, the chart-sheet refusal |
| `merged.xlsx` | a merged header and merged data cells | top-left only |
| `sparse.xlsx` | gaps in rows and columns, a range far from `A1` | range sniffing, `stop_at_empty`, padding |

### What each test proves

| Package | Test | Behaviour |
|---|---|---|
| `zlib` | `test_zlib_inflater` | A raw deflate stream inflated through a window of 1, 7 and 4,096 bytes gives the same bytes as `zlib_inflate_into`. Input cut at every byte gives the same result. A truncated or corrupt stream is refused, and `done` is reported once |
| `xml` | `test_xml_reader_pieces` | Every document of the existing `xml` tests, fed in pieces of every size from 1 byte up, gives the same events and the same refusals as the whole-buffer reader. That includes a split inside a UTF-8 sequence, a CRLF, an entity, `]]>`, a comment and an attribute value, and a token over the cap |
| `zip` | `test_zip_directory`, `test_zip_members`, `test_zip_refusals` | The end record found under a comment of 0 and 65,535 bytes. zip64 sizes and offsets. Data descriptors. Stored and deflate members read whole (slice 1) and streamed (added in slice 2). Refused by name: a CRC mismatch, a size mismatch, a member that inflates past its size, a local header that disagrees with the directory and no end record (`XLSX_ZIP_CORRUPT`), encryption (`XLSX_ZIP_ENCRYPTED`), a method other than 0 and 8 (`XLSX_ZIP_METHOD_UNSUPPORTED`), an OLE2 file (`XLSX_COMPOUND_FILE`) and a file with neither magic (`XLSX_NOT_A_ZIP`) |
| `xlsx` | `test_xlsx_workbook` | Relationships resolved relatively and absolutely, sheets by name and position, states, chart sheets refused, missing parts named, Strict OOXML and `.xlsb` refused |
| `xlsx` | `test_xlsx_styles_dates` | Each built-in date id and its neighbours that are not dates. Custom codes with quotes, escapes, colour brackets, elapsed time and `m` as minutes. Both date systems at every boundary in the section 1 table |
| `xlsx` | `test_xlsx_shared_strings` | Rich text, phonetic runs left out, `_xHHHH_` and `_x005F_`, a surrogate pair joined and a lone surrogate refused, whitespace kept, an index past the end refused. The reservation asked for equals the sum of section 3's bounds, and a denied reservation fails with `XLSX_PARTS_OVER_BUDGET` before any part is read. A part that inflates past its declared size is refused |
| `xlsx` | `test_xlsx_cells` | Every row of the cell-kind table, the mixed, empty and `ignore_errors` cases, and `all_varchar` |
| `xlsx` | `test_xlsx_range_header` | Header sniffing, forced headers, repeated names, names with no header, the range forms, `stop_at_empty` both ways, padding, and rows and cells without `r` or out of order |
| `xlsx` | `test_xlsx_streaming_bound` | A generated sheet of 200,000 rows read with small windows, the reader instantiated with small window parameters. The reader keeps an `XlsxBufferPeaks` value, the largest size each of its buffers reached, which the reader's tests read. The test asserts each peak is never greater than its configured window, whatever the row count, and that the rows equal the generated ones. It measures sizes, never time |
| `xlsx` | `test_xlsx_fixtures` | Slice 4: each fixture's sheets, states and date flags per style are those its README records. Slice 5 extends it: each fixture gives the rows its README records |
| `sql` | `test_sql_read_xlsx` | Every parameter, the replacement scan, each refusal message by exact equality, and the binding's params and schema |
| e2e | `komira_formats_e2e` xlsx cases | A query over each fixture through the plan and the engine. A workbook changed after binding is refused (`XLSX_CHANGED_SINCE_BIND`) |
| Python | `python/tests` `read_excel` tests | Each supported argument against the same fixtures, and each refused argument's exact message |
| Python | `//python/docs/tasks:26-read-excel-file` | The task page's example runs and prints its expected output |

Every new package starts at 99% line and branch coverage or more (rule T1), and every test file is
named in its library's `test_srcs` (rule T6). Each new public Mojo function appears in a README example
(rule T18).

**Why this list of failure cases is complete.** The list was made by walking each layer's input and
naming every way it can be wrong. For the container, that is the magic bytes, the end record, the
directory, the local header, the method, the flags, the sizes and the checksum. For the XML, that is
what the existing strict reader refuses, plus the window edge. For each part, its absence and each of
its fields. For each cell, its kind, its value, its style and its position. For each option, its values.
A case nobody listed would be a new way for one of those inputs to be wrong, and the reviewer of each
slice checks its layer's list against that layer's input.

## 7. Out of scope

The section [What is it for, and what is out of scope?](#what-is-it-for-and-what-is-out-of-scope)
holds the list: writing workbooks, macros, encrypted files, charts and the other non-cell parts,
evaluating formulas, display formatting, several sheets in one call, and the other file formats.

## Compatibility

- **The plan.** `komira.xlsx` is a new kind name inside the existing `WireScanBinding`. Its params are
  new keys. That change is additive (rule B8). A host that does not have the kind refuses a plan naming
  it before reading anything, through the scan-kind registry's existing lookup (`ScanKindRegistry:
  no descriptor for kind_id <id>`, `src/scan_source/scan_kind_registry.mojo`). The
  slice that adds the kind names the test that shows the refusal on a plan from a newer producer, and
  shows an older plan reads unchanged on the new engine.
- **`zlib` and `xml`.** Both changes add an entry point and leave every existing one with the same
  results. The `xml` change does alter the inside of the one path every AWS and Azure client takes
  (`parse_xml`). Its slice runs the existing `xml` tests and the AWS and Azure codec tests unchanged.
- **The libkomira ABI.** `komira_xlsx_binding` is a new export, so the ABI's minor version goes up by
  one, as [libkomira_run_abi.md](libkomira_run_abi.md) describes for new calls.

## Decisions for the owner

### D1. Dates that DuckDB reads differently from Excel

If slice 4's measurement confirms what section 1 infers, DuckDB reads two sets of date cells
differently from how Excel shows them. The cells in question are those with a date or timestamp
format whose serial is `1 <= s < 61` in a 1900-system workbook (one day early, and 1900-02-29 has no
date at all), and every date or timestamp cell of a 1904-system workbook (1462 days early). Time-only
cells are not affected, because DuckDB and Excel agree on the time of day. If the measurement shows
DuckDB reads them as Excel does, there is nothing to decide.

- **A (recommended).** Refuse those cells by name, with `XLSX_DATE_DIFFERS_FROM_DUCKDB`, naming the
  cell and advising to read the column with `all_varchar`. komira then never gives an answer that
  differs from DuckDB's, and never gives a date Excel does not show. A refusal is the form B21 gives an
  unsupported feature. It still fails a query DuckDB answers, so it is the owner's ruling and not a
  default.
- **B.** Give DuckDB's date. That matches DuckDB, but is a date the user never saw in Excel.
- **C.** Give Excel's date. That is what the user expects, but it departs from DuckDB, and B21 allows a
  departure only for an Arrow limit, so this needs a rule change.

The conversion lives in `xlsx`, so D1 must be decided before slice 4 lands.

### D2. What the pandas skin answers

pandas 3.0.6 with openpyxl and DuckDB differ in three places. In each, the skin can build pandas'
answer or list a departure ([dataframe_surface.md §8](dataframe_surface.md#8-where-the-libraries-and-the-plan-differ-the-rulings)):

- **Whole numbers.** pandas gives `int64` when every number in the column is written without a decimal
  point, and DuckDB gives DOUBLE. Building pandas' answer needs every cell before the type is known.
- **Dates.** pandas gives `datetime64` for date and timestamp cells, and DuckDB gives DATE or TIMESTAMP.
  For a time-only cell, openpyxl returns a `datetime.time`, so pandas' column holds objects, while
  DuckDB gives TIME. This is inferred from openpyxl's cell types and measured in slice 7.
- **The area.** pandas keeps empty rows inside the used area as rows of NaN. Its area spans the used
  rows and columns of the sheet. DuckDB's sniffed range stops at the first gap in the first data row
  and, by default, at the first empty row.

**Recommended:** take the engine's answer for whole numbers and dates, and list both as departures.
Build pandas' area. Finding the used area's last row and widest column needs the whole sheet, so for
`read_excel` the binding makes one more streaming pass over the sheet. That costs one extra decode of
the sheet, in the same bounded memory, and nothing else. Then the skin passes that range with
`stop_at_empty = false`. The slice that builds `read_excel` measures pandas 3.0.6 with openpyxl on each
fixture, and records in the skin's ruling which cases differ.

## Decisions taken here

Each of these is a choice the issue left open, taken the way most consistent with DuckDB and with the
rest of the tree:

- **`.xlsm` is read** like `.xlsx`, because its sheet parts are the same. Only `.xlsx` maps through
  `FROM '<path>'`.
- **Strict Open XML is refused** at first, because DuckDB's behaviour on it was not checked. It can be
  read later by matching both namespace sets, as an additive change.
- **Rows and cells out of order are refused**, not sorted. Sorting would need the whole sheet in
  memory, and no writer we know produces them.
- **One sheet decodes on one worker**, because a deflate stream cannot be split.
- **The fixtures come from LibreOffice**, converted from committed `.fods` sources by a recorded
  command, so anyone can regenerate them without Excel and no target depends on the converter.
- **The test writers are separate test-only libraries** (`zip_testing`, `xlsx_testing`), so `zip` and
  `xlsx` ship no writing code, and `xlsx`'s tests can reuse the zip writer.
- **Every part is streamed**, small ones included, so one bound per part covers all memory and no part
  is ever held whole.
- **Binding keeps only the shared strings it needs**, so it builds no whole table and needs no
  reservation of its own.
- **A lone surrogate in `_xHHHH_` is refused**, not replaced with U+FFFD, because a replacement would
  be a silently different answer.
- **A chart sheet named as `sheet` gets its own message**, although DuckDB reports it as not found,
  because both are errors and the message says why.

## Slices

Each slice is one pull request and lands in this order. Each package starts at 99% coverage or more.

1. **`zip`: read a zip archive.** It reads the end record, zip64, the directory and the local-header
   check, and reads stored and deflate members whole to their declared size with CRC-32 and size checks.
   The refusals are by name. It reads through `FileSystem`. The test-only `zip_testing` library lands
   here too, with its archive writer and its in-memory `FileSystem`.
2. **`zlib`: `ZlibInflater`.** Additive streaming raw inflate, plus `zip`'s streamed member read on top
   of it, stopping at the declared size.
3. **`xml`: `XmlReader` fed in pieces.** An additive constructor over a byte source with a token cap,
   with the whole-buffer path unchanged and held by the existing tests.
4. **`xlsx`: the workbook.** Relationships, sheets, states, styles and date classification, the date
   systems with D1 as decided (so D1 is decided before this slice), shared strings with the reservation,
   and the file-kind refusals. `xlsx_testing` and the fixtures also land here, with the fixtures' README
   and the recorded DuckDB results, with `test_xlsx_fixtures` checking what this slice reads (sheets,
   states, styles and date flags). This slice records DuckDB's answers to every inferred statement in
   sections 1 and 4, including those slice 5 builds on, and corrects this document where any differ.
5. **`xlsx`: rows.** The streamed row reader, cell kinds, inference, header and range sniffing, every
   option, batches, the streaming-bound test, `test_xlsx_fixtures` extended to every fixture's rows, and
   the throughput figure in the README.
6. **SQL: `read_xlsx`.** The table function, the `.xlsx` replacement scan, the `komira.xlsx` kind and its
   descriptor, the execute arm in `dispatch_scan`, the e2e cases, and the scan semantics added to
   [query_semantics_scans.md](query_semantics_scans.md) (a new §13 item for cell types, dates, empty and
   merged cells).
7. **Python: `read_excel`.** `komira_xlsx_binding`, `komira.read_excel` with its refusals, D2 as decided,
   the `kpl.read_excel` refusal entry in `python/komira/pl/_names.py`, the `scan_excel` row in
   [dataframe_surface_verbs.md](dataframe_surface_verbs.md), the reader list in
   [dataframe_surface.md](dataframe_surface.md), [install.md](../install.md), and a changelog entry.
   The task page lands here too: `python/docs/tasks/26-read-excel-file/` with `example.py` (it writes
   its small workbook with Python's standard `zipfile`, since the example's environment has only the
   wheel, pyarrow and protobuf), `expected_output.txt` and `page.md`. The catalogue's rank 26 moves from
   `gap` only as far as is true: `works` if the page's question is fully answered, otherwise `partial`,
   with the page saying which part is missing.

## Sources

- ECMA-376, *Office Open XML File Formats*, Part 1 (SpreadsheetML; §18.8.30 for number formats) and
  Part 2 (Open Packaging Conventions).
- DuckDB documentation, "Excel Extension" (the 1.5 and 2.0 pages; parameters, inference, `.xls`).
- duckdb-excel source, read on its main branch for this design: `src/excel/xlsx/read_xlsx.cpp`,
  `src/excel/include/xlsx/xlsx_parts.hpp` and
  `src/excel/include/xlsx/parsers/worksheet_parser.hpp`. Slice 4 re-reads them at the commit DuckDB
  v1.5.6 loads.
- pandas documentation, `pandas.read_excel`.
- Microsoft, "Excel specifications and limits" (cell text length, sheet size).
- PKWARE, *APPNOTE.TXT*, the .ZIP file format specification (end record, zip64, data descriptors,
  flags).
