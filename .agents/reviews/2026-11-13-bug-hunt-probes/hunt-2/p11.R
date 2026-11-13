source("h.R")
E <- function(s, f) D$engine_write(s$engine, f, timeout = 5)
cat("== stale tmp file with own pid, read-only\n")
d <- tempfile(); s <- cache(d, inline_max = 10)
p <- file.path(d, "tmp", sprintf("%d-%d", Sys.getpid(), D$dazcache_state$stage + 1L)); writeBin(as.raw(1:99), p); Sys.chmod(p, "444")
print(try_(cache_set(s, "a", raw(50)))); print(try_(cache_get(s, "a"))); print(tmpf(s))
p <- file.path(d, "tmp", sprintf("%d-%d", Sys.getpid(), D$dazcache_state$stage + 1L)); writeBin(as.raw(1:99), p)
cache_set(s, "b", as.raw(rep(5, 60))); print(try_(length(cache_pop(s, "b")))); print(cache_has(s, "b")); print(tmpf(s))
cat("== orphan garbage at target name\n")
cache_set(s, "c", as.raw(rep(6, 60))); pc <- cache_path(s, "c"); cache_delete(s, "c"); print(file.exists(pc)); writeBin(as.raw(1:3), pc); cache_set(s, "c", as.raw(rep(6, 60))); print(identical(cache_get(s, "c"), as.raw(rep(6,60)))); print(file.mode(pc)); print(nrow(cache_check(s, hash = TRUE)))
cat("== meta limit straddle\n")
mkm <- function(n) codec(paste0("m", n), encode = function(value, path) { writeBin(raw(3), path); list(a = raw(n)) }, decode = function(path, meta) length(meta$a))
base <- length(serialize(list(a = raw(0)), NULL, version = 3L)); n0 <- 4096 - base
for (n in c(n0 - 1, n0, n0 + 1)) { r <- try_({ cache_set(s, "m", 1, codec = mkm(n)); cache_get(s, "m") }); cat(n + base, ": "); print(r) }
for (m in list(data.frame(a = 1), list(1, 2), list(a = 1, 2), c(a = 1), "x", list(), structure(list(a = 1), class = "foo"), list(ext = NULL, a = 1), list(ext = 5))) {
  cd <- codec("mm", encode = function(value, path) { writeBin(raw(30), path); m }, decode = function(path, meta) meta)
  s$codecs$mm <- NULL; r <- try_({ cache_set(s, "mm", 1, codec = cd); cache_get(s, "mm") }); cat(deparse(m)[1], " -> "); if (inherits(r, "err")) print(r) else cat(deparse(r)[1], "| blob:", basename(cache_path(s, "mm")), "\n") }
cat("== garbage format/config at open\n")
for (rec in c("format", "config", "counters")) {
  d <- tempfile(); s <- cache(d); cache_set(s, "a", 1); E(s, function(txn) D$engine_put(txn, NULL, rec, as.raw(1:10))); cache_close(s)
  r <- try_(cache(d)); cat(rec, ": "); if (inherits(r, "err")) print(r) else { cat("opened; get: "); print(try_(cache_get(r, "a"))); cat(" set: "); print(try_(class(cache_set(r, "b", 1)))); cache_close(r) } }
d <- tempfile(); s <- cache(d); cache_set(s, "a", 1); E(s, function(txn) D$engine_del(txn, NULL, "counters")); print(try_(cache_volume(s))); print(try_(cache_set(s, "b", 2))); print(try_(cache_check(s, repair = TRUE)))
d <- tempfile(); s <- cache(d); E(s, function(txn) D$engine_put(txn, NULL, "config", serialize(list(size_limit = "big", eviction = "weird", inline_max = NA_real_, codec = "nope"), NULL))); cache_close(s)
r <- try_(cache(d)); if (inherits(r, "err")) print(r) else { print(try_(cache_set(r, "a", raw(5)))); print(try_(cache_get(r, "a"))) }
