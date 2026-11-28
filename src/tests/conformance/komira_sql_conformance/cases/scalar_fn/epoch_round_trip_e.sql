-- order: rows
SELECT k, epoch_us(make_timestamp(us)) AS us, epoch_ms(make_timestamp_ms(ms)) AS ms, epoch_ms(epoch_ms(ms)) AS ms2 FROM E
