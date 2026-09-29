# The stash handle and its opening and closing (design.md §3.1).

dastash_state <- new.env(parent = emptyenv())
dastash_state$stage <- 0L

#' Open a stash
#'
#' @description
#' `stash()` opens the cache in directory `dir`, creating it if needed, and
#' returns a handle for the other `stash_*()` functions. Any number of R
#' processes on the machine can open the same directory at once; they share it
#' safely.
#'
#' `local_stash()` opens a stash that closes when the calling function returns,
#' in a new temporary directory unless you give one, which is then deleted.
#' `with_stash()` opens one, passes it to a function, and closes it afterwards.
#'
#' @details
#' `size_limit`, `eviction`, `inline_max` and `codec` belong to the store and are
#' fixed when it is created: a later `stash()` that passes a *different* value
#' raises `dastash_config_conflict`, and one that leaves them out uses the stored
#' values. The other settings belong to this handle only.
#'
#' A second `stash()` on a directory this process already has open shares the
#' same underlying database; each handle is closed separately. While a
#' read-only handle is open, the same process cannot open the directory for
#' writing: close it first.
#'
#' A handle cannot be used from a forked child process, such as a
#' [parallel::mclapply()] worker; open the stash inside the worker instead.
#'
#' @param dir The stash's directory.
#' @param ... Must be empty.
#' @param size_limit The size, in bytes, the stash is kept under. `Inf` for no
#'   limit. Stored with the stash.
#' @param eviction Which entries make room when the stash is over `size_limit`:
#'   the least recently stored, or `"none"` to never evict. Stored with the
#'   stash. `"least-recently-used"` and `"least-frequently-used"` are not yet
#'   available.
#' @param inline_max Values smaller than this many bytes are kept inside the
#'   database; larger ones become files. Stored with the stash.
#' @param codec The default codec for writes; see [codec()]. Stored with the
#'   stash, by name.
#' @param codecs A list of your own codecs, made with [codec()], that this
#'   handle can read and write.
#' @param durability `"safe"` makes every write durable before it returns.
#'   `"fast"` does not wait for the disk: a crash may lose recent writes but
#'   never damages the stash. `"unsafe"` can damage it in a crash. The first
#'   process to open a stash sets this for everyone who opens it while it is
#'   open.
#' @param map_size The most the database file may grow to, in bytes.
#' @param cull_limit How many entries one eviction step removes at most.
#' @param timeout How long, in seconds, a write waits for another process's
#'   write to finish before raising `dastash_busy`.
#' @param readonly Open for reading only.
#' @param create Create the directory and the stash if they do not exist.
#'
#' @return `stash()` and `local_stash()` return a `dastash_stash`.
#'   `with_stash()` returns what `fn` returns.
#'
#' @examples
#' dir <- tempfile("stash-")
#' s <- stash(dir)
#' stash_set(s, "greeting", "hello")
#' stash_get(s, "greeting")
#' stash_close(s)
#' unlink(dir, recursive = TRUE)
#'
#' f <- function() {
#'   s <- local_stash()
#'   stash_set(s, "n", 1:3)
#'   stash_get(s, "n")
#' }
#' f()
#' @export
stash <- function(dir,
                  ...,
                  size_limit = 1024^3,
                  eviction = c("least-recently-stored", "least-recently-used",
                               "least-frequently-used", "none"),
                  inline_max = 32 * 1024,
                  codec = codec_auto(),
                  codecs = list(),
                  durability = c("safe", "fast", "unsafe"),
                  map_size = 1024^3,
                  cull_limit = 10L,
                  timeout = 60,
                  readonly = FALSE,
                  create = TRUE) {
  rlang::check_dots_empty()
  explicit <- list(
    size_limit = !missing(size_limit), eviction = !missing(eviction),
    inline_max = !missing(inline_max), codec = !missing(codec)
  )
  call <- rlang::current_env()
  check_string(dir, "dir", call)
  check_number(size_limit, "size_limit", call, min = 0, allow_inf = TRUE)
  eviction <- rlang::arg_match(eviction)
  if (eviction %in% c("least-recently-used", "least-frequently-used")) {
    abort_unsupported(
      sprintf("`eviction = \"%s\"` is not available yet; it arrives with access tracking.", eviction),
      call = call
    )
  }
  check_number(inline_max, "inline_max", call, min = 0, whole = TRUE)
  if (!is_codec(codec)) {
    abort_codec_error("`codec` must be a codec, such as `codec_auto()` or one made with `codec()`.", call = call)
  }
  codecs <- codec_registry(codecs, call = call)
  durability <- rlang::arg_match(durability)
  check_number(map_size, "map_size", call, min = 1)
  check_number(cull_limit, "cull_limit", call, min = 1, whole = TRUE)
  check_number(timeout, "timeout", call, min = 0)
  check_flag(readonly, "readonly", call)
  check_flag(create, "create", call)

  dir <- path.expand(dir)
  path <- file.path(dir, "cache.mdbx")
  if (!dir.exists(dir) || !file.exists(path)) {
    if (readonly || !create) {
      abort_not_found(
        sprintf("There is no stash in %s.", encodeString(dir, quote = "\"")),
        dir = dir, call = call
      )
    }
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  }
  dir <- normalizePath(dir, mustWork = TRUE)
  if (!readonly) {
    store_create_layout(dir)
  }

  s <- new.env(parent = emptyenv())
  class(s) <- "dastash_stash"
  s$dir <- dir
  s$readonly <- readonly
  s$closed <- FALSE
  s$timeout <- timeout
  s$cull_limit <- as.integer(cull_limit)
  s$codecs <- codecs
  s$engine <- engine_open(path, readonly = readonly, map_size = map_size, durability = durability, call = call)
  opened <- FALSE
  on.exit(if (!opened) engine_close(s$engine, call = call))

  config <- list(
    size_limit = as.double(size_limit),
    eviction = eviction,
    inline_max = as.double(inline_max),
    codec = codec$name
  )
  engine_ensure_dbs(s$engine, store_databases(config), timeout = timeout, call = call)
  s$config <- store_init(s, config, explicit, call)
  s$codec <- if (explicit$codec) codec else codec_default(s$config$codec, codecs)
  opened <- TRUE
  s
}

