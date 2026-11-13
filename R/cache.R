# The cache handle and its opening and closing (design.md §3.1).

dazcache_state <- new.env(parent = emptyenv())
dazcache_state$stage <- 0L

#' Open a cache
#'
#' @description
#' `cache()` opens the cache in directory `dir`, creating it if needed, and
#' returns a handle for the other `cache_*()` functions. Any number of R
#' processes on the machine can open the same directory at once; they share it
#' safely.
#'
#' `local_cache()` opens a cache that closes when the calling function returns,
#' in a new temporary directory unless you give one, which is then deleted. At
#' the top level there is no function to return from, so nothing closes it:
#' call `cache_close()` yourself. `with_cache()` opens one, passes it to a
#' function, and closes it afterwards.
#'
#' `cache_close()` closes a handle, `cache_is_open()` says whether it is open,
#' and `cache_dir()` returns its directory.
#'
#' @details
#' `size_limit`, `eviction`, `inline_max` and `codec` belong to the store and are
#' fixed when it is created: a later `cache()` that passes a *different* value
#' raises `dazcache_config_conflict`, and one that leaves them out uses the stored
#' values. The other settings belong to this handle only.
#'
#' A second `cache()` on a directory this process already has open shares the
#' same underlying database; each handle is closed separately. While a
#' read-only handle is open, the same process cannot open the directory for
#' writing: close it first.
#'
#' A handle cannot be used from a forked child process, such as a
#' [parallel::mclapply()] worker; open the cache inside the worker instead.
#'
#' Opening a cache that exists only reads it, so it never waits for another
#' process's write. Writes take the cache's one write lock in turn, waiting up
#' to `timeout` seconds. On Linux and Windows the lock of a process killed
#' while writing is released at once. On macOS and other platforms it is not:
#' every later write raises `dazcache_busy` until every process with the cache
#' open has closed it, after which the next to open it recovers the lock.
#' Reads are not affected.
#'
#' @param dir The cache's directory.
#' @param ... Must be empty.
#' @param size_limit The size, in bytes, the cache is kept under. `Inf` for no
#'   limit. Stored with the cache.
#' @param eviction Which entries make room when the cache is over `size_limit`:
#'   the least recently stored, or `"none"` to never evict. Stored with the
#'   cache. `"least-recently-used"` and `"least-frequently-used"` are not yet
#'   available.
#' @param inline_max Values smaller than this many bytes are kept inside the
#'   database; larger ones become files. Stored with the cache.
#' @param codec The default codec for writes; see [codec()]. Stored with the
#'   cache, by name.
#' @param codecs A list of your own codecs, made with [codec()], that this
#'   handle can read and write.
#' @param durability `"safe"` makes every write durable before it returns.
#'   `"fast"` does not wait for the disk: a crash may lose recent writes but
#'   never damages the cache. `"unsafe"` can damage it in a crash. The first
#'   process to open a cache sets this for everyone who opens it while it is
#'   open.
#' @param map_size The most the database file may grow to, in bytes.
#' @param cull_limit How many entries one eviction step removes at most.
#' @param timeout How long, in seconds, a write waits for another process's
#'   write to finish before raising `dazcache_busy`.
#' @param readonly Open for reading only.
#' @param create Create the directory and the cache if they do not exist.
#'
#' @return `cache()` and `local_cache()` return a `dazcache_cache`.
#'   `with_cache()` returns what `fn` returns. `cache_close()` returns the cache,
#'   invisibly; `cache_is_open()` `TRUE` or `FALSE`; and `cache_dir()` the
#'   cache's directory, normalised.
#'
#' @examples
#' dir <- tempfile("cache-")
#' s <- cache(dir)
#' cache_set(s, "greeting", "hello")
#' cache_get(s, "greeting")
#' cache_close(s)
#' unlink(dir, recursive = TRUE)
#'
#' f <- function() {
#'   s <- local_cache()
#'   cache_set(s, "n", 1:3)
#'   cache_get(s, "n")
#' }
#' f()
#' @export
cache <- function(
  dir,
  ...,
  size_limit = 1024^3,
  eviction = c(
    "least-recently-stored",
    "least-recently-used",
    "least-frequently-used",
    "none"
  ),
  inline_max = 32 * 1024,
  codec = codec_auto(),
  codecs = list(),
  durability = c("safe", "fast", "unsafe"),
  map_size = 1024^3,
  cull_limit = 10L,
  timeout = 60,
  readonly = FALSE,
  create = TRUE
) {
  rlang::check_dots_empty()
  check_supplied("dir")
  explicit <- list(
    size_limit = !missing(size_limit),
    eviction = !missing(eviction),
    inline_max = !missing(inline_max),
    codec = !missing(codec),
    codec_args = !missing(codec)
  )
  call <- rlang::current_env()
  check_string(dir, "dir")
  check_number(size_limit, "size_limit", min = 0, allow_inf = TRUE)
  eviction <- rlang::arg_match(eviction)
  if (eviction %in% c("least-recently-used", "least-frequently-used")) {
    abort_unsupported(
      sprintf(
        "`eviction = \"%s\"` is not available yet; it arrives with access tracking.",
        eviction
      ),
      call = call
    )
  }
  check_number(inline_max, "inline_max", min = 0, whole = TRUE)
  if (!is_codec(codec)) {
    abort_codec_error(
      "`codec` must be a codec, such as `codec_auto()` or one made with `codec()`.",
      call = call
    )
  }
  codecs <- codec_registry(codecs, call = call)
  durability <- rlang::arg_match(durability)
  check_number(map_size, "map_size", min = 1)
  check_number(cull_limit, "cull_limit", min = 1, whole = TRUE)
  check_number(timeout, "timeout", min = 0)
  check_flag(readonly, "readonly")
  check_flag(create, "create")

  dir <- path.expand(dir)
  path <- file.path(dir, "cache.mdbx")
  if (!dir.exists(dir) || !file.exists(path)) {
    if (readonly || !create) {
      abort_not_found(
        sprintf("There is no cache in %s.", encodeString(dir, quote = "\"")),
        dir = dir,
        call = call
      )
    }
    store_mkdir(dir, call)
  }
  dir <- normalizePath(dir, mustWork = TRUE)
  if (!readonly) {
    store_create_layout(dir, call)
  }

  s <- new.env(parent = emptyenv())
  class(s) <- "dazcache_cache"
  s$dir <- dir
  s$readonly <- readonly
  s$closed <- FALSE
  s$timeout <- timeout
  s$cull_limit <- as.integer(cull_limit)
  s$codecs <- codecs
  s$engine <- engine_open(
    path,
    readonly = readonly,
    map_size = map_size,
    durability = durability,
    call = call
  )
  opened <- FALSE
  on.exit(if (!opened) engine_close(s$engine, call = call))

  config <- list(
    size_limit = as.double(size_limit),
    eviction = eviction,
    inline_max = as.double(inline_max),
    codec = codec$name,
    codec_args = codec$args
  )
  # The stored configuration, not this call's defaults, says which indexes
  # exist: reopening a store without repeating its settings creates nothing.
  s$config <- store_init(s, config, explicit, call)
  engine_ensure_dbs(
    s$engine,
    store_databases(s$config),
    timeout = timeout,
    call = call
  )
  # A stored default that is a user codec this handle was not given is NULL:
  # writing with it is then an error, reading is not.
  s$codec <- if (explicit$codec) codec else codec_known(s$config$codec, codecs, s$config$codec_args)
  codec_register(s, s$codec)
  opened <- TRUE
  s
}

