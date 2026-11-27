-- order: rows
SELECT k, epoch(ts) AS s, epoch_ms(ts) AS ms, epoch_us(ts) AS us FROM E
