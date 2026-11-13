source("common.R")
big <- function(i) as.raw(rep(i, 50000))
d <- tempfile("c"); s <- cache(d, timeout = 20); cache_set(s, "a", 1); cache_set(s, "blob", big(1))
flag <- tempfile("flag")
holder <- function(d, flag, hold) { library(dazcache); s <- cache(d); cache_transact(s, { file.create(flag); Sys.sleep(hold) }); cache_close(s) }
sigint_later <- function(delay) callr::r_bg(function(pid, delay) { Sys.sleep(delay); tools::pskill(pid, tools::SIGINT) }, list(Sys.getpid(), delay))
# 1 interrupt while waiting busy in cache_set of a blob
bg <- callr::r_bg(holder, list(d, flag, 3), libpath = LP); while (!file.exists(flag)) Sys.sleep(0.01)
k <- sigint_later(1)
t <- system.time(r <- tryCatch({cache_set(s, "w", big(5)); "set"}, interrupt = function(c) "interrupted"))[[3]]
show("int in busy wait", list(r, t)); show("engine", list(is.null(s$engine$txn), s$engine$write)); show("tmp", list.files(file.path(d, "tmp")))
bg$wait(); show("after: keys", cache_keys(s)); show("write ok", tr({cache_set(s, "w2", big(6)); "ok"}))
# 2 interrupt in cache_transact body via SIGINT during sleep, after blob writes & delete
k <- sigint_later(1)
r <- tryCatch(cache_transact(s, { cache_set(s, "t1", big(8)); cache_delete(s, "blob"); v <- cache_pop(s, "w2"); Sys.sleep(5); "finished" }), interrupt = function(c) "interrupted")
show("int in transact", r); show("keys", cache_keys(s)); show("blob ok", identical(cache_get(s, "blob"), big(1))); show("w2 ok", identical(cache_get(s, "w2"), big(6)))
show("tmp", list.files(file.path(d, "tmp"))); show("check", cache_check(s)[, c("kind","repaired")])
# 3 interrupt during reap wait: delete a blob while lock is grabbed right after commit? approximate: interrupt in cache_mset encode
k <- sigint_later(0.5)
r <- tryCatch({ cache_mset(s, setNames(lapply(1:300, function(i) as.raw(sample(0:255, 2e5, TRUE))), paste0("m", 1:300))); "set" }, interrupt = function(c) "interrupted")
show("int in mset", r); show("count m", length(cache_keys(s, prefix = "m"))); show("tmp", length(list.files(file.path(d, "tmp")))); show("check", nrow(cache_check(s)))
show("engine", list(is.null(s$engine$txn), s$engine$write)); show("write", tr({cache_set(s, "fin", 1); "ok"}))
# 4 busy timeout with staged blob: tmp cleaned?
s0 <- cache(d, timeout = 0.2); unlink(flag)
bg <- callr::r_bg(holder, list(d, flag, 1.5), libpath = LP); while (!file.exists(flag)) Sys.sleep(0.01)
show("busy blob set", class(tryCatch(cache_set(s0, "bb", big(9)), error = function(e) e))[1]); show("tmp", list.files(file.path(d, "tmp")))
show("busy mset", class(tryCatch(cache_mset(s0, list(x = big(10), y = big(11))), error = function(e) e))[1]); show("tmp", list.files(file.path(d, "tmp")))
mm <- cache_memoise(function(x) big(x), s0, name = "mm"); show("memo busy", tryCatch(length(mm(3)), warning = function(w) class(w)[1])); show("tmp", list.files(file.path(d, "tmp")))
bg$wait()
# 5 reap busy: delete a blob then other process takes the lock >5s? skip; do reap with timeout 0 handle contended
show("final check", cache_check(s)[, c("kind","repaired")])
