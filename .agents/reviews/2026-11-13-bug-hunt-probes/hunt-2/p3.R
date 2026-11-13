source("h.R")
E <- function(s, f) D$engine_write(s$engine, f, timeout = 5)
db <- function(s, n) D$engine_db(s$engine, n)
mk <- function() { s <- newc(inline_max = 50); cache_set(s, "i_raw", as.raw(1:5)); cache_set(s, "i_str", "héllo"); cache_set(s, "i_rds", 1:3); cache_set(s, "b1", as.raw(rep(1,100))); cache_set(s, "b2", as.raw(rep(1,100))); cache_set(s, "b3", 1:200, expire = 3600, tags = "t"); s }
getall <- function(s) for (k in c("i_raw","i_str","i_rds","b1","b2","b3")) { cat(k, ": "); r <- try_(cache_get(s, k)); if (inherits(r, "err")) print(r) else cat(class(r), length(r), "\n") }
chk <- function(s) { r <- try_(cache_check(s, hash = TRUE)); print(if (inherits(r,"err")) r else r[, c("kind","key","detail")]); r <- try_(cache_check(s, repair = TRUE, hash = TRUE)); print(if (inherits(r,"err")) r else r[, c("kind","key","repaired")]); r <- try_(cache_check(s, hash=TRUE)); cat("after repair findings:", if (inherits(r,"err")) "ERR" else nrow(r), "\n"); getall(s); try_(st(s)) }

cat("=== missing inline values\n"); s <- mk()
E(s, function(txn) for (k in c("i_raw","i_str","i_rds")) D$engine_del(txn, db(s,"values"), k))
getall(s); print(try_(cache_mget(s, c("i_raw","i_str")))); print(try_(cache_pop(s, "i_raw"))); chk(s)

cat("=== wrong-length inline values\n"); s <- mk()
E(s, function(txn) { D$engine_put(txn, db(s,"values"), "i_raw", as.raw(9)); D$engine_put(txn, db(s,"values"), "i_rds", serialize(1:3, NULL)[1:20]) })
getall(s); print(cache_get(s, "i_raw")); chk(s)

cat("=== garbage meta\n"); s <- mk()
E(s, function(txn) D$engine_put(txn, db(s,"meta"), "i_rds", as.raw(1:10)))
getall(s); print(try_(cache_keys(s))); print(try_(cache_has(s, "i_rds"))); print(try_(cache_entries(s))); print(try_(cache_set(s, "i_rds", 5))); print(try_(cache_delete(s, "i_rds"))); chk(s)

cat("=== garbage counters\n"); s <- mk()
E(s, function(txn) D$engine_put(txn, NULL, "counters", as.raw(1:10)))
getall(s); print(try_(cache_set(s, "zz", 5))); print(try_(cache_stats(s))); chk(s)

cat("=== garbage blobs row\n"); s <- mk()
nm <- names(rows(s, "blobs"))[1]
E(s, function(txn) D$engine_put(txn, db(s,"blobs"), nm, as.raw(1:10)))
getall(s); print(try_(cache_delete(s, "b1"))); chk(s)
