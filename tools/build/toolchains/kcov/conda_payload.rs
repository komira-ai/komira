//! conda_payload: write the payload tar of a `.conda` package.
//!
//! usage: conda_payload <package.conda> <out.tar>
//!
//! A `.conda` file is a zip (stored entries, zip64 size fields) holding
//! `pkg-*.tar.zst`, the payload, and `info-*.tar.zst`. The pinned busybox
//! reads neither zip64 nor zstd, so kcov_build.sh and
//! ../llvm_branch/unpack.sh run this and untar the result with busybox. The
//! zip walk is the one of tools/build/mojo/tools/conda_unpack.zig, which this
//! does not change: an edit there would re-key every Mojo action.
//!
//! Exit status 2, with `conda_payload: <message>` on stderr and no output
//! file, on a usage error or a malformed zip. Exit status 1, with
//! `error: <Name>` on stderr (the Zig error name), when the package cannot
//! be read (no output file), or the output cannot be written or the payload
//! is not zstd this tool decodes (the output file then holds part of what was
//! decoded before the failure: ruzstd holds back a window's worth until a
//! frame ends). A zip64 size that overflows the member's end offset aborts
//! with `panic: integer overflow`, as the Zig tool's safety check did.
//!
//! The zstd payload is decoded by the `ruzstd` crate, one decoder per frame.
//! The frame and block headers are checked here first, so what is accepted
//! is what this tool's Zig predecessor (std.compress.zstd of zig 0.12, a
//! window buffer of 1 << 27 bytes) accepted: concatenated and skippable
//! frames; a frame with a reserved bit set, a dictionary id field, a window
//! over 1 << 27 bytes, a reserved block type, a block over
//! min(128 KiB, window), a content size that the blocks do not add up to, or
//! a checksum that does not match is refused; input that ends at a frame
//! boundary ends the output, and anything else after the last frame is
//! refused.

use std::ffi::OsString;
use std::fs::File;
use std::io::{self, Cursor, Write};
use std::os::unix::ffi::OsStrExt;
use std::process::exit;

use ruzstd::decoding::errors::FrameDecoderError;
use ruzstd::decoding::{BlockDecodingStrategy, FrameDecoder};

/// The decoder's window buffer: a frame whose window does not fit is
/// refused. conda-forge packages use far smaller windows.
const WINDOW_MAX: u64 = 1 << 27;

/// The largest block the format allows (before the window caps it).
const BLOCK_SIZE_MAX: u64 = 128 * 1024;

/// readFileAlloc's limit in the Zig tool.
const READ_MAX: u64 = 1 << 31;

/// A usage error or malformed zip: `conda_payload: <message>`, exit 2.
fn fail(parts: &[&[u8]]) -> ! {
    let mut msg = b"conda_payload: ".to_vec();
    for p in parts {
        msg.extend_from_slice(p);
    }
    msg.push(b'\n');
    let _ = io::stderr().write_all(&msg);
    exit(2);
}

/// Any other failure: `error: <Name>`, exit 1 (as a Zig `main` returning an
/// error).
fn die(name: &str) -> ! {
    let _ = io::stderr().write_all(format!("error: {name}\n").as_bytes());
    exit(1);
}

/// An integer overflow, which the Zig tool (ReleaseSafe) panicked on.
fn overflow() -> ! {
    let _ = io::stderr().write_all(b"panic: integer overflow\n");
    std::process::abort();
}

fn io_name(e: &io::Error) -> &'static str {
    match e.kind() {
        io::ErrorKind::NotFound => "FileNotFound",
        io::ErrorKind::PermissionDenied => "AccessDenied",
        io::ErrorKind::IsADirectory => "IsDir",
        io::ErrorKind::NotADirectory => "NotDir",
        io::ErrorKind::StorageFull => "NoSpaceLeft",
        io::ErrorKind::FileTooLarge => "FileTooBig",
        io::ErrorKind::OutOfMemory => "OutOfMemory",
        _ => "Unexpected",
    }
}

fn le16(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}

fn le32(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}

fn le64(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}

/// Compressed size from a local header's zip64 extra field (id 0x0001).
fn zip64_compressed_size(extra: &[u8], usize_is_64: bool) -> Option<u64> {
    let mut i = 0usize;
    while i + 4 <= extra.len() {
        let id = le16(extra, i);
        let len = le16(extra, i + 2) as usize;
        if i + 4 + len > extra.len() {
            return None;
        }
        if id == 0x0001 {
            let mut at = i + 4;
            if usize_is_64 {
                at += 8;
            }
            if at + 8 > i + 4 + len {
                return None;
            }
            return Some(le64(extra, at));
        }
        i += 4 + len;
    }
    None
}

/// A refusal of the zip walk: the message parts after `conda_payload: `.
#[derive(Debug, PartialEq)]
enum ZipError {
    Refused(Vec<u8>),
    Overflow,
}

