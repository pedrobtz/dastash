.libPaths(c("<W>/lib", .libPaths())); suppressMessages(library(dazcache))
t <- function(label, expr) { r <- tryCatch(expr, error = function(e) paste("ERR", class(e)[1], conditionMessage(e))); cat(label, ": ", paste(format(r), collapse=" "), "\n", sep="") }
eng <- function(s, db, k, v) dazcache:::engine_write(s$engine, function(txn) if (is.null(v)) dazcache:::engine_del(txn, dazcache:::engine_db(s$engine, db), k) else dazcache:::engine_put(txn, dazcache:::engine_db(s$engine, db), k, v))
# 4: missing inline raw value reads NULL
s <- cache(tempfile()); cache_set(s, "r", as.raw(1:5)); st <- dazcache:::store_key("r")$stored
t("4 del values", tryCatch(eng(s, "values", st, NULL), error=function(e) conditionMessage(e))); t("4 get", cache_get(s, "r", default="DEFAULT"))
# 8: same bytes never heal
s <- cache(tempfile(), inline_max = 100); x <- runif(100); cache_set(s, "a", x); p <- cache_path(s, "a"); Sys.chmod(p, "0644"); writeBin(as.raw(1), p)
cache_set(s, "new", x); t("8 get new", { v <- cache_get(s, "new"); identical(v, x) })
# 11: incr no cull
s <- cache(tempfile(), size_limit = 15); cache_set(s, "a", as.raw(1:10)); cache_incr(s, "c"); cache_incr(s, "d"); t("11 held", cache_stats(s)[c("bytes_inline","evictions")])
# 12: meta partial match
s <- cache(tempfile()); cd <- codec("mine", encode = function(value, path) { writeLines(value, path); list(extra = "zzz") }, decode = function(path, meta) readLines(path))
cache_set(s, "m", "hello", codec = cd); t("12 path", basename(tryCatch(cache_path(s, "m"), error=function(e) "inline")))
s2 <- cache(tempfile(), inline_max = 0); cache_set(s2, "m", "hello", codec = cd); t("12 path blob", basename(cache_path(s2, "m")))
# surprise: same-name codec
s <- cache(tempfile())
c1 <- codec("lines", encode = function(value, path) writeLines(value, path), decode = function(path, meta) readLines(path))
c2 <- codec("lines", encode = function(value, path) writeLines(rev(value), path), decode = function(path, meta) rev(readLines(path)))
cache_set(s, "k1", c("1","2"), codec = c1); cache_set(s, "k2", c("1","2"), codec = c2); t("codec same name k2", cache_get(s, "k2"))
