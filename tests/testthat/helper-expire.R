expiry_rows <- function(s) {
  engine_read(s$engine, function(txn) engine_count(txn, engine_db(s$engine, "expiry")))
}
