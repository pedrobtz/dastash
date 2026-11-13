source("lib.R")
p <- function(label, x) cat(sprintf("%-28s %s\n", label, substr(paste(capture.output(print(x)), collapse=" / "), 1, 400)))
s <- cache(tempfile("c-"))
n <- 0
f <- function(x, y = 2, ...) { n <<- n + 1; list(x = x, y = y, dots = list(...)) }
m <- cache_memoise(f, s)
K <- function(...) tr(cache_memoise_key(m, ...))
p("k x=1", K(1)); p("k x=1,y=2", K(1, 2)); p("k y=2,x=1", K(y = 2, x = 1)); p("k x=1L", K(1L)); p("k partial", K(1, y = 2))
p("k dots", K(1, 2, 3)); p("k dots named", K(1, 2, a = 3)); p("k dots named2", K(1, 2, 3, a = 4)); p("k dots vs list arg", c(K(1, 2, 3, 4), K(1, 2, c(3, 4)), K(1,2,list(3,4))))
p("k no x", K()); p("k y only", K(y = 5))
p("k factor/str", c(K("a"), K(factor("a"))))
p("k fn arg", K(sum)); p("k env", K(globalenv())); p("k pkgver", K(packageVersion("rlang")))
p("k df", K(data.frame(a = 1:2)))
p("k NULL", K(NULL)); p("k NA", K(NA))
p("call counts", {n <- 0; m(1); m(1, 2); m(y = 2, x = 1); m(1L); n})
p("dots distinct", {n <- 0; m(1, 2, 3); m(1, 2, a = 3); m(1, 2, 3); n})
p("forget", {cache_forget(m, 1); n <- 0; m(1); n})
p("keys", cache_keys(s))
# defaults depending on other args and lazy
g <- function(a, b = a * 2, c = stop("lazy")) a + b
mg <- cache_memoise(g, s)
p("g key", tr(cache_memoise_key(mg, 1))); p("g call", tr(mg(1))); p("g(1,2) same key as g(1)?", identical(cache_memoise_key(mg, 1), cache_memoise_key(mg, 1, 2)))
# missing() semantic
h <- function(a, b) if (missing(b)) "nob" else b
mh <- cache_memoise(h, s); p("missing b", tr(c(mh(1), mh(1, "B"), mh(1))))
# NULL result, invisible
nn <- 0; z <- function(x) { nn <<- nn + 1; NULL }; mz <- cache_memoise(z, s); p("NULL result cached", {mz(1); mz(1); nn})
iv <- function(x) invisible(x); miv <- cache_memoise(iv, s); p("invisible miss", withVisible(miv(1))$visible); p("invisible hit", withVisible(miv(1))$visible)
# errors not cached
ne <- 0; e <- function(x) { ne <<- ne + 1; stop("boom") }; me <- cache_memoise(e, s); p("error", {tr(me(1)); tr(me(1)); ne})
# name collisions / version
p("anon", tr(cache_memoise(function(x) x, s)))
p("name slash", tr(cache_memoise(f, s, name = "a/b"))); p("name opener", tr(cache_memoise(f, s, name = "s:x"))); p("name NA", tr(cache_memoise(f, s, name = NA_character_))); p("name empty", tr(cache_memoise(f, s, name = "")))
p("name nl", tr(cache_memoise_key(cache_memoise(f, s, name = "a\nb"), 1)))
p("ns name", tr(cache_memoise_key(cache_memoise(base::identity, s), 1)))
p("version 2", tr(cache_memoise_key(cache_memoise(f, s, version = 2), 1)))
p("version 1.5", tr(cache_memoise(f, s, version = 1.5))); p("version -1", tr(cache_memoise(f, s, version = -1)))
p("version 1e5", tr(cache_memoise_key(cache_memoise(f, s, version = 1e5), 1)))
p("version 1e15", tr(cache_memoise_key(cache_memoise(f, s, version = 1e15), 1)))
p("version 2^31", tr(suppressWarnings(cache_memoise_key(cache_memoise(f, s, version = 2^31), 1))))
p("version '1'", tr(cache_memoise(f, s, version = "1"))); p("version NULL", tr(cache_memoise(f, s, version = NULL)))
p("version 10 vs 1 forget_all", {m1 <- cache_memoise(f, s, name = "vv", version = 1); m10 <- cache_memoise(f, s, name = "vv", version = 10); m1(1); m10(1); cache_forget_all(m1); cache_keys(s, prefix = "vv/")})
p("forget_all prefix clash", {ma <- cache_memoise(f, s, name = "q"); ma(1); cache_set(s, "q/video", 1); cache_forget_all(ma); cache_keys(s, prefix = "q")})
p("forget_all name prefix", {ma <- cache_memoise(f, s, name = "nm"); mb <- cache_memoise(f, s, name = "nm2"); ma(1); mb(1); cache_forget_all(ma); cache_keys(s, prefix = "nm")})
# omit / key
mo <- cache_memoise(f, s, omit = "y", name = "fo"); p("omit", c(cache_memoise_key(mo, 1, 5), cache_memoise_key(mo, 1)))
p("omit dots", tr(cache_memoise_key(cache_memoise(f, s, omit = "...", name = "fo2"), 1, 2, 3)))
p("omit unknown", tr(cache_memoise_key(cache_memoise(f, s, omit = "nope", name = "fo3"), 1)))
p("omit all", tr(cache_memoise_key(cache_memoise(f, s, omit = c("x", "y"), name = "fo4"), 1)))
p("omit NA", tr(cache_memoise(f, s, omit = NA_character_))); p("omit num", tr(cache_memoise(f, s, omit = 1)))
mk <- cache_memoise(f, s, key = function(args) args$x, name = "fk"); p("key fn", c(cache_memoise_key(mk, "abc"), cache_memoise_key(mk, 1), cache_memoise_key(mk, "{x}")))
p("key fn partial $", tr(cache_memoise_key(cache_memoise(function(xlong, x2) 1, s, key = function(args) args$x, name = "fk2"), 1, 2)))
p("key fn returns key obj", tr(cache_memoise_key(cache_memoise(f, s, key = function(args) cache_key("zz"), name = "fk3"), 1)))
p("key fn nonfn", tr(cache_memoise(f, s, key = "x")))
# args named like internals
w <- function(frame, mc, info, f, cache, n, key) paste(frame, mc, info, f, cache, n, key)
mw <- cache_memoise(w, s); p("internal names", tr(c(mw(1, 2, 3, 4, 5, 6, 7), cache_memoise_key(mw, 1, 2, 3, 4, 5, 6, 7))))
# primitive / no-arg
p("primitive", tr({ms <- cache_memoise(sum, s); c(ms(1, 2, 3), ms(1, 2, 3), cache_memoise_key(ms, 1, 2, 3))}))
p("no-arg", tr({z0 <- function() 42; m0 <- cache_memoise(z0, s); c(m0(), cache_memoise_key(m0))}))
# double memoise, non-fn
p("double", tr(cache_memoise(m, s))); p("nonfn", tr(cache_memoise(1, s))); p("is", c(is_cache_memoised(m), is_cache_memoised(f)))
p("forget nonmemo", tr(cache_forget(f, 1))); p("print", tr(capture.output(print(m))[1]))
# expire/tags args
p("memo expire", {mx <- cache_memoise(f, s, expire = 100, tags = c("t2", "t1"), name = "fx"); mx(1); i <- cache_info(s, cache_memoise_key(mx, 1)); list(round(as.numeric(i$expires) - as.numeric(Sys.time())), i$tags[[1]])})
p("memo expire ct", tr({mx <- cache_memoise(f, s, expire = Sys.time() - 10, name = "fx2"); n <- 0; mx(1); mx(1); n}))
p("memo bad expire", tr(cache_memoise(f, s, expire = "a"))); p("memo bad tags", tr(cache_memoise(f, s, tags = 1)))
# language args, quote
q <- function(e) deparse(e); mq <- cache_memoise(q, s); p("lang arg", tr(mq(quote(a + b))))
# S4/R5 arg
# long key
p("long arg", tr({ml <- cache_memoise(function(x) nchar(x), s, name = "long"); c(ml(strrep("x", 5000)), ml(strrep("x", 5000)), ml(strrep("x", 5001)))}))
p("long arg near collision", tr({ml(paste0(strrep("x", 6000), "a")) ; ml(paste0(strrep("x", 6000), "bb"))}))
# closed cache
p("closed", tr({s9 <- cache(tempfile()); m9 <- cache_memoise(f, s9); cache_close(s9); m9(1)}))
# match.arg-like & same-name different positional
p("positional vs named dots", c(K(1, 2, x2 = 3), K(1, 2, 3)))
p("dots named 'name'", K(1, 2, name = 3, value = 4))
p("dots collision", c(K(1, 2, list(name = "", value = 3)), K(1, 2, 3)))
