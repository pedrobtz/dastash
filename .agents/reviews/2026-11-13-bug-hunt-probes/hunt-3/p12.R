source("common.R")
d <- tempfile("c"); s <- cache(d); cache_set(s, "seed", 1)
big <- function(i) as.raw(rep(i, 50000))
# 8 procs incr + same-blob set/delete churn + memo
worker <- function(d, id) {
  library(dazcache); s <- cache(d, timeout = 60)
  big <- function(i) as.raw(rep(i, 50000))
  m <- cache_memoise(function(x) { Sys.sleep(0.3); cache_incr(s, "memo_runs"); Sys.getpid() }, s, name = "race")
  r <- m(1)
  errs <- character()
  for (i in 1:40) {
    cache_incr(s, "n")
    e <- tryCatch({
      cache_set(s, paste0("b", id), big(7))        # same bytes from all procs
      v <- cache_get(s, paste0("b", (id %% 8) + 1), default = NULL)
      if (!is.null(v) && !identical(v, big(7))) stop("wrong bytes")
      if (i %% 2 == 0) cache_delete(s, paste0("b", id))
      if (i %% 5 == 0) { p <- cache_pop(s, paste0("b", (id %% 8) + 1), default = NULL); if (!is.null(p) && !identical(p, big(7))) stop("wrong pop") }
      NULL }, error = function(e) paste(class(e)[1], conditionMessage(e)))
    if (!is.null(e)) errs <- c(errs, e)
  }
  cache_close(s); list(r = r, errs = errs)
}
bgs <- lapply(1:8, function(id) callr::r_bg(worker, list(d, id), libpath = LP))
for (b in bgs) b$wait()
res <- lapply(bgs, function(b) tr(b$get_result()))
show("errs", unique(unlist(lapply(res, `[[`, "errs")))); show("memo values", vapply(res, function(r) r$r, 1L))
show("n (320)", cache_get(s, "n")); show("memo runs", cache_get(s, "memo_runs"))
show("keys", cache_keys(s)); show("files", files(d)); show("tmp", list.files(file.path(d, "tmp"))); show("check", cache_check(s, hash = TRUE)); show("stats", cache_stats(s)[1:4])
