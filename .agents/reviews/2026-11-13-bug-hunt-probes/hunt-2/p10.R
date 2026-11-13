source("h.R")
E <- function(s, f) D$engine_write(s$engine, f, timeout = 5)
db <- function(s, n) D$engine_db(s$engine, n)
big <- as.raw(rep(1,100)); v3 <- 1:200
mk <- function() { s <- newc(inline_max = 50); cache_set(s, "i", as.raw(1:5)); cache_set(s, "b1", big); cache_set(s, "b2", big); cache_set(s, "b3", v3, expire = 3600, tags = c("t","u")); s }
vals <- list(i = as.raw(1:5), b1 = big, b2 = big, b3 = v3)
verify <- function(s) { for (k in names(vals)) { r <- try_(cache_get(s, k)); cat(" ", k, if (inherits(r,"err")) paste("ERR", r$cls[1]) else if (identical(r, vals[[k]])) "ok" else "WRONG") }; cat("\n") }
chk <- function(s, hash = TRUE) { r <- try_(cache_check(s, hash = hash)); if (inherits(r,"err")) print(r) else print(r[, c("kind","key","detail")], row.names = FALSE); r <- try_(cache_check(s, repair = TRUE, hash = hash)); if (inherits(r,"err")) print(r); r <- try_(cache_check(s, hash=TRUE)); cat("second check findings:", if (inherits(r,"err")) "ERR" else nrow(r), "\n"); if (!inherits(r, "err") && nrow(r)) print(r[, c("kind","key","detail")], row.names = FALSE); verify(s); c <- ctr(s); cat(sprintf("  count=%d inline=%g blob=%g files=%d exp=%d tags=%d\n", cache_count(s), c$bytes_inline, c$bytes_blob, length(blobs(s)), length(cache_entries(s)$expires[!is.na(cache_entries(s)$expires)]), nrow(cache_entries(s, tag = "t")))) }
nmb <- function(s, k) D$record_blob_name(rows(s, "meta")[[k]])

cat("== blobs row deleted (file present, not counted)\n"); s <- mk(); n <- nmb(s, "b1"); E(s, function(txn) D$engine_del(txn, db(s,"blobs"), n)); verify(s)
cache_delete(s, "b1"); cat("after deleting b1 (b2 shares):"); verify(s); chk(s)
cat("== blobs row deleted, then set same content -> republish; then delete one\n"); s <- mk(); n <- nmb(s, "b1"); E(s, function(txn) D$engine_del(txn, db(s,"blobs"), n)); cache_set(s, "b4", big); cache_delete(s, "b4"); verify(s); chk(s)
cat("== refs too high / too low\n"); s <- mk(); n <- nmb(s, "b1"); E(s, function(txn) D$engine_put(txn, db(s,"blobs"), n, serialize(list(refs = 1, bytes = 100, ext = NULL), NULL))); cache_delete(s, "b1"); verify(s); chk(s)
cat("== no row + wrong size file\n"); s <- mk(); n <- nmb(s, "b1"); E(s, function(txn) D$engine_del(txn, db(s,"blobs"), n)); p <- cache_path(s, "b1"); Sys.chmod(p, "644"); writeBin(raw(7), p); chk(s, hash = TRUE)
cat("== counters drift\n"); s <- mk(); E(s, function(txn) D$store_counters_add(txn, list(bytes_inline = 1000, bytes_blob = -5000))); chk(s)
cat("== index rows removed / tags\n"); s <- mk(); E(s, function(txn) for (d in c("expiry","stored","tags")) D$engine_clear_db(txn, db(s, d))); print(nrow(cache_entries(s, tag = "t"))); chk(s)
cat("== meta record deleted (value orphan, blob ref orphan)\n"); s <- mk(); E(s, function(txn) for (k in c("i","b3","b1")) D$engine_del(txn, db(s,"meta"), k)); chk(s)
cat("== repair inside transact then abort\n"); s <- mk(); p <- cache_path(s, "b3"); unlink(p, force = TRUE); writeLines("x", file.path(cache_dir(s), "blobs", "ab")); 
print(try_(cache_transact(s, { cache_check(s, repair = TRUE); stop("boom") }))); print(cache_has(s, "b3")); print(nrow(cache_check(s))); 
cat("== blob row bytes wrong but file right\n"); s <- mk(); n <- nmb(s, "b3"); E(s, function(txn) D$engine_put(txn, db(s,"blobs"), n, serialize(list(refs = 1, bytes = 5, ext = "rds"), NULL))); chk(s)
cat("== record bytes wrong on inline\n"); s <- mk(); E(s, function(txn) { r <- unserialize(D$engine_get(txn, db(s,"meta"), "i")); r$bytes <- 500; D$engine_put(txn, db(s,"meta"), "i", serialize(r, NULL)) }); chk(s)
