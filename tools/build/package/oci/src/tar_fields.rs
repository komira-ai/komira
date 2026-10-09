//! Cases for every header field's width and offset, every type flag the
//! reader accepts, and the bytes the writer emits, checked against headers
//! laid out here from the ustar field table, not from the writer.

use super::write::*;
use super::*;

/// A ustar header from literal field bytes: name 0..100, mode 100..108,
/// uid 108..116, gid 116..124, size 124..136, mtime 136..148, checksum
/// 148..156 (six octal digits, NUL, space), type flag 156, link 157..257,
/// magic 257..263, version 263..265, prefix 345..500.
fn ustar(name: &[u8], mode: &[u8; 8], size: &[u8; 12], flag: u8) -> Vec<u8> {
    let mut h = vec![0u8; 512];
    h[..name.len()].copy_from_slice(name);
    h[100..108].copy_from_slice(mode);
    h[108..116].copy_from_slice(b"0000000\0");
    h[116..124].copy_from_slice(b"0000000\0");
    h[124..136].copy_from_slice(size);
    h[136..148].copy_from_slice(b"00000000000\0");
    h[148..156].copy_from_slice(b"        ");
    h[156] = flag;
    h[257..263].copy_from_slice(b"ustar\0");
    h[263..265].copy_from_slice(b"00");
    let sum: u32 = h.iter().map(|&b| b as u32).sum();
    h[148..156].copy_from_slice(format!("{:06o}\0 ", sum).as_bytes());
    h
}

fn item(p: &str, mode: u32, data: &[u8]) -> Item {
    Item { path: p.to_string(), mode, data: data.to_vec() }
}

fn zeros(n: usize) -> Vec<u8> {
    vec![0u8; n]
}

#[test]
fn the_writer_emits_these_bytes_exactly() {
    let dir = ustar(b"a/", b"0000755\0", b"00000000000\0", b'5');
    // The checksum by hand: 3189 = 0o6165.
    assert_eq!(&dir[148..156], b"006165\0 ");
    let mut want = dir;
    want.extend(ustar(b"a/f", b"0000644\0", b"00000000002\0", b'0'));
    want.extend(b"hi");
    want.extend(zeros(510));
    want.extend(zeros(1024));
    let got = write(vec![item("a/f", 0o644, b"hi"), item("a/", 0o755, b"")]).unwrap();
    assert_eq!(got.len(), 5 * 512);
    for (i, (g, w)) in got.chunks(512).zip(want.chunks(512)).enumerate() {
        assert_eq!(g, w, "block {}", i);
    }
    // A path of 101 bytes: a pax header whose one record is 111 bytes long,
    // then the entry under the path's first 100 bytes.
    let p = "p".repeat(101);
    let mut want = ustar(b"././@PaxHeader", b"0000644\0", b"00000000157\0", b'x');
    let rec = format!("111 path={}\n", p);
    assert_eq!(rec.len(), 111);
    want.extend(rec.as_bytes());
    want.extend(zeros(512 - 111));
    want.extend(ustar(&p.as_bytes()[..100], b"0000644\0", b"00000000000\0", b'0'));
    want.extend(zeros(1024));
    let got = write(vec![item(&p, 0o644, b"")]).unwrap();
    assert_eq!(got.len(), want.len());
    for (i, (g, w)) in got.chunks(512).zip(want.chunks(512)).enumerate() {
        assert_eq!(g, w, "block {}", i);
    }
}

#[test]
fn a_size_past_eleven_octal_digits_is_written_base_256() {
    let max = 0o77777777777u64;
    let mut h = Vec::new();
    put_header(&mut h, b"f", b'0', 0o644, max).unwrap();
    assert_eq!(&h[124..136], b"77777777777\0");
    assert_eq!(number(&h, 124, 12, "size"), Ok(max));
    // One over: 0x80, then the number big-endian in the other eleven bytes.
    let mut h = Vec::new();
    put_header(&mut h, b"f", b'0', 0o644, max + 1).unwrap();
    assert_eq!(&h[124..136], &[0x80, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0][..]);
    assert_eq!(number(&h, 124, 12, "size"), Ok(max + 1));
    let mut h = Vec::new();
    put_header(&mut h, b"f", b'0', 0o644, u64::MAX).unwrap();
    assert_eq!(&h[124..136], &[0x80, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff][..]);
    assert_eq!(number(&h, 124, 12, "size"), Ok(u64::MAX));
    // The checksum still holds: the reader takes the header.
    h.resize(512 + 1024, 0);
    assert_eq!(read(&h), Err("tar: an entry runs past the end".into()));
}

#[test]
fn each_numeric_field_is_read_at_its_width() {
    // (width, octal maximum): mode, uid, gid and checksum are 8 bytes; size
    // and mtime 12. The maximum fills all but the last byte; one over it is
    // base-256.
    for (width, max) in [(8usize, 0o7777777u64), (12, 0o77777777777)] {
        let mut f = vec![0u8; width];
        f[..width - 1].copy_from_slice(format!("{:o}", max).as_bytes());
        assert_eq!(number(&f, 0, width, "f"), Ok(max), "{}", width);
        // Every digit filled, no NUL: still the field's own bytes only.
        let mut g = f.clone();
        g[width - 1] = b'7';
        g.push(b'1');
        assert_eq!(number(&g, 0, width, "f"), Ok(max * 8 + 7), "{}", width);
        // Base-256: the low seven bits of the first byte and the rest, big-endian.
        let mut b = vec![0u8; width];
        for i in 0..8 {
            b[width - 1 - i] = ((max + 1) >> (8 * i)) as u8;
        }
        b[0] |= 0x80;
        assert_eq!(number(&b, 0, width, "f"), Ok(max + 1), "{}", width);
        assert_eq!(octal(&mut f, max), Ok(()));
        assert_eq!(octal(&mut f, max + 1), Err(format!("tar: {} does not fit a {}-byte field", max + 1, width)));
    }
}

