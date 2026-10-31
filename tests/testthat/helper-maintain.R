held <- function(s) {
  c <- engine_read(s$engine, store_counters)
  c$bytes_inline + c$bytes_blob
}
