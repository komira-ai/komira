//! elf_rpath: turn the DT_RUNPATH of an ELF64 little-endian file into a
//! DT_RPATH, in place.
//!
//! usage: elf_rpath <file>
//!
//! The loader searches a DT_RPATH before LD_LIBRARY_PATH, and a DT_RUNPATH
//! after it; a DT_RUNPATH also does not apply to a library another library
//! dlopens (glibc's pthread_cancel loads libgcc_s.so.1). kcov runs with the
//! LD_LIBRARY_PATH of the program under test, so its run path must be a
//! DT_RPATH. zig 0.12 passes `--disable-new-dtags` to lld for a shared
//! library only, so an executable it links always gets a DT_RUNPATH; this is
//! the byte edit `--disable-new-dtags` would have made: the tag of the one
//! DT_RUNPATH entry (29) becomes DT_RPATH (15), and its string is untouched.
//!
//! Refuses, with exit status 2, the message `elf_rpath: <reason>` on stderr
//! and the file untouched, anything but an x86_64 executable or shared object
//! (ET_EXEC or ET_DYN, EM_X86_64) with one PT_DYNAMIC header whose segment
//! has exactly one DT_RUNPATH and no DT_RPATH. A header or entry that lies
//! past the end of the file, or whose offset does not fit in 64 bits, is
//! refused as `truncated ELF file`. An error opening, reading or writing the
//! file, or a file over 2 GiB, exits 1 with `elf_rpath: <path>: <error>`.

use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::FileExt;
use std::process::exit;

const ET_EXEC: u16 = 2;
const ET_DYN: u16 = 3;
const EM_X86_64: u16 = 62;
const PT_DYNAMIC: u32 = 2;
const DT_NULL: u64 = 0;
const DT_RPATH: u64 = 15;
const DT_RUNPATH: u64 = 29;

/// The largest file read, in bytes.
const MAX_BYTES: u64 = 1 << 31;

const TRUNCATED: &str = "truncated ELF file";

/// The `N` bytes at `at`, or a refusal when they do not all lie in `b`.
fn bytes<const N: usize>(b: &[u8], at: u64) -> Result<[u8; N], String> {
    let start = usize::try_from(at).map_err(|_| TRUNCATED.to_string())?;
    let end = start.checked_add(N).ok_or_else(|| TRUNCATED.to_string())?;
    match b.get(start..end) {
        Some(s) => Ok(s.try_into().expect("slice of length N")),
        None => Err(TRUNCATED.to_string()),
    }
}

fn rd16(b: &[u8], at: u64) -> Result<u16, String> {
    bytes::<2>(b, at).map(u16::from_le_bytes)
}

fn rd32(b: &[u8], at: u64) -> Result<u32, String> {
    bytes::<4>(b, at).map(u32::from_le_bytes)
}

fn rd64(b: &[u8], at: u64) -> Result<u64, String> {
    bytes::<8>(b, at).map(u64::from_le_bytes)
}

/// `a + b`, or a refusal when it does not fit in 64 bits.
fn add(a: u64, b: u64) -> Result<u64, String> {
    a.checked_add(b).ok_or_else(|| TRUNCATED.to_string())
}

/// The file offset of the d_tag of the one DT_RUNPATH entry, or the reason
/// the file is refused.
fn runpath_tag(b: &[u8]) -> Result<u64, String> {
    if b.len() < 64 || &b[0..4] != b"\x7fELF" {
        return Err("not an ELF file".to_string());
    }
    if b[4] != 2 || b[5] != 1 {
        return Err("not ELF64 little-endian".to_string());
    }
    let e_type = rd16(b, 0x10)?;
    if e_type != ET_EXEC && e_type != ET_DYN {
        return Err(format!("e_type {e_type} is neither ET_EXEC nor ET_DYN"));
    }
    let e_machine = rd16(b, 0x12)?;
    if e_machine != EM_X86_64 {
        return Err(format!("e_machine {e_machine} is not EM_X86_64"));
    }
    let phoff = rd64(b, 0x20)?;
    let phentsize = u64::from(rd16(b, 0x36)?);
    let phnum = u64::from(rd16(b, 0x38)?);
    let mut dyn_seg: Option<(u64, u64)> = None;
    for i in 0..phnum {
        // i * phentsize < 2^32, so only the sum can overflow.
        let ph = add(phoff, i * phentsize)?;
        if rd32(b, ph)? == PT_DYNAMIC {
            if dyn_seg.is_some() {
                return Err("the file has two PT_DYNAMIC headers".to_string());
            }
            dyn_seg = Some((rd64(b, add(ph, 8)?)?, rd64(b, add(ph, 32)?)?));
        }
    }
    let (start, size) = dyn_seg.ok_or_else(|| "no PT_DYNAMIC segment".to_string())?;
    let end = add(start, size)?;
    let mut runpath: Option<u64> = None;
    let mut at = start;
    while add(at, 16)? <= end {
        let tag = rd64(b, at)?;
        if tag == DT_NULL {
            break;
        }
        if tag == DT_RPATH {
            return Err("the file has a DT_RPATH already".to_string());
        }
        if tag == DT_RUNPATH {
            if runpath.is_some() {
                return Err("the file has two DT_RUNPATH entries".to_string());
            }
            runpath = Some(at);
        }
        at += 16;
    }
    runpath.ok_or_else(|| "the file has no DT_RUNPATH".to_string())
}