/// One entry `name` with `link` and `prefix`, read back.
fn one(name: &[u8], link: &[u8], prefix: &[u8], magic: &[u8; 8]) -> Result<Vec<Entry>, String> {
    let mut h = ustar(name, b"0000777\0", b"00000000000\0", b'2');
    h[157..157 + link.len()].copy_from_slice(link);
    h[345..345 + prefix.len()].copy_from_slice(prefix);
    h[257..265].copy_from_slice(magic);
    h[148..156].copy_from_slice(b"        ");
    let sum: u32 = h.iter().map(|&b| b as u32).sum();
    h[148..156].copy_from_slice(format!("{:06o}\0 ", sum).as_bytes());
    h.extend(zeros(1024));
    read(&h)
}

#[test]
fn names_links_and_prefixes_fill_their_fields_exactly() {
    for n in [1, 99, 100] {
        let (name, link) = ("n".repeat(n), "l".repeat(n));
        let e = one(name.as_bytes(), link.as_bytes(), b"", b"ustar\x0000").unwrap();
        assert_eq!((e[0].path.as_str(), e[0].link.as_str()), (name.as_str(), link.as_str()), "{}", n);
    }
    // A prefix of 154 and of 155 bytes (the whole field) is joined with `/`.
    for n in [1, 154, 155] {
        let prefix = "q".repeat(n);
        let e = one(&[b'n'; 100], b"t", prefix.as_bytes(), b"ustar\x0000").unwrap();
        assert_eq!(e[0].path, format!("{}/{}", prefix, "n".repeat(100)), "{}", n);
    }
    // Under GNU's magic and under none, the prefix bytes are not a prefix.
    for magic in [b"ustar  \0", &[0u8; 8]] {
        assert_eq!(one(b"n", b"t", b"q", magic).unwrap()[0].path, "n");
    }
    // Longer than a field: the writer says it in a pax record instead.
    for n in [100, 101, 155, 156, 256, 257] {
        let p = "w".repeat(n);
        let e = read(&write(vec![item(&p, 0o644, b"")]).unwrap()).unwrap();
        assert_eq!(e[0].path, p, "{}", n);
    }
}

#[test]
fn every_type_flag_the_reader_accepts() {
    for (flag, kind) in [
        (b'0', Kind::File),
        (0, Kind::File),
        (b'7', Kind::File),
        (b'1', Kind::Hardlink),
        (b'2', Kind::Symlink),
        (b'5', Kind::Dir),
        (b'3', Kind::Other),
        (b'4', Kind::Other),
        (b'6', Kind::Other),
        (b'A', Kind::Other),
    ] {
        let e = read(&tar(&[("e", flag, 0o640, b"", "t")])).unwrap();
        let link = if matches!(kind, Kind::Symlink | Kind::Hardlink) { "t" } else { "" };
        assert_eq!((e.len(), e[0].kind, e[0].mode, e[0].link.as_str()), (1, kind, 0o640, link), "{}", flag as char);
    }
    // The four that are no entry: each is for the next one, or (g) for none.
    for (flag, path, link) in [(b'L', "body", "t"), (b'K', "e", "body"), (b'g', "e", "t")] {
        let e = read(&tar(&[("h", flag, 0o644, b"body", ""), ("e", b'2', 0o777, b"", "t")])).unwrap();
        assert_eq!((e.len(), e[0].path.as_str(), e[0].link.as_str()), (1, path, link), "{}", flag as char);
    }
    let e = read(&tar(&[("h", b'x', 0o644, b"11 path=pp\n", ""), ("e", b'0', 0o644, b"", "")])).unwrap();
    assert_eq!((e.len(), e[0].path.as_str()), (1, "pp"));
}

#[test]
fn a_pax_size_is_never_the_size_of_a_header_for_the_next_entry() {
    // A pax size of 2 then a header of each kind whose own size is not 2:
    // read at 2, its body would be cut and the next header misplaced.
    let long = "k".repeat(120);
    for (flag, body, path, link) in [
        (b'K', long.as_bytes(), "e", long.as_str()),
        (b'L', long.as_bytes(), long.as_str(), "t"),
        (b'g', &b"11 path=zz\n"[..], "e", "t"),
    ] {
        let mut t = Vec::new();
        entry(&mut t, "PaxHeader", b'x', 0o644, b"10 size=2\n", "");
        entry(&mut t, "h", flag, 0o644, body, "");
        t.extend(header("e", b'2', 0o777, 0, "t"));
        t.extend(b"ab");
        t.resize(t.len().div_ceil(512) * 512 + 1024, 0);
        let e = read(&t).unwrap();
        assert_eq!((e.len(), e[0].path.as_str(), e[0].link.as_str(), e[0].size), (1, path, link, 2), "{}", flag as char);
    }
    // Nor of a second pax header: that one is refused as a second, not read
    // at the first one's size past the end of the archive.
    let mut t = Vec::new();
    entry(&mut t, "PaxHeader", b'x', 0o644, b"13 size=5000\n", "");
    entry(&mut t, "PaxHeader", b'x', 0o644, b"", "");
    entry(&mut t, "e", b'0', 0o644, b"", "");
    t.resize(t.len() + 1024, 0);
    assert_eq!(read(&t), Err("tar: two pax headers for one entry".into()));
}
