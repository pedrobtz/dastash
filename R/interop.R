# The cachem interface (design.md §3.10) and base generics (§3.9).

#' Use a cache through the cachem interface
#'
#' @description
#' Returns an object with the methods of a cachem cache — `get()`, `set()`,
#' `exists()`, `remove()`, `reset()`, `keys()`, `prune()`, `size()` and
#' `info()` — so code written for cachem, such as `memoise::memoise()` and
#' Shiny's `bindCache()`, can store in a cache. Keys follow cachem's rule,
#' lower-case letters, digits, `_` and `-`, and are stored under `prefix`.
#'
#' @inheritParams cache_get
#' @param ... Must be empty.
#' @param prefix Where in the cache the keys live. It must end with a
#'   character a cachem key cannot contain, such as `/`, so that two adapters
#'   never share keys; the adapter lists and resets only its own keys.
#' @param expire,codec Passed to [cache_set()] on every `set()`.
#'
#' @return A list of functions with class `c("dazcache_cachem", "cachem")`.
#'
#' @examplesIf requireNamespace("memoise", quietly = TRUE)
#' s <- local_cache()
#' cache <- as_cachem(s)
#' cache$set("answer", 42)
#' cache$get("answer")
#' cache$keys()
#'
#' slow_double <- function(x) x * 2
#' fast_double <- memoise::memoise(slow_double, cache = cache)
#' fast_double(21)
#' @export
as_cachem <- function(
  cache,
  ...,
  prefix = "cachem/",
  expire = NULL,
  codec = NULL
) {
  rlang::check_dots_empty()
  check_open(cache)
  check_string(prefix, "prefix")
  prefix <- key_prefix(prefix)
  if (starts_with_opener(prefix)) {
    abort_key_invalid("`prefix` cannot start like an encoded key.")
  }
  if (grepl("[a-z0-9_-]$", prefix)) {
    abort_key_invalid(c(
      "`prefix` must end with a character a cachem key cannot contain, such as `/`.",
      i = "Otherwise `prefix = \"a\"` would also own the keys of `prefix = \"a2\"`."
    ))
  }
  # The adapter's own keys: the prefix and one cachem key, nothing deeper.
  own <- function(text) {
    startsWith(text, prefix) &
      grepl("^[a-z0-9_-]+$", substring(text, nchar(prefix) + 1L))
  }
  parse_expire(expire, 0)
  key_missing <- structure(list(), class = "key_missing")
  full <- function(key) {
    if (
      !is.character(key) ||
        length(key) != 1L ||
        is.na(key) ||
        !grepl("^[a-z0-9_-]+$", key)
    ) {
      abort_key_invalid(
        "A cachem key must be one string of lower-case letters, digits, `_` and `-`.",
        call = rlang::caller_env()
      )
    }
    paste0(prefix, key)
  }
  keys <- function() {
    text <- cache_keys(cache, prefix = prefix)
    substring(text[own(text)], nchar(prefix) + 1L)
  }
  structure(
    list(
      get = function(key, missing = key_missing) {
        cache_get(cache, full(key), default = missing)
      },
      set = function(key, value) {
        cache_set(cache, full(key), value, expire = expire, codec = codec)
        invisible(TRUE)
      },
      exists = function(key) cache_has(cache, full(key)),
      remove = function(key) {
        cache_delete(cache, full(key))
        invisible(TRUE)
      },
      reset = function() {
        check_writable(cache)
        evict_prefix_where(cache, prefix, own)
        invisible(TRUE)
      },
      keys = keys,
      prune = function() {
        cache_cull(cache)
        invisible(TRUE)
      },
      size = function() length(keys()),
      info = function() {
        list(
          dir = cache_dir(cache),
          prefix = prefix,
          size_limit = cache$config$size_limit
        )
      }
    ),
    class = c("dazcache_cachem", "cachem")
  )
}

#' @export
print.dazcache_cachem <- function(x, ...) {
  info <- x$info()
  cat(
    "<dazcache_cachem> ",
    info$dir,
    " under ",
    encodeString(info$prefix, quote = "\""),
    "\n",
    sep = ""
  )
  invisible(x)
}

#' Base generics for a cache
#'
#' @description
#' `length(s)` is [cache_count()]; `s[[key]]` is [cache_get()], an error on a
#' miss; `s[[key]] <- value` is [cache_set()]; `as.list(s)` reads every value,
#' warning above 1000 entries and refusing above 100,000. `names()`, `[` and
#' `$` are not provided: listing is [cache_keys()], and a subset of a cache is
#' not a cache.
#'
#' @param x A cache.
#' @param i A key.
#' @param value The value to store.
#' @param ... Must be empty.
#'
#' @return `length()` an integer; `[[` the value; `[[<-` the cache;
#'   `as.list()` a named list.
#'
#' @examples
#' s <- local_cache()
#' s[["a"]] <- 1
#' s[["a"]]
#' length(s)
#' as.list(s)
#' @name cache-generics
NULL

#' @rdname cache-generics
#' @export
length.dazcache_cache <- function(x) {
  cache_count(x)
}

#' @rdname cache-generics
#' @export
`[[.dazcache_cache` <- function(x, i, ...) {
  rlang::check_dots_empty()
  cache_get(x, i)
}

#' @rdname cache-generics
#' @export
`[[<-.dazcache_cache` <- function(x, i, ..., value) {
  rlang::check_dots_empty()
  cache_set(x, i, value)
  x
}

#' @rdname cache-generics
#' @export
as.list.dazcache_cache <- function(x, ...) {
  rlang::check_dots_empty()
  keys <- cache_keys(x)
  if (length(keys) > 1e5) {
    abort_unsupported(
      "This cache has more than 100,000 entries; read them with `cache_mget()` in pages."
    )
  }
  if (length(keys) > 1000) {
    rlang::warn(sprintf(
      "Reading all %d values of this cache into memory.",
      length(keys)
    ))
  }
  cache_mget(x, lapply(keys, cache_key_text), default = NULL)
}
