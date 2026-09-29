# Memoisation (design.md §3.8). A memoised function keys each call on
# `<name>/v<version>/` and the canonical encoding of its matched arguments,
# defaults filled in, so the key is specified text: it survives R upgrades,
# prefix-scans, and never depends on the function's body.

#' Memoise a function in a stash
#'
#' @description
#' `stash_memoise()` returns a function that looks each call up in the stash
#' first, and on a miss calls `f` and stores what it returns. The cache outlives
#' the session and is shared by every process using the stash.
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
#' `stash_memoise_key()` returns the key a call would use, `stash_forget()`
#' deletes one call's entry, and `stash_forget_all()` every entry of the
#' function.
#'
#' @param f A function.
#' @param stash A stash, from [stash()].
#' @param ... For `stash_memoise()`, must be empty. For the others, the
#'   arguments of a call to the memoised function.
#' @param expire,tags,codec Passed to [stash_set()] when a result is stored.
#' @param key `NULL`, or a function of the list of matched arguments returning
#'   a key, to key calls on something else than every argument.
#' @param omit Names of arguments to leave out of the key.
#' @param version A whole number, part of every key.
#' @param name The function's name in its keys. Defaults to the name `f` was
#'   passed as; an anonymous function needs one.
#'
#' @return `stash_memoise()` returns the memoised function.
#'   `stash_memoise_key()` returns a key's text. `stash_forget()` and
#'   `stash_forget_all()` return the memoised function, invisibly.
#'   `is_stash_memoised()` returns `TRUE` or `FALSE`.
#'
#' @examples
#' s <- local_stash()
#' slow_square <- function(x, verbose = FALSE) {
#'   Sys.sleep(0.1)
#'   x^2
#' }
#' fast_square <- stash_memoise(slow_square, s)
#' fast_square(4)
#' fast_square(4)
#' stash_memoise_key(fast_square, 4)
#' stash_forget(fast_square, 4)
#'
#' # Keep an argument out of the key.
#' fit <- stash_memoise(function(data_id, verbose = FALSE) data_id * 2, s,
#'   name = "fit", omit = "verbose")
#' identical(stash_memoise_key(fit, 1), stash_memoise_key(fit, 1, verbose = TRUE))
#' @export
stash_memoise <- function(f, stash, ..., expire = NULL, tags = NULL, codec = NULL,
                          key = NULL, omit = NULL, version = 1L, name = NULL) {
  rlang::check_dots_empty()
  call <- rlang::current_env()
  if (!is.function(f)) {
    abort_type_error("`f` must be a function.", call = call)
  }
  if (is_stash_memoised(f)) {
    abort_type_error("`f` is already memoised.", call = call)
  }
  check_open(stash, call)
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
  check_string(name, "name", call)
  if (grepl("/", name, fixed = TRUE) || starts_with_opener(name)) {
    abort_key_invalid("`name` cannot contain `/` or start like an encoded key.", call = call)
  }
  check_number(version, "version", call, min = 0, whole = TRUE)
  if (!is.null(key) && !is.function(key)) {
    abort_type_error("`key` must be NULL or a function of the matched arguments.", call = call)
  }
  if (!is.null(omit) && (!is.character(omit) || anyNA(omit))) {
    abort_type_error("`omit` must be a character vector of argument names.", call = call)
  }
  parse_expire(expire, 0, call = call)
  parse_tags(tags, call = call)
  if (!is.null(codec) && !is_codec(codec)) {
    abort_codec_error("`codec` must be NULL or a codec.", call = call)
  }

  fmls <- formals(args(f))
  info <- list(
    f = f, stash = stash, name = name, version = as.integer(version), formals = fmls,
    key = key, omit = omit, expire = expire, tags = tags, codec = codec
  )
  env <- new.env(parent = environment(f) %||% baseenv())
  env$`_dastash_memo` <- info
  memoised <- rlang::new_function(
    fmls,
    as.call(list(memo_call, quote(environment()), quote(match.call(expand.dots = FALSE)), quote(`_dastash_memo`))),
    env
  )
  # The same formals, computing only the key: shared by the companions.
  info$key_of <- rlang::new_function(
    fmls,
    as.call(list(memo_key_of, quote(environment()), quote(match.call(expand.dots = FALSE)), quote(`_dastash_memo`))),
    env
  )
  env$`_dastash_memo` <- info
  structure(memoised, class = c("dastash_memoised", "function"))
}