# The default codec a stored name stands for, or NULL for a user codec this
# handle was not given: writing with it is then an error, reading is not.
codec_default <- function(name, codecs) {
  switch(name,
    auto = codec_auto(),
    rds = codec_rds(),
    raw = codec_raw(),
    file = codec_file(),
    codecs[[name]]
  )
}

#' @rdname stash
#' @param stash A stash, from `stash()`.
#' @export
stash_close <- function(stash) {
  check_stash(stash)
  if (!stash$closed) {
    engine_close(stash$engine)
    stash$closed <- TRUE
  }
  invisible(stash)
}

#' @rdname stash
#' @export
stash_is_open <- function(stash) {
  check_stash(stash)
  !stash$closed
}

#' @rdname stash
#' @export
stash_dir <- function(stash) {
  check_stash(stash)
  stash$dir
}

#' @rdname stash
#' @param .local_envir The environment whose exit closes the stash.
#' @export
local_stash <- function(dir = NULL, ..., .local_envir = parent.frame()) {
  temporary <- is.null(dir)
  if (temporary) {
    dir <- tempfile("stash-")
  }
  s <- stash(dir, ...)
  defer(
    {
      stash_close(s)
      if (temporary) unlink(s$dir, recursive = TRUE)
    },
    envir = .local_envir
  )
  s
}

#' @rdname stash
#' @param fn A function of one argument, the open stash.
#' @export
with_stash <- function(dir, fn, ...) {
  s <- stash(dir, ...)
  on.exit(stash_close(s))
  fn(s)
}

#' @export
format.dastash_stash <- function(x, ...) {
  header <- paste0("<dastash_stash> ", x$dir)
  if (x$closed) {
    return(c(header, "  closed"))
  }
  n <- tryCatch(stash_count(x), error = function(cnd) NA)
  c(
    header,
    paste0(
      "  entries ", format(n, big.mark = ","),
      " \u00b7 eviction ", x$config$eviction,
      " \u00b7 durability ", stash_durability(x),
      if (x$readonly) " \u00b7 read-only"
    )
  )
}

#' @export
print.dastash_stash <- function(x, ...) {
  cat(format(x), sep = "\n")
  invisible(x)
}

stash_durability <- function(s) {
  flags <- engine_flags(s$engine)
  if ("UTTERLY_NOSYNC" %in% flags) "unsafe" else if ("SAFE_NOSYNC" %in% flags) "fast" else "safe"
}

# Checks ---------------------------------------------------------------------

check_stash <- function(x, call = rlang::caller_env()) {
  if (!inherits(x, "dastash_stash")) {
    abort_type_error("`stash` must be a stash opened with `stash()`.", call = call)
  }
}

check_open <- function(s, call = rlang::caller_env()) {
  check_stash(s, call)
  if (s$closed) {
    abort_closed("This stash has been closed.", dir = s$dir, call = call)
  }
}

check_writable <- function(s, call = rlang::caller_env()) {
  check_open(s, call)
  if (s$readonly) {
    abort_readonly("This stash was opened read-only.", dir = s$dir, call = call)
  }
}

check_string <- function(x, arg, call) {
  if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    abort_type_error(sprintf("`%s` must be a single non-empty string.", arg), call = call)
  }
}

check_flag <- function(x, arg, call) {
  if (!isTRUE(x) && !isFALSE(x)) {
    abort_type_error(sprintf("`%s` must be TRUE or FALSE.", arg), call = call)
  }
}

check_number <- function(x, arg, call, min = -Inf, whole = FALSE, allow_inf = FALSE) {
  ok <- is.numeric(x) && length(x) == 1L && !is.na(x) && x >= min &&
    (allow_inf || is.finite(x)) && (!whole || !is.finite(x) || x == trunc(x))
  if (!ok) {
    abort_type_error(
      sprintf("`%s` must be a single %s of at least %s.", arg, if (whole) "whole number" else "number", format(min)),
      call = call
    )
  }
}

# Run `expr` when `envir`'s function returns. At the top level there is no such
# moment, so nothing is registered and the caller closes the stash.
defer <- function(expr, envir) {
  thunk <- as.call(list(function() expr))
  if (!identical(envir, globalenv())) {
    do.call(base::on.exit, list(thunk, TRUE, FALSE), envir = envir)
  }
  invisible()
}

# A new staging path in the stash's own tmp/, so a rename into blobs/ stays on
# one device (design.md §8).
stage_path <- function(s) {
  if (s$readonly) {
    # Only a decode can stage on a read-only handle, and nothing is renamed.
    return(tempfile("dastash-"))
  }
  dastash_state$stage <- dastash_state$stage + 1L
  file.path(s$dir, "tmp", sprintf("%d-%d", Sys.getpid(), dastash_state$stage))
}
