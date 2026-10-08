//! conda_payload's unit tests: the zip walk's answers and refusals with
//! their exact messages, and the zstd checks that make the decoder accept
//! what std.compress.zstd of zig 0.12 accepted and refuse what it refused.
//! kcov_check.sh `cases` runs the built binary end to end.

use super::*;

/// A zip local header and body, as kcov_check.sh's `zip_member` writes it.
fn member(name: &str, method: u16, zip64: bool, data: &[u8]) -> Vec<u8> {
    let mut v = vec![0x50, 0x4b, 0x03, 0x04, 0x0a, 0x00, 0x00, 0x00];
    v.extend_from_slice(&method.to_le_bytes());
    v.extend_from_slice(&[0; 8]);
    if zip64 {
        v.extend_from_slice(&[0xff; 8]);
    } else {
        v.extend_from_slice(&(data.len() as u32).to_le_bytes());
        v.extend_from_slice(&(data.len() as u32).to_le_bytes());
    }
    v.extend_from_slice(&(name.len() as u16).to_le_bytes());
    v.extend_from_slice(&(if zip64 { 20u16 } else { 0 }).to_le_bytes());
    v.extend_from_slice(name.as_bytes());
    if zip64 {
        v.extend_from_slice(&[0x01, 0x00, 0x10, 0x00]);
        v.extend_from_slice(&(data.len() as u64).to_le_bytes());
        v.extend_from_slice(&(data.len() as u64).to_le_bytes());
    }
    v.extend_from_slice(data);
    v
}

fn refusal(r: Result<&[u8], ZipError>) -> String {
    match r {
        Err(ZipError::Refused(m)) => String::from_utf8(m).unwrap(),
        other => panic!("want a refusal, got {other:?}"),
    }
}

#[test]
fn zip_payload_after_another_member() {
    let mut z = member("info-x.tar.zst", 0, false, b"\x00");
    z.extend(member("pkg-x.tar.zst", 0, false, b"BODY"));
    assert_eq!(payload(&z, b"p.conda"), Ok(&b"BODY"[..]));
}

#[test]
fn zip64_sizes() {
    let z = member("pkg-x.tar.zst", 0, true, b"BODY");
    assert_eq!(payload(&z, b"p.conda"), Ok(&b"BODY"[..]));
}

#[test]
fn zip64_compressed_size_after_the_uncompressed_one_only_when_that_is_64_bit() {
    // Extra field: id 1, len 8, one size. With the 32-bit uncompressed size
    // not 0xffffffff the field holds the compressed size first.
    let mut z = member("pkg-x.tar.zst", 0, false, b"BODY");
    z[18..22].copy_from_slice(&[0xff; 4]);
    z[28..30].copy_from_slice(&12u16.to_le_bytes());
    let mut extra = vec![0x01, 0x00, 0x08, 0x00];
    extra.extend_from_slice(&4u64.to_le_bytes());
    let body_at = 30 + "pkg-x.tar.zst".len();
    z.splice(body_at..body_at, extra);
    assert_eq!(payload(&z, b"p.conda"), Ok(&b"BODY"[..]));
    // The same field when the uncompressed size is 0xffffffff too: the
    // compressed size would be past the field's 8 bytes.
    z[22..26].copy_from_slice(&[0xff; 4]);
    assert_eq!(refusal(payload(&z, b"p.conda")), "pkg-x.tar.zst: zip64 size field missing");
}

#[test]
fn refusals_name_what_is_wrong() {
    let nopkg = member("info-x.tar.zst", 0, false, b"BODY");
    assert_eq!(refusal(payload(&nopkg, b"dir/p.conda")), "dir/p.conda: no pkg-*.tar.zst member");
    let deflate = member("pkg-x.tar.zst", 8, false, b"BODY");
    assert_eq!(
        refusal(payload(&deflate, b"p.conda")),
        "pkg-x.tar.zst: zip compression method 8; only stored (0) is supported"
    );
    let mut desc = member("pkg-x.tar.zst", 0, false, b"BODY");
    desc[6] = 0x08;
    assert_eq!(refusal(payload(&desc, b"p.conda")), "pkg-x.tar.zst: zip data descriptors are not supported");
    let mut nosize = member("pkg-x.tar.zst", 0, false, b"BODY");
    nosize[18..22].copy_from_slice(&[0xff; 4]);
    assert_eq!(refusal(payload(&nosize, b"p.conda")), "pkg-x.tar.zst: zip64 size field missing");
    let mut past = member("pkg-x.tar.zst", 0, false, b"BODY");
    past.pop();
    assert_eq!(refusal(payload(&past, b"p.conda")), "pkg-x.tar.zst: entry runs past end of file");
    // The second header's name runs past the end: its offset is named.
    let mut trunc = member("info-x.tar.zst", 0, false, b"ab");
    let first = trunc.len();
    trunc.extend(member("pkg-x.tar.zst", 0, false, b""));
    trunc.truncate(first + 31);
    assert_eq!(
        refusal(payload(&trunc, b"p.conda")),
        format!("p.conda: truncated zip local header at offset {first}")
    );
    // Not a zip at all, and a header cut short of 30 bytes: no member.
    assert_eq!(refusal(payload(b"\x7fELF", b"p.conda")), "p.conda: no pkg-*.tar.zst member");
    let short = &member("pkg-x.tar.zst", 0, false, b"")[..29];
    assert_eq!(refusal(payload(short, b"p.conda")), "p.conda: no pkg-*.tar.zst member");
}

