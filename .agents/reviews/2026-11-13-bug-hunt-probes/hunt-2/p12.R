source("h.R")
s <- newc(inline_max = 10)
print(try_(cache_mset(s, list(a = raw(50), b = raw(60), c = file("x")))))
cat("tmp:", tmpf(s), " count:", cache_count(s), " files:", length(blobs(s)), "\n")
print(try_(cache_mset(s, list(a = raw(50), b = raw(60)), tags = NA_character_))); cat("tmp:", tmpf(s), "\n")
# mset where later entry fails inside txn? force by closing... skip
# get after overwrite by another handle on the same dir
s2 <- cache(cache_dir(s)); cache_set(s, "k", as.raw(rep(1, 40))); cache_set(s2, "k", as.raw(rep(2, 40))); print(cache_get(s, "k")[1]); print(length(blobs(s)))
