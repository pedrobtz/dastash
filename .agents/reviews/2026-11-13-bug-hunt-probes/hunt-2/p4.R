source("h.R")
E <- function(s, f) D$engine_write(s$engine, f, timeout = 5)
db <- function(s, n) D$engine_db(s$engine, n)
keys <- c("i_raw","i_str","b1","b2","b3","f")
mk <- function() { s <- newc(inline_max = 50); cache_set(s, "i_raw", as.raw(1:5)); cache_set(s, "i_str", "héllo"); cache_set(s, "b1", as.raw(rep(1,100))); cache_set(s, "b2", as.raw(rep(1,100))); cache_set(s, "b3", 1:200, expire = 3600, tags = "t"); f <- tempfile(fileext=".txt"); writeLines("file!", f); cache_set(s, "f", f, codec = codec_file()); s }
getall <- function(s) for (k in keys) { cat(k, ": "); r <- try_(cache_get(s, k)); if (inherits(r, "err")) print(r) else cat(class(r), length(r), "\n") }
chk <- function(s, hash = TRUE) { r <- try_(cache_check(s, hash = hash)); print(if (inherits(r,"err")) r else r[, c("kind","key","detail")]); r <- try_(cache_check(s, repair = TRUE, hash = hash)); print(if (inherits(r,"err")) r else r[, c("kind","key","repaired")]); r <- try_(cache_check(s, hash=TRUE)); cat("after repair findings:", if (inherits(r,"err")) "ERR" else nrow(r), "\n"); getall(s); try_(st(s)); print(blobs(s)) }

cat("=== missing inline raw, check only\n"); s <- mk()
E(s, function(txn) D$engine_del(txn, db(s,"values"), "i_raw"))
print(try_(cache_get(s, "i_raw"))); print(try_(cache_get(s, "i_raw", "DEFAULT"))); print(try_(cache_mget(s, c("i_raw","b1"))[1])); chk(s)

cat("=== blob moved to wrong directory\n"); s <- mk()
p <- cache_path(s, "b1"); dir.create(file.path(cache_dir(s), "blobs", "zz")); file.rename(p, file.path(cache_dir(s), "blobs", "zz", basename(p)))
getall(s); chk(s)

cat("=== blob same size wrong bytes\n"); s <- mk()
p <- cache_path(s, "b1"); Sys.chmod(p, "644"); writeBin(as.raw(rep(2,100)), p)
print(cache_get(s, "b1")[1:3]); chk(s, hash = FALSE); 
s <- mk(); p <- cache_path(s, "b1"); Sys.chmod(p, "644"); writeBin(as.raw(rep(2,100)), p); chk(s, hash = TRUE)

cat("=== blob wrong size\n"); s <- mk()
p <- cache_path(s, "b1"); Sys.chmod(p, "644"); writeBin(as.raw(rep(1,99)), p)
getall(s); print(try_(cache_pop(s, "b2"))); print(cache_has(s, c("b1","b2")));
# re-set same content: does it heal?
cache_set(s, "b_new", as.raw(rep(1,100))); print(try_(cache_get(s, "b_new"))); chk(s)

cat("=== blob missing, then set same content\n"); s <- mk()
p <- cache_path(s, "b1"); Sys.chmod(p, "644"); unlink(p)
getall(s); cache_set(s, "b_new", as.raw(rep(1,100))); print(try_(length(cache_get(s, "b_new")))); 
s <- mk(); p <- cache_path(s, "b1"); unlink(p, force=TRUE); chk(s)

cat("=== writable blob, stray files\n"); s <- mk()
p <- cache_path(s, "b1"); Sys.chmod(p, "666")
writeLines("x", file.path(cache_dir(s), "blobs", "README")); writeLines("x", file.path(cache_dir(s), "tmp", "junk")); writeLines("x", file.path(cache_dir(s), "tmp", "999999-1")); writeLines("x", file.path(cache_dir(s), "tmp", paste0(Sys.getpid(), "-777")))
dir.create(file.path(cache_dir(s), "blobs", "ab", "sub"), recursive = TRUE); writeLines("x", file.path(cache_dir(s), "blobs", "ab", "sub", "deep"))
chk(s); print(file.mode(p)); print(list.files(cache_dir(s), recursive = TRUE))
