.libPaths(c("<W>/lib", .libPaths()))
suppressMessages(library(dazcache))
D <- asNamespace("dazcache")
newc <- function(...) cache(tempfile("hc-"), ...)
try_ <- function(expr) tryCatch(expr, error = function(e) structure(list(cls = class(e), msg = conditionMessage(e)), class = "err"))
print.err <- function(x, ...) cat("ERR[", paste(x$cls, collapse=","), "]:", x$msg, "\n")
blobs <- function(s) list.files(file.path(cache_dir(s), "blobs"), recursive = TRUE)
tmpf <- function(s) list.files(file.path(cache_dir(s), "tmp"))
rows <- function(s, db, values = TRUE) D$engine_read(s$engine, function(txn) {
  g <- D$engine_scan(txn, D$engine_db(s$engine, db), as = "character", values = TRUE)
  if (values && db %in% c("meta","blobs")) setNames(lapply(g$values, unserialize), g$keys) else g$keys })
ctr <- function(s) D$engine_read(s$engine, D$store_counters)
st <- function(s) { c <- ctr(s); cat(sprintf("count=%d inline=%g blob=%g files=%d tmp=%d check=%d\n", cache_count(s), c$bytes_inline, c$bytes_blob, length(blobs(s)), length(tmpf(s)), nrow(cache_check(s, hash=TRUE)))) }
