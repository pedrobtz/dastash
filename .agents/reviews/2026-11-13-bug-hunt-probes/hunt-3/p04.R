source("common.R")
newc <- function(...) { d <- tempfile("c"); cache(d, ...) }
s <- newc()
g <- function() { cache_transact(s, { cache_set(s, "a", 1); signalCondition(simpleError("soft")); return("ret") }); "late" }
show("J", g()); show("J keys", cache_keys(s))
g2 <- function() { cache_transact(s, { cache_set(s, "b", 1); signalCondition(simpleError("soft")); "normal" }) }
show("J2", g2()); show("J2 keys", cache_keys(s))
# realistic: a handled error via tryCatch(..., condition=) is fine; but try a package that signals an error condition as a message-ish: rlang::cnd_signal
g3 <- function() { for (i in 1:2) cache_transact(s, { cache_set(s, paste0("c", i), 1); rlang::cnd_signal(rlang::error_cnd("soft2")) ; next }); "x" }
show("J3", tr(g3())); show("J3 keys", cache_keys(s))
# timeout validation
for (t in list(NA, NA_real_, -1, 0, Inf, 0.5, "1", c(1,2), NULL, TRUE, 1L)) { r <- tr({ x <- newc(timeout = t); cache_set(x, "a", 1); cache_close(x); "ok" }); cat(deparse(t), "->", r, "\n") }
# refcounts
d <- tempfile("c"); hs <- lapply(1:200, function(i) cache(d)); show("refs", hs[[1]]$engine$refs)
for (h in hs[-1]) cache_close(h); for (h in hs[-1]) cache_close(h)
show("refs after closing 199 twice", hs[[1]]$engine$refs); show("still works", tr({cache_set(hs[[1]], "a", 1); cache_get(hs[[1]], "a")}))
cache_close(hs[[1]]); show("reg", length(ls(dazcache:::engine_registry)))
show("use after close", tr(cache_get(hs[[1]], "a"))); show("transact after close", tr(cache_transact(hs[[1]], 1)))
show("double close", tr(cache_close(hs[[1]])))
# spellings
d <- tempfile("c"); dir.create(d); s1 <- cache(d)
ln <- tempfile("ln"); file.symlink(d, ln)
old <- setwd(dirname(d))
s2 <- cache(basename(d)); s3 <- cache(paste0("./", basename(d))); s4 <- cache(paste0(d, "/")); s5 <- cache(ln); s6 <- cache(file.path(d, "..", basename(d)))
setwd(old)
show("refs", s1$engine$refs); show("same engine", all(vapply(list(s2,s3,s4,s5,s6), function(x) identical(x$engine, s1$engine), NA)))
show("dirs", unique(vapply(list(s1,s2,s3,s4,s5,s6), cache_dir, "")))
cache_transact(s1, { cache_set(s5, "viaLink", 1); show("in-txn other handle", cache_get(s3, "viaLink")) })
# case-insensitive spelling
up <- file.path(dirname(d), toupper(basename(d)))
show("upper exists", dir.exists(up))
show("case spelling", tr({ s7 <- cache(up); cache_set(s7, "U", 1); c(identical(s7$engine, s1$engine), cache_get(s1, "U", default = "MISSING")) }))
# ~ spelling
hd <- file.path("~", paste0(".dazhunt3-", Sys.getpid())); 
a <- cache(hd); b <- cache(path.expand(hd)); show("tilde same", identical(a$engine, b$engine)); cache_close(a); cache_close(b); unlink(path.expand(hd), recursive = TRUE)