#' @rdname stash_memoise
#' @export
stash_memoise_key <- function(f, ...) {
  memo_info(f)$key_of(...)
}

#' @rdname stash_memoise
#' @export
stash_forget <- function(f, ...) {
  info <- memo_info(f)
  stash_delete(info$stash, info$key_of(...))
  invisible(f)
}

#' @rdname stash_memoise
#' @export
stash_forget_all <- function(f) {
  info <- memo_info(f)
  stash_evict(info$stash, prefix = paste0(info$name, "/v"))
  invisible(f)
}

#' @rdname stash_memoise
#' @export
is_stash_memoised <- function(f) {
  inherits(f, "dastash_memoised")
}

#' @export
print.dastash_memoised <- function(x, ...) {
  info <- memo_info(x)
  cat(
    "<dastash_memoised> ", info$name, " v", info$version,
    " in ", info$stash$dir, "\n",
    sep = ""
  )
  print(info$f, ...)
  invisible(x)
}

memo_info <- function(f, call = rlang::caller_env()) {
  if (!is_stash_memoised(f)) {
    abort_type_error("`f` must be a function made by `stash_memoise()`.", call = call)
  }
  environment(f)$`_dastash_memo`
}

# The symbol `f` was passed as, or NULL for an anonymous function.
memo_default_name <- function(expr) {
  if (is.symbol(expr)) {
    return(as.character(expr))
  }
  if (is.call(expr) && (identical(expr[[1L]], quote(`::`)) || identical(expr[[1L]], quote(`:::`)))) {
    return(as.character(expr[[3L]]))
  }
  NULL
}

# The body of a memoised function.
memo_call <- function(frame, mc, info) {
  args <- memo_collect(frame, mc, info)
  key <- memo_key_text(info, args$key, call = sys.call(-1L))
  hit <- stash_get(info$stash, key, default = memo_miss)
  if (!identical(hit, memo_miss)) {
    return(hit)
  }
  result <- withVisible(do.call(info$f, args$call, quote = TRUE))
  stash_set(info$stash, key, result$value, expire = info$expire, tags = info$tags, codec = info$codec)
  if (result$visible) result$value else invisible(result$value)
}

memo_key_of <- function(frame, mc, info) {
  memo_key_text(info, memo_collect(frame, mc, info)$key, call = sys.call(-1L))
}

# Stands for a miss: no stored value can be identical to this environment.
memo_miss <- new.env(parent = emptyenv())

# The arguments of a call, evaluated once: `call` to pass to the function (as
# supplied), and `key` to key it by (defaults filled in, `omit` left out).
memo_collect <- function(frame, mc, info) {
  fmls <- info$formals
  supplied <- setdiff(names(as.list(mc))[-1L], c("", "..."))
  values <- list()
  for (n in supplied) values[n] <- list(get(n, envir = frame))
  dots <- if ("..." %in% names(fmls)) eval(quote(list(...)), frame) else list()

  key <- values
  for (n in setdiff(names(fmls), c(supplied, "..."))) {
    if (rlang::is_missing(fmls[[n]])) next
    # A default is evaluated as the function would, in the call's frame; one
    # that cannot be evaluated here depends on the body, and so on the other
    # arguments, which are keyed already.
    value <- tryCatch(list(get(n, envir = frame)), error = function(cnd) NULL)
    if (!is.null(value)) key[n] <- value
  }
  if (length(dots) > 0L) {
    # Dots are positional and may be named: a list of name and value, in order.
    nms <- names(dots) %||% rep("", length(dots))
    key[["..."]] <- lapply(seq_along(dots), function(i) list(name = nms[[i]], value = dots[[i]]))
  }
  key <- key[setdiff(names(key), info$omit)]
  list(call = c(values, dots), key = key)
}

memo_key_text <- function(info, args, call) {
  body <- if (is.null(info$key)) key_canon(args, call = call) else key_canon(info$key(args), call = call)
  paste0(info$name, "/v", info$version, "/", body)
}
