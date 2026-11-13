.libPaths(c("<W>/lib", .libPaths())); suppressMessages(library(dazcache))
s <- cache(tempfile()); u <- rawToChar(as.raw(c(0x63,0x61,0x66,0xc3,0xa9))); print(Encoding(u))
cache_set(s, u, 1); cache_set(s, paste0(u, "/x"), 2)
print(cache_get(s, u)); print(length(cache_keys(s, prefix = u)))