#' @rdname cache
#' @inheritParams cache_get
#' @export
cache_close <- function(cache) {
  check_cache(cache)
  if (!cache$closed) {
    engine_close(cache$engine)
    cache$closed <- TRUE
  }
  invisible(cache)
}

#' @rdname cache
#' @export
cache_is_open <- function(cache) {
  check_cache(cache)
  !cache$closed
}

#' @rdname cache
#' @export
cache_dir <- function(cache) {
  check_cache(cache)
  cache$dir
}

#' @rdname cache
#' @param .local_envir The environment whose exit closes the cache.
#' @export
local_cache <- function(dir = NULL, ..., .local_envir = parent.frame()) {
  temporary <- is.null(dir)
  if (temporary) {
    dir <- tempfile("cache-")
  }
  s <- cache(dir, ...)
  defer(
    {
      cache_close(s)
      if (temporary) unlink(s$dir, recursive = TRUE)
    },
    envir = .local_envir
  )
  s
}

#' @rdname cache
#' @param fn A function of one argument, the open cache.
#' @export
with_cache <- function(dir, fn, ...) {
  check_supplied(c("dir", "fn"))
  if (!is.function(fn)) {
    abort_type_error("`fn` must be a function of one argument, the open cache.")
  }
  s <- cache(dir, ...)
  on.exit(cache_close(s))
  fn(s)
}

