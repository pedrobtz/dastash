source("h.R")
# straddle inline_max with raw
s <- newc(inline_max = 100)
cache_set(s, "a99", raw(99)); cache_set(s, "a100", raw(100)); cache_set(s, "a101", as.raw(1:101))
print(cache_entries(s)[, c("key","bytes","codec","inline")])
st(s)
# empty values
cache_set(s, "e_raw", raw(0)); cache_set(s, "e_str", ""); 
print(try_(cache_get(s, "e_raw"))); print(try_(cache_get(s, "e_str")))
s0 <- newc(inline_max = 0)
cache_set(s0, "e_raw", raw(0)); cache_set(s0, "e_str", ""); cache_set(s0, "n", NULL)
print(try_(cache_get(s0, "e_raw"))); print(try_(cache_get(s0, "e_str"))); print(try_(cache_get(s0,"n")))
print(cache_entries(s0)[, c("key","bytes","codec","inline","blob")]); st(s0)
print(try_(cache_incr(s0, "c"))); print(cache_get(s0,"c")); print(cache_info(s0,"c")[,c("bytes","inline","codec")]); st(s0)
print(try_(cache_path(s0, "c")))
# rds compress straddle
x <- rep(1L, 1000)
s <- newc(inline_max = 200)
cache_set(s, "u", x); cache_set(s, "c", x, codec = codec_rds(compress = TRUE))
print(cache_entries(s)[, c("key","bytes","codec","inline")])
stopifnot(identical(cache_get(s,"u"), x), identical(cache_get(s,"c"), x)); st(s)
# file modes
p <- cache_path(s, "u"); print(file.mode(p)); print(identical(readRDS(p), x)); print(file.size(p))
# numbers
for (v in list(NA, -1, 1.5, Inf, 2^31, NA_integer_, c(1,2), "a")) print(try_(newc(inline_max = v)))
for (v in list(NA, -1, 0, 1.5, Inf, 2^31)) {r <- try_(newc(size_limit = v)); if (inherits(r,"err")) print(r) else cat("size_limit ok", v, "\n")}
for (v in list(NA, 0, 1.5, Inf, 2^31)) {r <- try_(newc(cull_limit = v)); if (inherits(r,"err")) print(r) else cat("cull ok", v, r$cull_limit, "\n")}
s <- newc(inline_max = 2^31+5); cache_set(s, "a", 1:10); print(cache_get(s,"a"))
