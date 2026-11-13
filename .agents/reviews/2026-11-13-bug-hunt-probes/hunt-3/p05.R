source("common.R")
mk <- function() { d <- tempfile("c"); s <- cache(d); cache_set(s, "a", 1); cache_close(s); d }
# dropped readonly then writable
d <- mk(); local({ r <- cache(d, readonly = TRUE); cache_get(r, "a") }); invisible(gc()); invisible(gc())
show("writable after dropped RO", tr({ w <- cache(d); cache_set(w, "b", 2); "ok" }))
show("reg refs", dazcache:::engine_registry[[ls(dazcache:::engine_registry)[1]]]$refs)
# closed RO then writable
d <- mk(); r <- cache(d, readonly = TRUE); cache_close(r); show("writable after closed RO", tr({ w <- cache(d); cache_set(w, "b", 2); cache_close(w); "ok" }))
# RO held, writable
d <- mk(); r <- cache(d, readonly = TRUE); show("W while RO open", tr(cache(d)))
show("RO still fine", tr(cache_get(r, "a"))); show("refs", r$engine$refs); cache_close(r)
# W held, RO
d <- mk(); w <- cache(d); r <- cache(d, readonly = TRUE)
show("RO write", tr(cache_set(r, "x", 1))); show("RO transact", tr(cache_transact(r, 1)))
show("RO write inside W transact", tr(cache_transact(w, cache_set(r, "x", 1))))
show("RO sees in-txn", cache_transact(w, { cache_set(w, "t", 1); cache_get(r, "t") }))
cache_close(w); show("RO after W closed", tr(cache_get(r, "t"))); show("engine readonly flag", r$engine$readonly)
show("W reopen while RO-on-W-engine open", tr({ w2 <- cache(d); cache_set(w2, "q", 1); "ok" }))
# RO with error in readonly failing cache() : refs unchanged?
d <- mk(); r <- cache(d, readonly = TRUE); for (i in 1:3) tr(cache(d)); show("refs after 3 failed W opens", r$engine$refs); cache_close(r); show("reg has d", any(startsWith(ls(dazcache:::engine_registry), normalizePath(d))))
# dropped writable, gc, another PROCESS writes
d <- mk(); local({ w <- cache(d); cache_set(w, "z", 1) }); invisible(gc())
show("other proc write with dropped handle here", callr::r(function(d) { library(dazcache); s <- cache(d, timeout = 2); cache_set(s, "o", 1); cache_keys(s) }, list(d), libpath = LP))
# local_cache / with_cache
f <- function() { s <- local_cache(); cache_set(s, "a", 1); s }
s <- f(); show("local closed", c(cache_is_open(s), dir.exists(cache_dir(s))))
f2 <- function(d) { s <- local_cache(d); stop("x") }; d <- mk(); try(f2(d), silent = TRUE)
show("reg has d after error", any(startsWith(ls(dazcache:::engine_registry), normalizePath(d))))
show("with_cache err", tr(with_cache(d, function(s) stop("y")))); show("reg has d", any(startsWith(ls(dazcache:::engine_registry), normalizePath(d))))
show("with_cache inside transact", { s <- cache(d); r <- tr(cache_transact(s, { with_cache(d, function(x) cache_set(x, "wc", 1)); stop("abort") })); list(r, cache_keys(s)) })
# local_cache temp dir with second handle: unlink while open
g <- function() { s <- local_cache(); cache_set(s, "a", 1); cache(cache_dir(s)) }
s2 <- g(); show("second handle on deleted local_cache dir", list(open = cache_is_open(s2), direxists = dir.exists(cache_dir(s2)), get = tr(cache_get(s2, "a")), set = tr({cache_set(s2, "b", as.raw(rep(1, 1e5))); "ok"})))
# delete directory under an open handle, then reopen
d <- mk(); s <- cache(d); unlink(d, recursive = TRUE); s2 <- tr(cache(d))
show("reopen after unlink w/o close", tr({ cache_set(s2, "new", 1); list(keys = cache_keys(s2), files = files(d)) }))
show("other proc sees", tr(callr::r(function(d) { library(dazcache); s <- cache(d, timeout = 2); cache_keys(s) }, list(d), libpath = LP)))