fn io_fail(path: &std::ffi::OsStr, err: impl std::fmt::Display) -> ! {
    eprintln!("elf_rpath: {}: {}", path.to_string_lossy(), err);
    exit(1);
}

fn main() {
    let args: Vec<std::ffi::OsString> = std::env::args_os().collect();
    if args.len() != 2 {
        eprintln!("elf_rpath: usage: elf_rpath <file>");
        exit(2);
    }
    let path = args[1].as_os_str();
    let f: File = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .unwrap_or_else(|e| io_fail(path, e));
    let mut b = Vec::new();
    (&f).take(MAX_BYTES + 1)
        .read_to_end(&mut b)
        .unwrap_or_else(|e| io_fail(path, e));
    if b.len() as u64 > MAX_BYTES {
        io_fail(path, "file is larger than 2 GiB");
    }
    let off = match runpath_tag(&b) {
        Ok(off) => off,
        Err(why) => {
            eprintln!("elf_rpath: {why}");
            exit(2);
        }
    };
    f.write_all_at(&DT_RPATH.to_le_bytes(), off)
        .unwrap_or_else(|e| io_fail(path, e));
}

#[cfg(test)]
mod tests {
    use super::*;

    const PHOFF: usize = 64;
    const PHENTSIZE: usize = 56;

    fn put16(b: &mut [u8], at: usize, v: u16) {
        b[at..at + 2].copy_from_slice(&v.to_le_bytes());
    }
    fn put32(b: &mut [u8], at: usize, v: u32) {
        b[at..at + 4].copy_from_slice(&v.to_le_bytes());
    }
    fn put64(b: &mut [u8], at: usize, v: u64) {
        b[at..at + 8].copy_from_slice(&v.to_le_bytes());
    }

    /// An x86_64 ET_DYN file with two program headers (PT_LOAD, PT_DYNAMIC)
    /// and a dynamic segment holding `tags` (each with d_val 0), then a
    /// DT_NULL. Returns the bytes and the offset of the dynamic segment.
    fn elf(tags: &[u64]) -> (Vec<u8>, usize) {
        let dyn_off = PHOFF + 2 * PHENTSIZE;
        let dyn_size = (tags.len() + 1) * 16;
        let mut b = vec![0u8; dyn_off + dyn_size];
        b[0..4].copy_from_slice(b"\x7fELF");
        b[4] = 2;
        b[5] = 1;
        put16(&mut b, 0x10, ET_DYN);
        put16(&mut b, 0x12, EM_X86_64);
        put64(&mut b, 0x20, PHOFF as u64);
        put16(&mut b, 0x36, PHENTSIZE as u16);
        put16(&mut b, 0x38, 2);
        put32(&mut b, PHOFF, 1); // PT_LOAD
        let ph = PHOFF + PHENTSIZE;
        put32(&mut b, ph, PT_DYNAMIC);
        put64(&mut b, ph + 8, dyn_off as u64);
        put64(&mut b, ph + 32, dyn_size as u64);
        for (i, t) in tags.iter().enumerate() {
            put64(&mut b, dyn_off + 16 * i, *t);
        }
        (b, dyn_off)
    }

    fn refused(b: &[u8]) -> String {
        runpath_tag(b).expect_err("refused")
    }

    #[test]
    fn finds_the_one_runpath() {
        let (b, d) = elf(&[1, 21, DT_RUNPATH, 5]);
        assert_eq!(runpath_tag(&b), Ok((d + 32) as u64));
    }

