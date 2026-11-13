source("common.R")
big <- function(i) as.raw(rep(i, 50000))
run <- function(point, fn) {
  d <- tempfile("c")
  callr::r(function(d) { library(dazcache); s <- cache(d); cache_set(s, "keep", as.raw(rep(1, 50000))); cache_set(s, "small", 1); cache_close(s) }, list(d), libpath = LP)
  r <- tr(callr::r(fn, list(d), libpath = LP, env = c(callr::rcmd_safe_env(), DAZCACHE_CRASH = point)))
  s <- cache(d, timeout = 1)
  out <- list(child = substr(r, 1, 60), keys = cache_keys(s), keep = identical(cache_get(s, "keep", default = NULL), big(1)),
    stats = unlist(cache_stats(s)[1:3]), nblobs = length(list.files(file.path(d, "blobs"), recursive = TRUE)), tmp = list.files(file.path(d, "tmp")),
    check = cache_check(s)[, c("kind", "repaired")], write = tr({cache_set(s, "after", big(9)); "ok"}))
  out$repair <- cache_check(s, repair = TRUE, hash = TRUE)[, c("kind", "repaired")]; out$check2 <- nrow(cache_check(s, hash = TRUE))
  out$keep2 <- identical(cache_get(s, "keep", default = NULL), big(1))
  cache_close(s); show(point, out)
}
run("publish", function(d) { library(dazcache); s <- cache(d); cache_set(s, "new", as.raw(rep(2, 50000))) })
run("publish", function(d) { library(dazcache); s <- cache(d); cache_transact(s, { cache_delete(s, "keep"); cache_set(s, "small", 2); cache_set(s, "new", as.raw(rep(2, 50000))) }) })
# replace: delete keep then set same bytes in one txn -> orphan replaced -> crash before rename
run("replace", function(d) { library(dazcache); s <- cache(d); cache_transact(s, { cache_delete(s, "keep"); cache_set(s, "again", as.raw(rep(1, 50000))) }) })
run("unlink", function(d) { library(dazcache); s <- cache(d); cache_delete(s, "keep") })
run("unlink", function(d) { library(dazcache); s <- cache(d); cache_set(s, "keep", 5) })