fn refused(parts: &[&[u8]]) -> ZipError {
    ZipError::Refused(parts.concat())
}

/// The bytes of the `pkg-*.tar.zst` member.
fn payload<'a>(data: &'a [u8], path: &[u8]) -> Result<&'a [u8], ZipError> {
    let mut off = 0usize;
    while off + 30 <= data.len() && le32(data, off) == 0x04034b50 {
        let flags = le16(data, off + 6);
        let method = le16(data, off + 8);
        let mut csize = u64::from(le32(data, off + 18));
        let usize32 = le32(data, off + 22);
        let nlen = le16(data, off + 26) as usize;
        let xlen = le16(data, off + 28) as usize;
        let start = off + 30 + nlen + xlen;
        if start > data.len() {
            return Err(refused(&[path, b": truncated zip local header at offset ", off.to_string().as_bytes()]));
        }
        let name = &data[off + 30..off + 30 + nlen];
        let extra = &data[off + 30 + nlen..start];
        if flags & 0x8 != 0 {
            return Err(refused(&[name, b": zip data descriptors are not supported"]));
        }
        if method != 0 {
            return Err(refused(&[
                name,
                b": zip compression method ",
                method.to_string().as_bytes(),
                b"; only stored (0) is supported",
            ]));
        }
        if csize == 0xffff_ffff {
            csize = match zip64_compressed_size(extra, usize32 == 0xffff_ffff) {
                Some(n) => n,
                None => return Err(refused(&[name, b": zip64 size field missing"])),
            };
        }
        let end = (start as u64).checked_add(csize).ok_or(ZipError::Overflow)?;
        if end > data.len() as u64 {
            return Err(refused(&[name, b": entry runs past end of file"]));
        }
        let body = &data[start..end as usize];
        if name.starts_with(b"pkg-") && name.ends_with(b".tar.zst") {
            return Ok(body);
        }
        off = end as usize;
    }
    Err(refused(&[path, b": no pkg-*.tar.zst member"]))
}

/// What std.compress.zstd's reader returned, by its error name.
#[derive(Debug, PartialEq)]
enum ZstdError {
    MalformedFrame,
    MalformedBlock,
    ChecksumFailure,
    DictionaryIdFlagUnsupported,
    /// Writing the output failed: the Zig name of the I/O error.
    Io(&'static str),
}

impl ZstdError {
    fn name(&self) -> &'static str {
        match self {
            ZstdError::MalformedFrame => "MalformedFrame",
            ZstdError::MalformedBlock => "MalformedBlock",
            ZstdError::ChecksumFailure => "ChecksumFailure",
            ZstdError::DictionaryIdFlagUnsupported => "DictionaryIdFlagUnsupported",
            ZstdError::Io(n) => n,
        }
    }
}

/// A zstd frame header, as far as the checks here need it.
struct FrameHeader {
    window_size: u64,
    content_size: Option<u64>,
}

/// The frame starting at `src[0]`: Ok(None) for a skippable frame (whose
/// total length is returned through `skip`), the header of a zstd frame,
/// or the error the Zig reader gave.
fn frame_header(src: &[u8], skip: &mut u64) -> Result<Option<FrameHeader>, ZstdError> {
    use ZstdError::*;
    if src.len() < 4 {
        return Err(MalformedFrame);
    }
    let magic = le32(src, 0);
    if (0x184D2A50..=0x184D2A5F).contains(&magic) {
        if src.len() < 8 {
            return Err(MalformedFrame);
        }
        let total = 8 + u64::from(le32(src, 4));
        if total > src.len() as u64 {
            return Err(MalformedFrame);
        }
        *skip = total;
        return Ok(None);
    }
    if magic != 0xFD2FB528 {
        return Err(MalformedFrame);
    }
    let mut at = 4usize;
    let byte = |at: usize| src.get(at).copied().ok_or(MalformedFrame);
    let desc = byte(at)?;
    at += 1;
    let dict_flag = desc & 0x3;
    let reserved = desc & 0x8 != 0;
    let single_segment = desc & 0x20 != 0;
    let fcs_flag = desc >> 6;
    if reserved {
        return Err(MalformedFrame);
    }
    let mut window_descriptor = None;
    if !single_segment {
        window_descriptor = Some(byte(at)?);
        at += 1;
    }
    if dict_flag > 0 {
        let field = (1usize << dict_flag) >> 1;
        if src.len() < at + field {
            return Err(MalformedFrame);
        }
        at += field;
    }
    let mut content_size = None;
    if single_segment || fcs_flag > 0 {
        let field = 1usize << fcs_flag;
        if src.len() < at + field {
            return Err(MalformedFrame);
        }
        let mut n = 0u64;
        for i in 0..field {
            n |= u64::from(src[at + i]) << (8 * i);
        }
        if field == 2 {
            n += 256;
        }
        content_size = Some(n);
    }
    if dict_flag != 0 {
        return Err(DictionaryIdFlagUnsupported);
    }
    let window_size = match window_descriptor {
        Some(d) => {
            let exponent = u64::from(d >> 3);
            let mantissa = u64::from(d & 0x7);
            let base = 1u64 << (10 + exponent);
            base + (base / 8) * mantissa
        }
        // The single-segment flag always carries a content size.
        None => content_size.unwrap_or(0),
    };
    if window_size > WINDOW_MAX {
        return Err(MalformedFrame);
    }
    Ok(Some(FrameHeader { window_size, content_size }))
}

