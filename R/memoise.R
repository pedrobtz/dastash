# Memoisation (design.md §3.8). A memoised function keys each call on
# `<name>/v<version>/` and the canonical encoding of its matched arguments,
# defaults filled in, so the key is specified text: it survives R upgrades,
# prefix-scans, and never depends on the function's body.

#' Memoise a function in a cache
#'
#' @description
#' `cache_memoise()` returns a function that looks each call up in the cache
#' first, and on a miss calls `f` and stores what it returns. The cache outlives
#' the session and is shared by every process using the cache.
#'
#' The key of a call is the function's `name`, `version` and its arguments,
#' matched to `f`'s formals with defaults filled in: `f(1)` and
#' `f(1, verbose = FALSE)` are one entry when `FALSE` is the default. It does
#' not depend on `f`'s code; change `version` when a change in meaning should
#' invalidate what is stored. An argument that cannot be part of a key — a
#' connection, an environment, a function — is an error at call time: leave it
#' out with `omit`, or supply `key`.
#'
#' Two processes missing the same call at once both run `f`, and one result
#' is kept. That is duplicated work, never a wrong result.
#'
#' If the cache cannot store a result because its write lock stayed busy, it is
#' full or it is read-only, the result is returned anyway, with a warning of
#' class `dazcache_memoise_unstored`. A codec that cannot store it is an error.
#'
#' A result stored as a file, with `codec = codec_file()`, is the path of the
#' cached file on a miss as on a hit, not the path `f` returned.
#'
#' `cache_memoise_key()` returns the key a call would use, `cache_forget()`
#' deletes one call's entry, and `cache_forget_all()` every entry of the
#' function.
#'
#' @inheritParams cache_get
#' @param f A function.
#' @param ... For `cache_memoise()`, must be empty. For the others, the
#'   arguments of a call to the memoised function.
#' @param expire,tags,codec Passed to [cache_set()] when a result is stored.
#' @param key `NULL`, or a function of the list of matched arguments returning
#'   a key, to key calls on something else than every argument.
#' @param omit Names of arguments to leave out of the key.
#' @param version A whole number, part of every key, up to `2^53`: a date
#'   stamp such as `20261113120000` will do.
#' @param name The function's name in its keys. Defaults to the name `f` was
#'   passed as; an anonymous function needs one.
#'
#' @return `cache_memoise()` returns the memoised function.
#'   `cache_memoise_key()` returns a key's text. `cache_forget()` and
#'   `cache_forget_all()` return the memoised function, invisibly.
#'   `is_cache_memoised()` returns `TRUE` or `FALSE`.
#'
#' @examples
#' s <- local_cache()
#' slow_square <- function(x, verbose = FALSE) {
#'   Sys.sleep(0.1)
#'   x^2
#' }
#' fast_square <- cache_memoise(slow_square, s)
#' fast_square(4)
#' fast_square(4)
#' cache_memoise_key(fast_square, 4)
#' cache_forget(fast_square, 4)
#'
#' # Keep an argument out of the key.
#' fit <- cache_memoise(
#'   function(data_id, verbose = FALSE) data_id * 2,
#'   s,
#'   name = "fit",
#'   omit = "verbose"
#' )
#' identical(cache_memoise_key(fit, 1), cache_memoise_key(fit, 1, verbose = TRUE))
#' @export
cache_memoise <- function(
  f,
  cache,
  ...,
  expire = NULL,
  tags = NULL,
  codec = NULL,
  key = NULL,
  omit = NULL,
  version = 1L,
  name = NULL
) {
  check_dots()
  check_supplied(c("f", "cache"))
  call <- rlang::current_env()
  if (!is.function(f)) {
    abort_type_error("`f` must be a function.", call = call)
  }
  if (is_cache_memoised(f)) {
    abort_type_error("`f` is already memoised.", call = call)
  }
  check_open(cache, call)
  name <- name %||% memo_default_name(substitute(f))
  if (is.null(name)) {
    abort_key_invalid(
      c(
        "An anonymous function needs a `name` to key its results by.",
        i = "Supply `name =`."
      ),
      call = call
    )
  }
  check_string(name, "name")
  if (grepl("/", name, fixed = TRUE) || starts_with_opener(name)) {
    abort_key_invalid(
      "`name` cannot contain `/` or start like an encoded key.",
      call = call
    )
  }
  check_number(version, "version", min = 0, whole = TRUE, max = 2^53)
  if (!is.null(key) && !is.function(key)) {
    abort_type_error(
      "`key` must be NULL or a function of the matched arguments.",
      call = call
    )
  }
  if (!is.null(omit) && (!is.character(omit) || anyNA(omit))) {
    abort_type_error(
      "`omit` must be a character vector of argument names.",
      call = call
    )
  }
  parse_expire(expire, 0, call = call)
  parse_tags(tags, call = call)
  if (!is.null(codec) && !is_codec(codec)) {
    abort_codec_error("`codec` must be NULL or a codec.", call = call)
  }
  # Every call reads what an earlier one stored with it, in any process.
  codec_register(cache, codec)

  fmls <- formals(args(f))
  info <- list(
    f = f,
    cache = cache,
    name = name,
    # A double, written as whole digits: a date-stamp version such as
    # 20261113120000 is past the integer range.
    version = sprintf("%.0f", version),
    formals = fmls,
    key = key,
    omit = omit,
    expire = expire,
    tags = tags,
    codec = codec
  )
  env <- new.env(parent = environment(f) %||% baseenv())
  env$`_dazcache_memo` <- info
  memoised <- rlang::new_function(
    fmls,
    as.call(list(
      memo_call,
      quote(environment()),
      quote(match.call(expand.dots = FALSE)),
      quote(`_dazcache_memo`)
    )),
    env
  )
  # The same formals, computing only the key: shared by the companions.
  info$key_of <- rlang::new_function(
    fmls,
    as.call(list(
      memo_key_of,
      quote(environment()),
      quote(match.call(expand.dots = FALSE)),
      quote(`_dazcache_memo`)
    )),
    env
  )
  env$`_dazcache_memo` <- info
  structure(memoised, class = c("dazcache_memoised", "function"))
}

