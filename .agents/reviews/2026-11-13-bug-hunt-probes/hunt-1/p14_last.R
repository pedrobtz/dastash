source("lib.R")
p <- function(label, x) cat(sprintf("%-28s %s\n", label, substr(paste(capture.output(print(x)), collapse=" / "), 1, 500)))
s <- suppressWarnings(cache(tempfile("c-"), cull_limit = 2^31))
p("set NA cull: committed?", {r <- tr(cache_set(s, "a", 1)); list(r, cache_has(s, "a"))})
p("get still fine", tr(cache_get(s, "a", default = "MISS")))
s <- cache(tempfile("c-"))
f <- function(x) invisible(x); m <- cache_memoise(f, s)
p("visible miss/hit", c(withVisible(m(1))$visible, withVisible(m(1))$visible))
# as.list on entries with NULL values & structured names
cache_set(s, "n", NULL); cache_set(s, list(a = 1), 2)
p("as.list", tr(as.list(s)))
p("$ / names", tr(list(names(s), is.null(s$nokey))))
# cache_mget w/ default list / NULL stored
p("mget NULL stored vs default", tr(cache_mget(s, c("n", "zz"), default = "D")))
# cache_has on expired; cache_info on expired
cache_set(s, "ex", 1, expire = -1); p("expired", list(cache_has(s, "ex"), cache_info(s, "ex"), cache_get(s, "ex", default = "D"), tr(cache_pop(s, "ex", default = "D")), "ex" %in% cache_entries(s)$key))
# expire as POSIXct equals now + secs route
cache_set(s, "e1", 1, expire = 100); cache_set(s, "e2", 1, expire = Sys.time() + 100); cache_set(s, "e3", 1, expire = as.difftime(100, units = "secs")); cache_set(s, "e4", 1, expire = as.difftime(100/60, units = "mins"))
i <- cache_entries(s, prefix = "e"); p("expire routes", round(diff(as.numeric(i$expires)), 1))
p("expires tz/class", list(class(i$expires), attr(i$expires, "tzone")))
p("int expire big", tr({cache_set(s, "e5", 1, expire = .Machine$integer.max); as.numeric(cache_info(s, "e5")$expires) > 2e9}))
p("ct integer-typed expire", tr({cache_set(s, "e6", 1, expire = .POSIXct(as.integer(Sys.time()) + 100L)); cache_has(s, "e6")}))
