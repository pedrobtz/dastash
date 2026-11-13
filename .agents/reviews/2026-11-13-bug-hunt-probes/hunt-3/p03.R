source("common.R")
big <- function(i) as.raw(rep(i, 50000))
newc <- function(...) { d <- tempfile("c"); cache(d, ...) }
# A: close only handle inside transact
s <- newc(); d <- cache_dir(s)
show("A close inside", tr(cache_transact(s, { cache_set(s, "a", 1); cache_close(s); 5 })))
show("A is_open", cache_is_open(s)); show("A registry", ls(dazcache:::engine_registry))
s <- cache(d); show("A keys after", cache_keys(s)); cache_close(s)
# A2: close inside, reopen inside, write
s <- cache(d)
show("A2", tr(cache_transact(s, { cache_set(s, "a", 1); cache_close(s); s2 <- cache(d); cache_set(s2, "b", 2); 5 })))
show("A2 keys", tr(cache_keys(s2))); show("A2 reg", ls(dazcache:::engine_registry))
show("A2 engine", tr({e <- s2$engine; list(txn = is.null(e$txn), write = e$write, refs = e$refs)}))
tr(cache_close(s2))
# B: close one of two handles inside
s <- newc(); d <- cache_dir(s); s2 <- cache(d)
show("B", tr(cache_transact(s, { cache_set(s, "a", 1); cache_close(s2); cache_set(s, "b", 2); 5 })))
show("B keys", cache_keys(s)); show("B use closed", tr(cache_get(s2, "a")))
# B2: close the transacting handle but another remains
s2 <- cache(d)
show("B2", tr(cache_transact(s, { cache_set(s, "c", 1); cache_close(s); cache_set(s2, "d", 2); 5 })))
show("B2 keys", cache_keys(s2))
# C: nested error caught inside
s <- newc()
show("C", tr(cache_transact(s, { cache_set(s, "a", 1); try(cache_transact(s, { cache_set(s, "b", 2); stop("inner") }), silent = TRUE); cache_set(s, "c", 3); "done" })))
show("C keys", cache_keys(s))
# D: return / break / next
s <- newc()
f <- function() { cache_transact(s, { cache_set(s, "r", 1); return("early") }); "late" }
show("D return", f()); 
for (i in 1:3) cache_transact(s, { cache_set(s, paste0("brk", i), i); if (i == 2) break })
for (i in 1:3) cache_transact(s, { cache_set(s, paste0("nxt", i), i); next })
show("D keys", cache_keys(s)); show("D eng", list(is.null(s$engine$txn), s$engine$write))
# E: error after blob writes; files
s <- newc(); d <- cache_dir(s)
cache_set(s, "old", big(1))
show("E", tr(cache_transact(s, { cache_set(s, "b1", big(2)); cache_delete(s, "old"); cache_set(s, "b2", big(3)); show("E inside count", cache_count(s)); stop("boom") })))
show("E keys", cache_keys(s)); show("E files", files(d)); show("E check", tr(cache_check(s)))
show("E old readable", identical(cache_get(s, "old"), big(1)))
show("E check repair", tr(cache_check(s, repair = TRUE))); show("E files", files(d))
# F: delete blob and re-set same bytes inside transact, then abort / commit
s <- newc(); d <- cache_dir(s); cache_set(s, "x", big(7))
show("F", tr(cache_transact(s, { cache_delete(s, "x"); cache_set(s, "y", big(7)); stop("x") })))
show("F get", identical(cache_get(s, "x"), big(7))); show("F check", cache_check(s))
cache_transact(s, { cache_delete(s, "x"); cache_set(s, "y", big(7)) })
show("F2 get", identical(cache_get(s, "y"), big(7))); show("F2 check", cache_check(s)); show("F2 files", files(d))
cache_transact(s, { cache_delete(s, "y"); cache_set(s, "y", big(7)); cache_delete(s, "y") })
show("F3 files", files(d)); show("F3 check", cache_check(s))
# G: pop of blob inside transact; then abort
s <- newc(); d <- cache_dir(s); cache_set(s, "x", big(9))
show("G", tr(cache_transact(s, { v <- cache_pop(s, "x"); stopifnot(identical(v, big(9))); stop("abort") })))
show("G get", identical(cache_get(s, "x"), big(9))); show("G files", files(d)); show("G check", cache_check(s))
# H: other dir inside block
s <- newc(); o <- newc()
show("H", tr(cache_transact(s, { cache_set(s, "a", 1); cache_set(o, "o", 1); stop("x") })))
show("H keys", list(cache_keys(s), cache_keys(o)))
# I: interrupt
s <- newc()
show("I", tr(cache_transact(s, { cache_set(s, "a", 1); rlang::interrupt(); 1 })))
show("I keys", cache_keys(s)); show("I eng", list(is.null(s$engine$txn), s$engine$write))
show("I write after", tr({cache_set(s, "z", 1); cache_keys(s)}))
# J: signalCondition non-terminating error then return
s <- newc()
g <- function() { cache_transact(s, { cache_set(s, "a", 1); signalCondition(simpleError("soft")); return("ret") }); "late" }
show("J", tr(g())); show("J keys", cache_keys(s))
g2 <- function() { cache_transact(s, { cache_set(s, "b", 1); signalCondition(simpleError("soft")); "normal" }) }
show("J2", tr(g2())); show("J2 keys", cache_keys(s))
# K: error handled by restart from calling handler outside
s <- newc()
r <- withCallingHandlers(
  cache_transact(s, { cache_set(s, "a", 1); withRestarts(stop("x"), skip = function() "skipped"); cache_set(s, "b", 2); "fin" }),
  error = function(c) invokeRestart("skip"))
show("K", r); show("K keys", cache_keys(s))
# K2: warning as error via options(warn=2) caught by try inside