#[test]
fn a_zip64_size_that_overflows_the_offset_is_an_overflow() {
    let mut z = member("pkg-x.tar.zst", 0, true, b"BODY");
    let at = 30 + "pkg-x.tar.zst".len() + 4 + 8;
    z[at..at + 8].copy_from_slice(&u64::MAX.to_le_bytes());
    assert_eq!(payload(&z, b"p.conda"), Err(ZipError::Overflow));
}

// ---- zstd ------------------------------------------------------------------

const MAGIC: [u8; 4] = [0x28, 0xb5, 0x2f, 0xfd];

/// A block header: size, type (0 raw, 1 RLE, 2 compressed, 3 reserved), last.
fn block(size: u32, ty: u32, last: bool) -> [u8; 3] {
    let h = (size << 3) | (ty << 1) | u32::from(last);
    [h as u8, (h >> 8) as u8, (h >> 16) as u8]
}

/// A single-segment frame of one raw last block, content size in one byte.
fn raw_frame(data: &[u8]) -> Vec<u8> {
    let mut v = MAGIC.to_vec();
    v.extend_from_slice(&[0x20, data.len() as u8]);
    v.extend_from_slice(&block(data.len() as u32, 0, true));
    v.extend_from_slice(data);
    v
}

fn run(src: &[u8]) -> (Result<(), ZstdError>, Vec<u8>) {
    let mut out = Vec::new();
    let r = decode(src, &mut out);
    (r, out)
}

#[test]
fn the_cases_frame() {
    // kcov_check.sh's FRAME: one raw block, `kcov\n`.
    let frame = [0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x05, 0x29, 0x00, 0x00, 0x6b, 0x63, 0x6f, 0x76, 0x0a];
    assert_eq!(raw_frame(b"kcov\n"), frame);
    assert_eq!(run(&frame), (Ok(()), b"kcov\n".to_vec()));
}

#[test]
fn empty_input_is_empty_output() {
    assert_eq!(run(b""), (Ok(()), vec![]));
}

#[test]
fn frames_concatenate_and_skippable_frames_are_skipped() {
    let mut s = raw_frame(b"ab");
    s.extend_from_slice(&[0x5f, 0x2a, 0x4d, 0x18, 3, 0, 0, 0, 9, 9, 9]);
    // An RLE block: one byte, repeated (no window descriptor: window 1 KiB).
    s.extend_from_slice(&MAGIC);
    s.extend_from_slice(&[0x00, 0x00]);
    s.extend_from_slice(&block(3, 1, true));
    s.push(b'c');
    assert_eq!(run(&s), (Ok(()), b"abccc".to_vec()));
}

#[test]
fn bytes_after_the_last_frame_are_refused() {
    for tail in [&[0x28][..], &[0x28, 0xb5, 0x2f], &[0, 0, 0, 0]] {
        let mut s = raw_frame(b"ab");
        s.extend_from_slice(tail);
        let (r, out) = run(&s);
        assert_eq!(r, Err(ZstdError::MalformedFrame), "tail {tail:?}");
        assert_eq!(out, b"ab", "the frame before the tail is written");
    }
    // A skippable frame cut short.
    let (r, _) = run(&[0x50, 0x2a, 0x4d, 0x18, 4, 0, 0, 0, 1]);
    assert_eq!(r, Err(ZstdError::MalformedFrame));
}

#[test]
fn header_refusals() {
    let mut reserved = raw_frame(b"ab");
    reserved[4] |= 0x08;
    assert_eq!(run(&reserved).0, Err(ZstdError::MalformedFrame));
    // A dictionary id field, even of id 0.
    let mut dict = MAGIC.to_vec();
    dict.extend_from_slice(&[0x21, 0x00, 0x02]);
    dict.extend_from_slice(&block(2, 0, true));
    dict.extend_from_slice(b"ab");
    assert_eq!(run(&dict).0, Err(ZstdError::DictionaryIdFlagUnsupported));
    // A header cut short of its content size.
    assert_eq!(run(&[0x28, 0xb5, 0x2f, 0xfd, 0x20]).0, Err(ZstdError::MalformedFrame));
}

/// A frame with a window descriptor and one raw last block.
fn windowed(descriptor: u8, data: &[u8]) -> Vec<u8> {
    let mut v = MAGIC.to_vec();
    v.extend_from_slice(&[0x00, descriptor]);
    v.extend_from_slice(&block(data.len() as u32, 0, true));
    v.extend_from_slice(data);
    v
}

