# The cachem interface (design.md §3.10) and base generics (§3.9).

#' Use a stash through the cachem interface
#'
#' Returns an object with the methods of a 'cachem' cache — `get()`, `set()`,
#' `exists()`, `remove()`, `reset()`, `keys()`, `prune()`, `size()` and
#' `info()` — so code written for 'cachem', such as `memoise::memoise()` and
#' Shiny's `bindCache()`, can store in a stash. Keys follow 'cachem''s rule,
#' lower-case letters, digits, `_` and `-`, and are stored under `prefix`.
#'
#' @inheritParams stash_get
#' @param ... Must be empty.
#' @param prefix Where in the stash the keys live.
#' @param expire,codec Passed to [stash_set()] on every `set()`.
#'
#' @return A list of functions with class `c("dastash_cachem", "cachem")`.
#'
#' @examplesIf requireNamespace("memoise", quietly = TRUE)
#' s <- local_stash()
#' cache <- as_cachem(s)
#' cache$set("answer", 42)
#' cache$get("answer")
#' cache$keys()
#'
#' slow_double <- function(x) x * 2
#' fast_double <- memoise::memoise(slow_double, cache = cache)
#' fast_double(21)
#' @export
as_cachem <- function(stash, ..., prefix = "cachem/", expire = NULL, codec = NULL) {
  rlang::check_dots_empty()
  check_open(stash)
  check_string(prefix, "prefix", rlang::current_env())
  if (starts_with_opener(prefix)) {
    abort_key_invalid("`prefix` cannot start like an encoded key.")
  }
  parse_expire(expire, 0)
  key_missing <- structure(list(), class = "key_missing")
  full <- function(key) {
    if (!is.character(key) || length(key) != 1L || is.na(key) || !grepl("^[a-z0-9_-]+$", key)) {
      abort_key_invalid(
        "A cachem key must be one string of lower-case letters, digits, `_` and `-`.",
        call = rlang::caller_env()
      )
    }
    paste0(prefix, key)
  }
  keys <- function() {
    substring(stash_keys(stash, prefix = prefix), nchar(prefix) + 1L)
  }
  structure(
    list(
      get = function(key, missing = key_missing) stash_get(stash, full(key), default = missing),
      set = function(key, value) {
        stash_set(stash, full(key), value, expire = expire, codec = codec)
        invisible(TRUE)
      },
      exists = function(key) stash_has(stash, full(key)),
      remove = function(key) {
        stash_delete(stash, full(key))
        invisible(TRUE)
      },
      reset = function() {
        stash_evict(stash, prefix = prefix)
        invisible(TRUE)
      },
      keys = keys,
      prune = function() {
        stash_cull(stash)
        invisible(TRUE)
      },
      size = function() length(keys()),
      info = function() {
        list(dir = stash_dir(stash), prefix = prefix, size_limit = stash$config$size_limit)
      }
    ),
    class = c("dastash_cachem", "cachem")
  )
}

#' @export
print.dastash_cachem <- function(x, ...) {
  info <- x$info()
  cat("<dastash_cachem> ", info$dir, " under ", encodeString(info$prefix, quote = "\""), "\n", sep = "")
  invisible(x)
}

#' Base generics for a stash
#'
#' `length(s)` is [stash_count()]; `s[[key]]` is [stash_get()], an error on a
#' miss; `s[[key]] <- value` is [stash_set()]; `as.list(s)` reads every value,
#' warning above 1000 entries and refusing above 100,000. `names()`, `[` and
#' `$` are not provided: listing is [stash_keys()], and a subset of a cache is
#' not a cache.
#'
#' @param x A stash.
#' @param i A key.
#' @param value The value to store.
#' @param ... Must be empty.
#'
#' @return `length()` an integer; `[[` the value; `[[<-` the stash;
#'   `as.list()` a named list.
#'
#' @examples
#' s <- local_stash()
#' s[["a"]] <- 1
#' s[["a"]]
#' length(s)
#' as.list(s)
#' @name stash-generics
NULL

#' @rdname stash-generics
#' @export
length.dastash_stash <- function(x) {
  stash_count(x)
}

#' @rdname stash-generics
#' @export
`[[.dastash_stash` <- function(x, i, ...) {
  rlang::check_dots_empty()
  stash_get(x, i)
}

#' @rdname stash-generics
#' @export
`[[<-.dastash_stash` <- function(x, i, ..., value) {
  rlang::check_dots_empty()
  stash_set(x, i, value)
  x
}

#' @rdname stash-generics
#' @export
as.list.dastash_stash <- function(x, ...) {
  rlang::check_dots_empty()
  keys <- stash_keys(x)
  if (length(keys) > 1e5) {
    abort_unsupported("This stash has more than 100,000 entries; read them with `stash_mget()` in pages.")
  }
  if (length(keys) > 1000) {
    rlang::warn(sprintf("Reading all %d values of this stash into memory.", length(keys)))
  }
  stash_mget(x, lapply(keys, stash_key_text), default = NULL)
}
