-- order: rows
SELECT k, epoch(dt) AS s, epoch_ms(dt) AS ms, epoch_us(dt) AS us FROM E