#[test]
fn the_window_limit_is_one_shl_27() {
    // Exponent 17: 1 << 27, accepted. Exponent 17 mantissa 1, and exponent
    // 18: over it, refused. ruzstd alone allows only 100 MiB on a reused
    // decoder, so 1 << 27 also shows the decoder is fresh per frame.
    let mut s = windowed(17 << 3, b"ab");
    s.extend(windowed(17 << 3, b"cd"));
    assert_eq!(run(&s), (Ok(()), b"abcd".to_vec()));
    assert_eq!(run(&windowed((17 << 3) | 1, b"ab")).0, Err(ZstdError::MalformedFrame));
    assert_eq!(run(&windowed(18 << 3, b"ab")).0, Err(ZstdError::MalformedFrame));
}

#[test]
fn block_refusals() {
    // A reserved block type.
    let mut s = MAGIC.to_vec();
    s.extend_from_slice(&[0x20, 2]);
    s.extend_from_slice(&block(2, 3, true));
    s.extend_from_slice(b"ab");
    assert_eq!(run(&s).0, Err(ZstdError::MalformedBlock));
    // A block larger than the window (content size 2, block of 3).
    let mut big = MAGIC.to_vec();
    big.extend_from_slice(&[0x20, 2]);
    big.extend_from_slice(&block(3, 0, true));
    big.extend_from_slice(b"abc");
    assert_eq!(run(&big).0, Err(ZstdError::MalformedBlock));
    // A raw block cut short, and a block header cut short.
    let mut cut = raw_frame(b"abc");
    cut.pop();
    assert_eq!(run(&cut).0, Err(ZstdError::MalformedBlock));
    assert_eq!(run(&raw_frame(b"abc")[..7]).0, Err(ZstdError::MalformedFrame));
}

#[test]
fn content_size_must_match() {
    // A 4-byte content size field and a 1 KiB window: 3 bytes decoded
    // against 2 declared (more) and 4 declared (fewer).
    for declared in [2u32, 4] {
        let mut f = MAGIC.to_vec();
        f.extend_from_slice(&[0x80, 0x00]);
        f.extend_from_slice(&declared.to_le_bytes());
        f.extend_from_slice(&block(3, 0, true));
        f.extend_from_slice(b"abc");
        assert_eq!(run(&f).0, Err(ZstdError::MalformedFrame), "declared {declared}");
        f[6..10].copy_from_slice(&3u32.to_le_bytes());
        assert_eq!(run(&f), (Ok(()), b"abc".to_vec()));
    }
    // The two-byte field counts from 256.
    let mut two = MAGIC.to_vec();
    two.extend_from_slice(&[0x40, 0x00, 0x00, 0x00]);
    two.extend_from_slice(&block(256, 1, true));
    two.push(b'z');
    assert_eq!(run(&two), (Ok(()), vec![b'z'; 256]));
}

#[test]
fn checksums_are_verified() {
    let data = b"kcov\n";
    let sum = (twox_hash::XxHash64::oneshot(0, data) as u32).to_le_bytes();
    let mut good = MAGIC.to_vec();
    good.extend_from_slice(&[0x24, data.len() as u8]);
    good.extend_from_slice(&block(data.len() as u32, 0, true));
    good.extend_from_slice(data);
    good.extend_from_slice(&sum);
    assert_eq!(run(&good), (Ok(()), data.to_vec()));
    let mut bad = good.clone();
    *bad.last_mut().unwrap() ^= 1;
    let (r, out) = run(&bad);
    assert_eq!(r, Err(ZstdError::ChecksumFailure));
    assert!(out.is_empty(), "a frame whose checksum fails is not written");
    // The checksum cut short.
    assert_eq!(run(&good[..good.len() - 1]).0, Err(ZstdError::MalformedFrame));
}

#[test]
fn compressed_frames_round_trip() {
    // Several 128 KiB blocks of compressible, non-trivial text: compressed
    // blocks, the decoder's window retention across blocks, and the
    // encoder's checksum.
    let mut data = Vec::new();
    let mut x = 0x2545_f491_4f6c_dd1du64;
    while data.len() < 700_000 {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        let word = ["kcov", "conda", "payload", "zstd", "frame", "block"][(x % 6) as usize];
        data.extend_from_slice(word.as_bytes());
        data.push(if x % 11 == 0 { b'\n' } else { b' ' });
    }
    let z = ruzstd::encoding::compress_to_vec(&data[..], ruzstd::encoding::CompressionLevel::Fastest);
    assert!(z.len() < data.len() / 2, "the frame is compressed");
    let mut two = z.clone();
    two.extend_from_slice(&z);
    let (r, out) = run(&two);
    assert_eq!(r, Ok(()));
    assert!(out.len() == 2 * data.len() && out[..data.len()] == data[..] && out[data.len()..] == data[..]);
}
