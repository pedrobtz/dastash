source("common.R")
big <- function(i) as.raw(rep(i, 50000))
d <- tempfile("c"); s <- cache(d, timeout = 2); cache_set(s, "a", 1)
r <- cache_transact(s, { cache_set(s, "t", big(1)); j <- parallel::mcparallel(tr(cache_get(s, "t"))); x <- parallel::mccollect(j); cache_set(s, "t2", 2); x })
show("fork in transact child", r); show("parent keys", cache_keys(s)); show("check", nrow(cache_check(s)))
show("other proc write after", callr::r(function(d) { library(dazcache); x <- cache(d, timeout = 2); cache_set(x, "o", 1); cache_keys(x) }, list(d), libpath = LP))
# mclapply children then parent state + gc in child
r <- parallel::mclapply(1:4, function(i) { gc(); tr(cache_set(s, "c", i)) }); show("mclapply", unique(substr(unlist(r), 1, 40)))
show("parent write", tr({cache_set(s, "p", big(2)); cache_keys(s)})); show("check", nrow(cache_check(s)))
# replace crash leaves blob mode
d2 <- tempfile("c")
callr::r(function(d) { library(dazcache); s <- cache(d); cache_set(s, "keep", as.raw(rep(1, 50000))); cache_close(s) }, list(d2), libpath = LP)
try(callr::r(function(d) { library(dazcache); s <- cache(d); cache_transact(s, { cache_delete(s, "keep"); cache_set(s, "again", as.raw(rep(1, 50000))) }) }, list(d2), libpath = LP, env = c(callr::rcmd_safe_env(), DAZCACHE_CRASH = "replace")), silent = TRUE)
s2 <- cache(d2); show("mode of live blob after replace-crash", as.character(file.mode(cache_path(s2, "keep")))); show("check", cache_check(s2, repair = TRUE, hash = TRUE)[, c("kind","repaired")]); show("mode after repair", as.character(file.mode(cache_path(s2, "keep"))))
