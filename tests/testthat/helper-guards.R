# The grep guards of design.md §16, done on parsed code rather than text so a
# comment or a string never trips them and a call split over lines never escapes
# them. They walk the installed namespace, which works under R CMD check, where
# the R/ sources are not present.

# Every call in a function: its formals' defaults and its body, recursively,
# including functions defined inside it.
calls_in <- function(fn) {
  out <- list()
  walk <- function(e) {
    if (is.function(e)) {
      walk(formals(e))
      walk(body(e))
      return(invisible())
    }
    if (is.call(e)) out[[length(out) + 1L]] <<- e
    if (is.call(e) || is.pairlist(e) || is.expression(e) || is.list(e)) {
      for (i in seq_along(e)) {
        if (rlang::is_missing(e[[i]])) next
        walk(e[[i]])
      }
    }
    invisible()
  }
  walk(fn)
  out
}

# The name a call is made by: `f(...)` is "f", `pkg::f(...)` is "f".
call_fn_name <- function(call) {
  f <- call[[1]]
  if (is.symbol(f)) return(as.character(f))
  if (is.call(f) && (identical(f[[1]], quote(`::`)) || identical(f[[1]], quote(`:::`)))) {
    return(as.character(f[[3]]))
  }
  NA_character_
}

call_pkg <- function(call) {
  f <- call[[1]]
  if (is.call(f) && (identical(f[[1]], quote(`::`)) || identical(f[[1]], quote(`:::`)))) {
    return(as.character(f[[2]]))
  }
  NA_character_
}

# Named list of the functions in a namespace.
namespace_functions <- function(pkg = "dastash") {
  ns <- asNamespace(pkg)
  fns <- mget(ls(ns, all.names = TRUE), envir = ns)
  Filter(is.function, fns)
}

# One row per violation: which function, which rule.
guard_violations <- function(fns) {
  hits <- character()
  for (name in names(fns)) {
    for (call in calls_in(fns[[name]])) {
      fn <- call_fn_name(call)
      if (is.na(fn)) next
      pkg <- call_pkg(call)

      # serialize() output never reaches a hash; the RDS codec and the meta
      # record are the only functions that call it.
      if (fn == "serialize" && !grepl("^(codec_rds|record_)", name)) {
        hits <- c(hits, sprintf("%s: serialize() outside the RDS codec and meta record", name))
      }
      # digest() only ever hashes bytes it is given.
      if (fn == "digest" && !isFALSE(call$serialize)) {
        hits <- c(hits, sprintf("%s: digest() without serialize = FALSE", name))
      }
      # Every mdbx call lives in the engine file, whose functions are engine_*.
      if ((startsWith(fn, "mdbx_") || identical(pkg, "mdbx")) && !startsWith(name, "engine_")) {
        hits <- c(hits, sprintf("%s: %s() outside R/engine.R", name, fn))
      }
      # Errors come from the taxonomy.
      if (fn == "stop" && (is.na(pkg) || pkg == "base")) {
        hits <- c(hits, sprintf("%s: bare stop()", name))
      }
      if (fn == "abort" && !identical(name, "dastash_abort")) {
        hits <- c(hits, sprintf("%s: rlang::abort() outside dastash_abort()", name))
      }
    }
  }
  unique(hits)
}