/// Decodes the zstd stream `src` into `out`, writing each frame's bytes as
/// the decoder releases them.
fn decode(src: &[u8], out: &mut impl Write) -> Result<(), ZstdError> {
    use ZstdError::*;
    let mut cur = Cursor::new(src);
    loop {
        let pos = cur.position() as usize;
        if pos == src.len() {
            return Ok(());
        }
        let mut skip = 0u64;
        let header = match frame_header(&src[pos..], &mut skip)? {
            None => {
                cur.set_position(pos as u64 + skip);
                continue;
            }
            Some(h) => h,
        };
        // A new decoder per frame: ruzstd's reset() of a used decoder refuses
        // windows over its own 100 MiB limit, which is not this tool's.
        let mut dec = FrameDecoder::new();
        dec.reset(&mut cur).map_err(|_| MalformedFrame)?;
        let block_max = BLOCK_SIZE_MAX.min(header.window_size);
        let mut decoded = 0u64;
        loop {
            let at = cur.position() as usize;
            if src.len() < at + 3 {
                return Err(MalformedFrame);
            }
            let bh = u32::from(src[at]) | u32::from(src[at + 1]) << 8 | u32::from(src[at + 2]) << 16;
            let block_type = (bh >> 1) & 0x3;
            let block_size = u64::from(bh >> 3);
            if block_type == 3 || block_size > block_max {
                return Err(MalformedBlock);
            }
            let finished = dec
                .decode_blocks(&mut cur, BlockDecodingStrategy::UptoBlocks(1))
                .map_err(|e| match e {
                    FrameDecoderError::FailedToReadChecksum(_) => MalformedFrame,
                    _ => MalformedBlock,
                })?;
            if finished {
                break;
            }
            // While the frame is open the decoder keeps a window's worth.
            if let Some(bytes) = dec.collect() {
                decoded += bytes.len() as u64;
                put(&mut *out, &bytes)?;
            }
        }
        let rest = dec.collect().unwrap_or_default();
        decoded += rest.len() as u64;
        if let Some(size) = header.content_size {
            if decoded > size {
                return Err(MalformedFrame);
            }
        }
        if let Some(want) = dec.get_checksum_from_data() {
            if dec.get_calculated_checksum() != Some(want) {
                return Err(ChecksumFailure);
            }
        }
        if let Some(size) = header.content_size {
            if decoded != size {
                return Err(MalformedFrame);
            }
        }
        put(&mut *out, &rest)?;
    }
}

fn put(out: &mut dyn Write, bytes: &[u8]) -> Result<(), ZstdError> {
    out.write_all(bytes).map_err(|e| ZstdError::Io(io_name(&e)))
}

fn read_input(path: &OsString) -> Vec<u8> {
    let data = (|| -> io::Result<Option<Vec<u8>>> {
        let mut f = File::open(path)?;
        if f.metadata()?.len() > READ_MAX {
            return Ok(None);
        }
        let mut data = Vec::new();
        io::Read::read_to_end(&mut f, &mut data)?;
        Ok(Some(data))
    })();
    match data {
        Ok(Some(d)) if d.len() as u64 <= READ_MAX => d,
        Ok(_) => die("FileTooBig"),
        Err(e) => die(io_name(&e)),
    }
}

fn main() {
    let args: Vec<OsString> = std::env::args_os().collect();
    if args.len() != 3 {
        fail(&[b"usage: conda_payload <package.conda> <out.tar>"]);
    }
    let data = read_input(&args[1]);
    let body = match payload(&data, args[1].as_bytes()) {
        Ok(b) => b,
        Err(ZipError::Refused(msg)) => fail(&[msg.as_slice()]),
        Err(ZipError::Overflow) => overflow(),
    };
    let file = File::create(&args[2]).unwrap_or_else(|e| die(io_name(&e)));
    let mut out = io::BufWriter::with_capacity(65536, file);
    if let Err(e) = decode(body, &mut out) {
        let _ = out.flush();
        die(e.name());
    }
    if let Err(e) = out.flush() {
        die(io_name(&e));
    }
}

#[cfg(test)]
#[path = "conda_payload_test.rs"]
mod tests;
