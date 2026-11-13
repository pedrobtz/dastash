source("lib.R")
p <- function(label, x) cat(sprintf("%-28s %s\n", label, substr(paste(capture.output(print(x)), collapse=" / "), 1, 500)))
s <- cache(tempfile("c-"), inline_max = 200)
set.seed(42)
keys <- c("a","b","c", "ab", strrep("L", 600), "é", "{x}")
keyobjs <- c(as.list(keys), list(list(n=1), 1:2, c(a="x")))
model <- list()  # text -> list(value, tags, expire)
txt <- function(k) cache_key_chr(k)
tagsets <- list(NULL, "t1", c("t1","t2"), "t2", character())
vals <- list(1, "str", 1:500, NULL, list(a=1), as.raw(1:10), strrep("z", 1000), TRUE)
bad <- 0
check <- function(step) {
  live <- Filter(function(m) is.infinite(m$expire) || m$expire > Sys.time(), model)
  ks <- cache_keys(s)
  if (!setequal(ks, names(live))) { bad <<- bad + 1; p(paste("KEYS DIFF", step), list(setdiff(ks, names(live)), setdiff(names(live), ks))) }
  e <- cache_entries(s)
  if (!identical(e$key, ks)) { bad <<- bad + 1; p(paste("ENTRIES!=KEYS", step), 1) }
  for (k in names(live)) {
    got <- cache_get(s, cache_key_text(k), default = quote(MISS))
    if (!identical(got, live[[k]]$value)) { bad <<- bad + 1; p(paste("VALUE DIFF", step, substr(k,1,10)), list(got, live[[k]]$value)) }
    et <- e$tags[[match(k, e$key)]]
    if (!identical(et, sort(unique(as.character(live[[k]]$tags))))) { bad <<- bad + 1; p(paste("TAGS DIFF", step, k), list(et, live[[k]]$tags)) }
  }
  for (t in c("t1","t2")) {
    exp <- names(Filter(function(m) t %in% m$tags, live)); got <- cache_entries(s, tag = t)$key
    if (!setequal(exp, got)) { bad <<- bad + 1; p(paste("TAG INDEX DIFF", step, t), list(got=got, exp=exp)) }
  }
  st <- cache_stats(s)
  ea <- { all_keys <- names(model); NULL }
  if (st$count != length(model)) { bad <<- bad + 1; p(paste("COUNT DIFF", step), c(st$count, length(model))) }
  if (length(live) == length(model)) {
    if (st$bytes_inline != sum(e$bytes[e$inline])) { bad <<- bad + 1; p(paste("BYTES_INLINE DIFF", step), c(st$bytes_inline, sum(e$bytes[e$inline]))) }
    ub <- !duplicated(e$blob) & !e$inline
    if (st$bytes_blob != sum(e$bytes[ub])) { bad <<- bad + 1; p(paste("BYTES_BLOB DIFF", step), c(st$bytes_blob, sum(e$bytes[ub]))) }
  }
}
for (step in 1:1500) {
  k <- keyobjs[[sample(length(keyobjs), 1)]]; t <- txt(k)
  op <- sample(c("set","set","mset","add","delete","pop","touch","incr","evict_tag","expire","setexp","evict_prefix","cull"), 1)
  v <- vals[[sample(length(vals), 1)]]; tg <- tagsets[[sample(length(tagsets), 1)]]
  live <- function(t) !is.null(model[[t]]) && (is.infinite(model[[t]]$expire) || model[[t]]$expire > Sys.time())
  switch(op,
    set = { cache_set(s, k, v, tags = tg); model[[t]] <- list(value = v, tags = tg %||% character(), expire = Inf) },
    setexp = { cache_set(s, k, v, tags = tg, expire = -1); model[[t]] <- list(value = v, tags = tg %||% character(), expire = Sys.time() - 1) },
    mset = { if (is.character(k) && length(k) == 1 && is.null(names(k))) { cache_mset(s, setNames(list(v), k), tags = tg); model[[t]] <- list(value = v, tags = tg %||% character(), expire = Inf) } },
    add = { r <- cache_add(s, k, v, tags = tg); if (r != !live(t)) { bad <- bad + 1; p(paste("ADD DIFF", step), r) }; if (r) model[[t]] <- list(value = v, tags = tg %||% character(), expire = Inf) },
    delete = { cache_delete(s, list(k)); model[[t]] <- NULL },
    pop = { r <- cache_pop(s, k, default = quote(MISS)); exp <- if (live(t)) model[[t]]$value else quote(MISS); if (!identical(r, exp)) { bad <- bad + 1; p(paste("POP DIFF", step), list(r, exp)) }; if (live(t)) model[[t]] <- NULL },
    touch = { cache_touch(s, k, 1000); if (live(t)) model[[t]]$expire <- Sys.time() + 1000 },
    incr = { if (live(t) && !isTRUE(model[[t]]$counter)) { r <- tr(cache_incr(s, k)); if (!is.character(r)) { bad <- bad + 1; p(paste("INCR on value", step), r) } } else { r <- cache_incr(s, k, by = 3, default = 10); exp <- if (live(t)) model[[t]]$value + 3 else 13; if (r != exp) { bad <- bad + 1; p(paste("INCR DIFF", step), c(r, exp)) }; if (live(t)) model[[t]]$value <- exp else model[[t]] <- list(value = exp, tags = character(), expire = Inf, counter = TRUE) } },
    evict_tag = { cache_evict(s, tag = "t1"); for (n in names(model)) if ("t1" %in% model[[n]]$tags) model[[n]] <- NULL },
    evict_prefix = { cache_evict(s, prefix = "a"); for (n in names(model)) if (startsWith(n, "a")) model[[n]] <- NULL },
    expire = { cache_expire(s); for (n in names(model)) if (!live(n)) model[[n]] <- NULL },
    cull = { cache_cull(s); for (n in names(model)) if (!live(n)) model[[n]] <- NULL })
  
  check(paste(step, op))
  if (bad > 8) break
}
p("bad", bad); p("check", cache_check(s))
