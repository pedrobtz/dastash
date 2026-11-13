source("common.R")
d <- tempfile("c"); s <- cache(d)
n <- 0
m <- cache_memoise(function(x) { n <<- n + 1; x + 1 }, s, name = "inc")
cm <- as_cachem(s); cm$set("k", 5)
m(1); cache_close(s)
show("memo after close", tr(m(1))); show("cachem after close", tr(cm$get("k"))); show("cachem info after close", tr(cm$info())); show("forget after close", tr(cache_forget(m, 1)))
s2 <- cache(d); show("memo after reopen dir (other handle)", tr(m(1)))
m2 <- cache_memoise(function(x) stop("should hit"), s2, name = "inc"); show("m2 hit", m2(1)); show("n", n)
# producer writes same cache / nested memo / inside transact
inner <- cache_memoise(function(x) x * 2, s2, name = "inner")
outer <- cache_memoise(function(x) { cache_set(s2, "side", x); inner(x) + 1 }, s2, name = "outer")
show("outer", outer(3)); show("keys", cache_keys(s2))
show("outer in transact abort", tr(cache_transact(s2, { outer(4); stop("abort") }))); show("keys", cache_keys(s2))
show("outer in transact", cache_transact(s2, outer(4))); show("keys", cache_keys(s2))
# producer errors: nothing stored
bad <- cache_memoise(function(x) { cache_set(s2, "pre", 1); stop("prod") }, s2, name = "bad"); show("bad", tr(bad(1))); show("keys", cache_keys(s2))
# producer spawns callr writer on same cache
sp <- cache_memoise(function(x) callr::r(function(d) { library(dazcache); s <- cache(d, timeout = 3); cache_set(s, "fromchild", 1); cache_close(s); 42 }, list(d), libpath = LP), s2, name = "sp")
show("sp", tr(sp(1))); show("keys", cache_keys(s2))
show("sp in transact (child must be busy)", tr(cache_transact(s2, sp(2))))
# producer that closes the cache
cl <- cache_memoise(function(x) { cache_close(s2); x }, s2, name = "cl"); show("closing producer", tr(cl(1)))
s3 <- cache(d)
# producer deletes own key / forget inside
# readonly memo
cache_close(s3); r <- cache(d, readonly = TRUE)
mr <- cache_memoise(function(x) x + 100, r, name = "ro"); show("ro memo", tryCatch(mr(1), warning = function(w) class(w)))
show("ro memo hit of existing", mr2 <- cache_memoise(function(x) stop("no"), r, name = "inc")(1))
# memoised returning invisible, NULL
cache_close(r); s <- cache(d)
nul <- cache_memoise(function(x) { n <<- n + 1; NULL }, s, name = "nul"); n <- 0; nul(1); nul(1); show("NULL memo runs", n)
inv <- cache_memoise(function(x) invisible(x), s, name = "inv"); show("inv vis miss", withVisible(inv(1))$visible); show("inv vis hit", withVisible(inv(1))$visible)
# large memo (blob) + forget -> files
bigf <- cache_memoise(function(x) as.raw(rep(x, 1e5)), s, name = "bigf"); invisible(bigf(1)); invisible(bigf(1)); cache_forget(bigf, 1); show("files", files(d)); show("check", cache_check(s))
# memo expire
ex <- cache_memoise(function(x) { n <<- n + 1; x }, s, name = "ex", expire = 0.3); n <- 0; ex(1); ex(1); Sys.sleep(0.4); ex(1); show("expire runs (2)", n)