    #[test]
    fn exec_is_accepted() {
        let (mut b, d) = elf(&[DT_RUNPATH]);
        put16(&mut b, 0x10, ET_EXEC);
        assert_eq!(runpath_tag(&b), Ok(d as u64));
    }

    #[test]
    fn entries_after_dt_null_are_not_read() {
        // A DT_RPATH after the terminator is not an entry.
        let (mut b, d) = elf(&[DT_RUNPATH, DT_NULL, DT_RPATH]);
        let ph = PHOFF + PHENTSIZE;
        put64(&mut b, ph + 32, 4 * 16);
        assert_eq!(runpath_tag(&b), Ok(d as u64));
    }

    #[test]
    fn entries_past_the_segment_size_are_not_read() {
        let (mut b, d) = elf(&[DT_RUNPATH, DT_RPATH]);
        put64(&mut b, PHOFF + PHENTSIZE + 32, 16);
        assert_eq!(runpath_tag(&b), Ok(d as u64));
    }

    #[test]
    fn refuses_what_is_not_elf() {
        assert_eq!(refused(&[0u8; 63]), "not an ELF file");
        let (mut b, _) = elf(&[DT_RUNPATH]);
        b[0] = b'E';
        assert_eq!(refused(&b), "not an ELF file");
        let (mut b, _) = elf(&[DT_RUNPATH]);
        b[4] = 1;
        assert_eq!(refused(&b), "not ELF64 little-endian");
        let (mut b, _) = elf(&[DT_RUNPATH]);
        b[5] = 2;
        assert_eq!(refused(&b), "not ELF64 little-endian");
    }

    #[test]
    fn refuses_type_and_machine() {
        let (mut b, _) = elf(&[DT_RUNPATH]);
        put16(&mut b, 0x10, 1);
        assert_eq!(refused(&b), "e_type 1 is neither ET_EXEC nor ET_DYN");
        let (mut b, _) = elf(&[DT_RUNPATH]);
        put16(&mut b, 0x12, 183);
        assert_eq!(refused(&b), "e_machine 183 is not EM_X86_64");
    }

    #[test]
    fn refuses_dynamic_headers_other_than_one() {
        let (mut b, _) = elf(&[DT_RUNPATH]);
        put32(&mut b, PHOFF, PT_DYNAMIC);
        assert_eq!(refused(&b), "the file has two PT_DYNAMIC headers");
        let (mut b, _) = elf(&[DT_RUNPATH]);
        put32(&mut b, PHOFF + PHENTSIZE, 1);
        assert_eq!(refused(&b), "no PT_DYNAMIC segment");
    }

    #[test]
    fn refuses_run_paths_other_than_one_runpath() {
        assert_eq!(refused(&elf(&[DT_RPATH, DT_RUNPATH]).0), "the file has a DT_RPATH already");
        assert_eq!(refused(&elf(&[DT_RUNPATH, DT_RPATH]).0), "the file has a DT_RPATH already");
        assert_eq!(refused(&elf(&[DT_RUNPATH, 1, DT_RUNPATH]).0), "the file has two DT_RUNPATH entries");
        assert_eq!(refused(&elf(&[1, 21]).0), "the file has no DT_RUNPATH");
    }

    #[test]
    fn refuses_offsets_past_the_end() {
        // Program headers past the end.
        let (mut b, _) = elf(&[DT_RUNPATH]);
        let n = b.len() as u64;
        put64(&mut b, 0x20, n);
        assert_eq!(refused(&b), TRUNCATED);
        // A dynamic segment that runs past the end.
        let (mut b, _) = elf(&[DT_RUNPATH, 1]);
        let n = b.len();
        b.truncate(n - 16); // drops the DT_NULL; the size still counts it
        put64(&mut b, PHOFF + PHENTSIZE + 32, 4 * 16);
        assert_eq!(refused(&b), TRUNCATED);
        // An offset whose sum does not fit in 64 bits.
        let (mut b, _) = elf(&[DT_RUNPATH]);
        put64(&mut b, 0x20, u64::MAX - 8);
        assert_eq!(refused(&b), TRUNCATED);
        let (mut b, _) = elf(&[DT_RUNPATH]);
        put64(&mut b, PHOFF + PHENTSIZE + 32, u64::MAX);
        assert_eq!(refused(&b), TRUNCATED);
    }
}