#' @rdname cache_memoise
#' @export
cache_memoise_key <- function(f, ...) {
  memo_info(f)$key_of(...)
}

#' @rdname cache_memoise
#' @export
cache_forget <- function(f, ...) {
  info <- memo_info(f)
  cache_delete(info$cache, info$key_of(...))
  invisible(f)
}

#' @rdname cache_memoise
#' @export
cache_forget_all <- function(f) {
  info <- memo_info(f)
  check_writable(info$cache)
  prefix <- key_prefix(paste0(info$name, "/v"))
  # Only `<name>/v<digits>/...`: a user's `<name>/video` is not the function's.
  evict_prefix_where(info$cache, prefix, function(text) {
    startsWith(text, prefix) &
      grepl("^[0-9]+/", substring(text, nchar(prefix) + 1L))
  })
  invisible(f)
}

#' @rdname cache_memoise
#' @export
is_cache_memoised <- function(f) {
  inherits(f, "dazcache_memoised")
}

#' @export
print.dazcache_memoised <- function(x, ...) {
  info <- memo_info(x)
  cat(
    "<dazcache_memoised> ",
    info$name,
    " v",
    info$version,
    " in ",
    info$cache$dir,
    "\n",
    sep = ""
  )
  print(info$f, ...)
  invisible(x)
}

memo_info <- function(f, call = rlang::caller_env()) {
  if (!is_cache_memoised(f)) {
    abort_type_error(
      "`f` must be a function made by `cache_memoise()`.",
      call = call
    )
  }
  environment(f)$`_dazcache_memo`
}

# The symbol `f` was passed as, or NULL for an anonymous function.
memo_default_name <- function(expr) {
  if (is.symbol(expr)) {
    return(as.character(expr))
  }
  if (
    is.call(expr) &&
      (identical(expr[[1L]], quote(`::`)) ||
        identical(expr[[1L]], quote(`:::`)))
  ) {
    return(as.character(expr[[3L]]))
  }
  NULL
}

