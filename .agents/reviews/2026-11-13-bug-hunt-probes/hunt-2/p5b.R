source("h.R")
E <- function(s, f) D$engine_write(s$engine, f, timeout = 5)
db <- function(s, n) D$engine_db(s$engine, n)
which <- commandArgs(TRUE)[1]
if (which == "expire") {
s <- newc(cull_limit = 2)
cache_set(s, "live", 1, expire = 3600)
E(s, function(txn) for (k in c("g1","g2","g3")) D$engine_put(txn, db(s,"expiry"), D$index_key(1000, k), raw()))
cat("check:\n"); print(cache_check(s)[,1:2])
cat("calling cache_expire\n"); cache_expire(s); cat("returned\n")
}
if (which == "stale") {
s <- newc(); cache_set(s, "k", "v", expire = 3600)
E(s, function(txn) D$engine_put(txn, db(s,"expiry"), D$index_key(1000, "k"), raw()))
cache_expire(s); print(cache_has(s, "k")); print(ctr(s)$expired)
}
if (which == "cull") {
s <- newc(cull_limit = 2, size_limit = 10, inline_max = 1000)
E(s, function(txn) for (k in c("g1","g2","g3")) D$engine_put(txn, db(s,"stored"), D$index_key(1000, k), raw()))
cache_set(s, "a", raw(8)); cache_set(s, "b", raw(8)); cache_set(s, "c", raw(8)); print(cache_keys(s)); print(unlist(ctr(s)[c("bytes_inline","evictions")]))
cat("calling cache_cull\n"); cache_cull(s); cat("returned\n")
}