#' @export
format.dazcache_cache <- function(x, ...) {
  header <- paste0("<dazcache_cache> ", x$dir)
  if (x$closed) {
    return(c(header, "  closed"))
  }
  # Printing must not fail, whatever stops the count.
  n <- tryCatch(format(cache_count(x), big.mark = ","), error = function(cnd) {
    "unavailable"
  })
  c(
    header,
    paste0(
      "  entries ",
      n,
      " \u00b7 eviction ",
      x$config$eviction,
      " \u00b7 durability ",
      cache_durability(x),
      if (x$readonly) " \u00b7 read-only"
    )
  )
}

#' @export
print.dazcache_cache <- function(x, ...) {
  cat(format(x), sep = "\n")
  invisible(x)
}

cache_durability <- function(s) {
  flags <- engine_flags(s$engine)
  if ("UTTERLY_NOSYNC" %in% flags) {
    "unsafe"
  } else if ("SAFE_NOSYNC" %in% flags) {
    "fast"
  } else {
    "safe"
  }
}

# Checks -----------------------------------------------------------------------

check_cache <- function(x, call = rlang::caller_env()) {
  if (missing(x)) {
    abort_type_error("`cache` is required.", call = call)
  }
  if (!inherits(x, "dazcache_cache")) {
    abort_type_error(
      "`cache` must be a cache opened with `cache()`.",
      call = call
    )
  }
}

check_open <- function(s, call = rlang::caller_env()) {
  check_cache(s, call)
  if (s$closed) {
    abort_closed("This cache has been closed.", dir = s$dir, call = call)
  }
}

check_writable <- function(s, call = rlang::caller_env()) {
  check_open(s, call)
  if (s$readonly) {
    abort_readonly("This cache was opened read-only.", dir = s$dir, call = call)
  }
}

# Raise dazcache_type_error for the first of the caller's arguments `args` it
# was not given, rather than letting R's own "argument is missing" escape the
# taxonomy when the argument is first used.
check_supplied <- function(args, call = rlang::caller_env()) {
  for (arg in args) {
    if (eval(as.call(list(quote(missing), as.name(arg))), call)) {
      abort_type_error(sprintf("`%s` is required.", arg), call = call)
    }
  }
}

check_string <- function(x, arg, call = rlang::caller_env()) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    abort_type_error(
      sprintf("`%s` must be a single non-empty string.", arg),
      call = call
    )
  }
}

check_flag <- function(x, arg, call = rlang::caller_env()) {
  if (!isTRUE(x) && !isFALSE(x)) {
    abort_type_error(sprintf("`%s` must be TRUE or FALSE.", arg), call = call)
  }
}

check_string_or_empty <- function(x, arg, call = rlang::caller_env()) {
  if (!is.character(x) || length(x) != 1L || is.na(x)) {
    abort_type_error(sprintf("`%s` must be a single string.", arg), call = call)
  }
}

check_number <- function(
  x,
  arg,
  call = rlang::caller_env(),
  min = -Inf,
  whole = FALSE,
  allow_inf = FALSE
) {
  ok <- is.numeric(x) &&
    length(x) == 1L &&
    !is.na(x) &&
    x >= min &&
    (allow_inf || is.finite(x)) &&
    (!whole || !is.finite(x) || x == trunc(x))
  if (!ok) {
    abort_type_error(
      sprintf(
        "`%s` must be a single %s of at least %s.",
        arg,
        if (whole) "whole number" else "number",
        format(min)
      ),
      call = call
    )
  }
}

# Run `expr` when `envir`'s function returns. At the top level there is no such
# moment, so nothing is registered and the caller closes the cache.
defer <- function(expr, envir) {
  thunk <- as.call(list(function() expr))
  if (!identical(envir, globalenv())) {
    do.call(base::on.exit, list(thunk, TRUE, FALSE), envir = envir)
  }
  invisible()
}

# A new staging path in the cache's own tmp/, so a rename into blobs/ stays on
# one device (design.md §8).
stage_path <- function(s) {
  if (s$readonly) {
    # Only a decode can stage on a read-only handle, and nothing is renamed.
    return(tempfile("dazcache-"))
  }
  dazcache_state$stage <- dazcache_state$stage + 1L
  file.path(s$dir, "tmp", sprintf("%d-%d", Sys.getpid(), dazcache_state$stage))
}