# The body of a memoised function.
memo_call <- function(frame, mc, info) {
  args <- memo_collect(frame, mc, info)
  key <- memo_key_text(info, args$key, call = sys.call(-1L))
  hit <- memo_lookup(info$cache, key)
  if (!is.null(hit)) {
    # As visible as the producer's result was when it was stored (#109).
    return(if (hit$visible) hit$value else invisible(hit$value))
  }
  result <- withVisible(do.call(info$f, args$call, quote = TRUE))
  # The result is computed, and a cache may forget (design.md §4): when the
  # cache cannot take it for now, return it anyway. A codec that refuses it is
  # a mistake in the setup, and stays an error.
  stored <- tryCatch(
    {
      cache_set_entry(
        info$cache,
        key,
        result$value,
        expire = info$expire,
        tags = info$tags,
        codec = info$codec,
        extra = if (!result$visible) list(invisible = TRUE)
      )
      TRUE
    },
    dazcache_busy = function(cnd) memo_unstored(info, cnd),
    dazcache_store_full = function(cnd) memo_unstored(info, cnd),
    dazcache_readonly = function(cnd) memo_unstored(info, cnd)
  )
  value <- result$value
  # A file-backed result is the stored file on a miss as on a hit, not the
  # producer's own (design.md §3.8); the producer's when it was not stored, or
  # the entry is gone already.
  if (isTRUE(stored) && memo_file_backed(info, value)) {
    value <- cache_get(info$cache, key, default = value)
  }
  if (result$visible) value else invisible(value)
}

# A stored result and whether to return it visibly, or NULL on a miss.
memo_lookup <- function(cache, key) {
  check_open(cache)
  key <- store_key(key)
  hit <- engine_read(cache$engine, function(txn) {
    store_read_entry(cache, txn, key)
  })
  value <- if (!is.null(hit)) store_decode_entry(cache, hit, key)
  if (is.null(value)) {
    return(NULL)
  }
  list(value = value[[1L]], visible = !isTRUE(hit$record$invisible))
}

memo_file_backed <- function(info, value) {
  codec <- info$codec %||% info$cache$codec
  !is.null(codec) && identical(codec_for_value(codec, value)$name, "file")
}

memo_key_of <- function(frame, mc, info) {
  memo_key_text(info, memo_collect(frame, mc, info)$key, call = sys.call(-1L))
}


# The arguments of a call, evaluated once: `call` to pass to the function (as
# supplied), and `key` to key it by (defaults filled in, `omit` left out).
memo_collect <- function(frame, mc, info) {
  fmls <- info$formals
  supplied <- setdiff(names(as.list(mc))[-1L], c("", "..."))
  values <- list()
  for (n in supplied) {
    values[n] <- list(get(n, envir = frame))
  }
  dots <- if ("..." %in% names(fmls)) eval(quote(list(...)), frame) else list()

  key <- values
  for (n in setdiff(names(fmls), c(supplied, "..."))) {
    if (rlang::is_missing(fmls[[n]])) {
      next
    }
    # A default is evaluated as the function would, in the call's frame; one
    # that cannot be evaluated here depends on the body, and so on the other
    # arguments, which are keyed already.
    value <- tryCatch(list(get(n, envir = frame)), error = function(cnd) NULL)
    if (!is.null(value)) key[n] <- value
  }
  if (length(dots) > 0L) {
    # Dots are positional and may be named: a list of name and value, in order.
    nms <- names(dots) %||% rep("", length(dots))
    key[["..."]] <- lapply(seq_along(dots), function(i) {
      list(name = nms[[i]], value = dots[[i]])
    })
  }
  key <- key[setdiff(names(key), info$omit)]
  list(call = c(values, dots), key = key)
}

memo_key_text <- function(info, args, call) {
  body <- if (is.null(info$key)) {
    key_canon(args, call = call)
  } else {
    key_canon(info$key(args), call = call)
  }
  paste0(info$name, "/v", info$version, "/", body)
}

memo_unstored <- function(info, cnd) {
  warn_unstored(
    sprintf("The result of `%s()` was returned but not stored.", info$name),
    parent = cnd
  )
  FALSE
}
