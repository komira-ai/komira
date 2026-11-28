-- order: rows
SELECT k, epoch(t) AS s, epoch_ms(t) AS ms, epoch_us(t) AS us FROM T
