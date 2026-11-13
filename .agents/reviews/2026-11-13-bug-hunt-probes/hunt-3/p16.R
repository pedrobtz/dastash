source("common.R")
big <- function(i) as.raw(rep(i, 50000))
# return with deferred reap
d <- tempfile("c"); s <- cache(d); cache_set(s, "x", big(1))
f <- function() { cache_transact(s, { cache_delete(s, "x"); return(1) }); 2 }
show("ret", f()); show("files", files(d)); show("check", nrow(cache_check(s)))
# reap deferred while other handle closes s inside
cache_set(s, "x", big(1)); s2 <- cache(d)
cache_transact(s, { cache_delete(s, "x"); cache_close(s) }); show("files after close-inside w/ 2 handles", files(d)); show("s closed, s2 works", list(cache_is_open(s), cache_keys(s2)))
# 8 procs first-open the same new dir simultaneously, with differing configs
d2 <- tempfile("c"); go <- tempfile("go")
w <- function(d, go, id) { library(dazcache); while (!file.exists(go)) Sys.sleep(0.001); r <- tryCatch({ s <- cache(d, inline_max = 1000 * id, timeout = 30); cache_set(s, paste0("k", id), id); x <- s$config$inline_max; cache_close(s); x }, error = function(e) paste(class(e)[1], conditionMessage(e))); r }
bgs <- lapply(1:8, function(i) callr::r_bg(w, list(d2, go, i), libpath = LP)); Sys.sleep(2); file.create(go); for (b in bgs) b$wait()
show("concurrent create", sapply(bgs, function(b) tr(b$get_result())))
s3 <- cache(d2); show("keys", cache_keys(s3)); show("check", nrow(cache_check(s3))); show("cfg", s3$config$inline_max)
# reap busy: A deletes blob; B grabs lock right after A's commit for > reap timeout
d4 <- tempfile("c"); a <- cache(d4, timeout = 0.3); cache_set(a, "x", big(4)); flag <- tempfile("f")
# B waits for lock (blocked by A's transact), gets it at A's commit, holds 2s
bg <- callr::r_bg(function(d, flag) { library(dazcache); s <- cache(d, timeout = 30); file.create(flag); cache_transact(s, Sys.sleep(2)); cache_close(s) }, list(d4, flag), libpath = LP)
t <- system.time(r <- tr(cache_transact(a, { cache_delete(a, "x"); while (!file.exists(flag)) Sys.sleep(0.01); Sys.sleep(0.5); "committed" })))[[3]]
show("delete w/ reap contended", list(r, t)); show("x gone", !cache_has(a, "x")); show("files", files(d4)); bg$wait(); show("check", cache_check(a)[, c("kind", "repaired")])
