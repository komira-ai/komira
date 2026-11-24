-- Every unsigned integer width up to UBIGINT max.
SELECT id, u8, u16, u32, u64 FROM types ORDER BY id ASC NULLS LAST
