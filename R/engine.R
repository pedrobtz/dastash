# The engine: the only file that calls mdbx (design.md §14.2), and so the only
# place that knows how libmdbx fails. Every function here is named engine_*,
# which the guards use to enforce that.
#
# An environment is opened once per process and database path and shared by
# every handle on it (design.md §3.1). Its entry in the registry below owns the
# environment's one live transaction (D21): inside a write transaction every
# engine call joins it, whichever handle made the call.

# Normalised database path -> entry (an environment).
engine_registry <- new.env(parent = emptyenv())

# Stands for a named database that a read-only handle found absent: it reads as
# empty. Distinct from NULL, which mdbx takes to mean the main database.
engine_missing_db <- structure(list(), class = "dastash_missing_db")

ENGINE_SCAN_CHUNK <- 1000L

engine_sync_flags <- function(durability) {
  switch(durability,
    safe = NULL,
    fast = "SAFE_NOSYNC",
    unsafe = "UTTERLY_NOSYNC"
  )
}

# Open or join the environment at `path` (the database file, whose directory
# must exist). A second open in this process, under any spelling of the path,
# joins the first and shares it.
engine_open <- function(path, readonly = FALSE, map_size = NULL,
                        durability = "safe", call = rlang::caller_env()) {
  key <- file.path(normalizePath(dirname(path), mustWork = TRUE), basename(path))
  e <- engine_registry[[key]]
  if (!is.null(e)) {
    engine_check_pid(e, call)
    if (e$readonly && !readonly) {
      abort_readonly(
        c(
          "This stash is already open read-only in this process.",
          i = "Close every handle on it before opening it for writing."
        ),
        dir = dirname(key), call = call
      )
    }
    e$refs <- e$refs + 1L
    return(e)
  }
  env <- engine_try(
    mdbx::mdbx_env_open(
      key,
      readonly = readonly, create = !readonly, subdir = FALSE, max_dbs = 16L,
      map_size = map_size, flags = c("ACCEDE", engine_sync_flags(durability))
    ),
    call
  )
  e <- new.env(parent = emptyenv())
  e$env <- env
  e$path <- key
  e$pid <- Sys.getpid()
  e$readonly <- readonly
  e$refs <- 1L
  e$txn <- NULL
  e$write <- FALSE
  e$after_commit <- list()
  e$dbs <- list()
  engine_registry[[key]] <- e
  e
}

# Release one handle's share; the environment closes with the last.
engine_close <- function(e, call = rlang::caller_env()) {
  engine_check_pid(e, call)
  e$refs <- e$refs - 1L
  if (e$refs > 0L) {
    return(invisible(FALSE))
  }
  if (!is.null(e$txn)) {
    engine_try(mdbx::mdbx_txn_abort(e$txn), call)
    e$txn <- NULL
  }
  engine_try(mdbx::mdbx_env_close(e$env), call)
  rm(list = e$path, envir = engine_registry)
  invisible(TRUE)
}

# On unload, close whatever this process still has open, so a reload can open
# the same paths again.
engine_close_all <- function() {
  for (key in ls(engine_registry)) {
    e <- engine_registry[[key]]
    if (identical(e$pid, Sys.getpid())) {
      if (!is.null(e$txn)) try(mdbx::mdbx_txn_abort(e$txn), silent = TRUE)
      try(mdbx::mdbx_env_close(e$env), silent = TRUE)
    }
    rm(list = key, envir = engine_registry)
  }
  invisible()
}

engine_check_pid <- function(e, call = rlang::caller_env()) {
  if (!identical(e$pid, Sys.getpid())) {
    abort_forked(
      c(
        sprintf(
          "This stash was opened by process %d and cannot be used from process %d.",
          e$pid, Sys.getpid()
        ),
        i = "It was inherited across a fork. Open the stash inside the worker instead."
      ),
      call = call
    )
  }
}

# Make sure every named database in `names` is usable: a read-write handle
# creates the missing ones in one write transaction; a read-only one looks
# them up and treats the absent ones as empty.
engine_ensure_dbs <- function(e, names, timeout = 60, call = rlang::caller_env()) {
  wanted <- setdiff(names, names(e$dbs))
  if (length(wanted) == 0L) {
    return(invisible(e))
  }
  if (e$readonly) {
    found <- engine_read(e, function(txn) {
      existing <- engine_try(mdbx::mdbx_dbi_list(txn), call)
      lapply(wanted, function(name) {
        if (name %in% existing) engine_try(mdbx::mdbx_dbi_open(txn, name), call) else engine_missing_db
      })
    }, call = call)
  } else {
    found <- engine_write(e, function(txn) {
      lapply(wanted, function(name) {
        engine_try(mdbx::mdbx_dbi_open(txn, name, create = TRUE), call)
      })
    }, timeout = timeout, call = call)
  }
  names(found) <- wanted
  # Only now: a handle from a transaction that aborted refers to nothing.
  e$dbs[names(found)] <- found
  invisible(e)
}

# The handle for a named database, or NULL for the main database.
engine_db <- function(e, name = NULL) {
  if (is.null(name)) {
    return(NULL)
  }
  db <- e$dbs[[name]]
  if (is.null(db)) {
    abort_engine_error(sprintf("Internal error: database %s was never opened.", name), call = NULL)
  }
  db
}

# Transactions -----------------------------------------------------------------

# Run `fn(txn)` in a read transaction, or in the transaction already open on
# this environment.
engine_read <- function(e, fn, call = rlang::caller_env()) {
  engine_check_pid(e, call)
  if (!is.null(e$txn)) {
    return(fn(e$txn))
  }
  txn <- engine_try(mdbx::mdbx_txn_begin(e$env, write = FALSE), call)
  e$txn <- txn
  e$write <- FALSE
  on.exit({
    e$txn <- NULL
    mdbx::mdbx_txn_abort(txn)
  })
  fn(txn)
}

# Run `fn(txn)` in a write transaction and commit it, or join the write
# transaction already open. The lock is taken with TRY and retried with
# backoff for up to `timeout` seconds, so a busy store is an error rather than
# a hang. Actions deferred with engine_defer() run after the commit, and are
# dropped if the transaction aborts.
engine_write <- function(e, fn, timeout = 60, call = rlang::caller_env()) {
  engine_check_pid(e, call)
  if (e$readonly) {
    abort_readonly("This stash is read-only.", call = call)
  }
  if (!is.null(e$txn)) {
    if (!e$write) {
      abort_engine_error("Internal error: a write inside a read transaction.", call = call)
    }
    return(fn(e$txn))
  }
  txn <- engine_begin_write(e, timeout, call)
  e$txn <- txn
  e$write <- TRUE
  e$after_commit <- list()
  on.exit({
    if (!is.null(e$txn)) {
      e$txn <- NULL
      e$write <- FALSE
      e$after_commit <- list()
      mdbx::mdbx_txn_abort(txn)
    }
  })
  result <- withVisible(fn(txn))
  engine_try(mdbx::mdbx_txn_commit(txn), call)
  actions <- e$after_commit
  e$txn <- NULL
  e$write <- FALSE
  e$after_commit <- list()
  for (action in actions) action()
  if (result$visible) result$value else invisible(result$value)
}

engine_begin_write <- function(e, timeout, call) {
  deadline <- Sys.time() + timeout
  wait <- 0.002
  # A fixed per-process offset instead of random jitter, so waiting never
  # touches the user's random number stream.
  spread <- 1 + (Sys.getpid() %% 7L) / 10
  repeat {
    txn <- tryCatch(
      mdbx::mdbx_txn_begin(e$env, write = TRUE, flags = "TRY"),
      mdbx_busy = function(cnd) NULL,
      error = function(cnd) engine_translate(cnd, call)
    )
    if (!is.null(txn)) {
      return(txn)
    }
    remaining <- as.double(difftime(deadline, Sys.time(), units = "secs"))
    if (remaining <= 0) {
      abort_busy(
        c(
          sprintf("Could not write: another process held the stash's write lock for %s seconds.", format(timeout)),
          i = "Raise `timeout` in `stash()` to wait longer."
        ),
        timeout = timeout, call = call
      )
    }
    Sys.sleep(min(wait * spread, remaining))
    wait <- min(wait * 2, 0.25)
  }
}

# Run `action()` once the current write transaction commits.
engine_defer <- function(e, action) {
  if (is.null(e$txn) || !e$write) {
    abort_engine_error("Internal error: nothing to defer to outside a write transaction.", call = NULL)
  }
  e$after_commit[[length(e$after_commit) + 1L]] <- action
  invisible()
}

# Records ----------------------------------------------------------------------

engine_get <- function(txn, db, key, as = "raw") {
  if (inherits(db, "dastash_missing_db")) {
    return(NULL)
  }
  engine_try(mdbx::mdbx_get(txn, key, as = as, db = db))
}

engine_put <- function(txn, db, key, value, overwrite = TRUE) {
  engine_try(mdbx::mdbx_put(txn, key, value, overwrite = overwrite, db = db))
}

engine_del <- function(txn, db, key) {
  if (inherits(db, "dastash_missing_db")) {
    return(FALSE)
  }
  engine_try(mdbx::mdbx_del(txn, key, db = db))
}

# Remove every record from a named database, keeping the database.
engine_clear_db <- function(txn, db) {
  if (inherits(db, "dastash_missing_db")) {
    return(invisible())
  }
  engine_try(mdbx::mdbx_dbi_drop(txn, db, delete = FALSE))
  invisible()
}

engine_count <- function(txn, db) {
  if (inherits(db, "dastash_missing_db")) {
    return(0)
  }
  engine_try(mdbx::mdbx_env_stat(txn, db = db))$entries
}

# Keys in order from `start` (inclusive), or from the front. With `prefix`,
# only keys that begin with it, stopping at the first that does not; mdbx has
# no upper bound on a scan, so the stop is done here, a chunk at a time. At
# most `n` keys. With `values = TRUE`, a list of `keys` and `values`.
engine_scan <- function(txn, db, prefix = NULL, start = NULL, n = Inf,
                        reverse = FALSE, as = "raw", values = FALSE,
                        chunk = ENGINE_SCAN_CHUNK) {
  empty <- if (as == "raw") list() else character()
  out_keys <- empty
  out_values <- list()
  if (inherits(db, "dastash_missing_db") || n <= 0) {
    return(if (values) list(keys = out_keys, values = out_values) else out_keys)
  }
  if (!is.null(prefix) && reverse) {
    abort_engine_error("Internal error: a prefix scan runs forwards.", call = NULL)
  }
  matches <- if (is.null(prefix)) {
    function(k) rep(TRUE, length(k))
  } else if (as == "raw") {
    p <- if (is.character(prefix)) charToRaw(prefix) else prefix
    function(k) vapply(k, function(x) length(x) >= length(p) && identical(x[seq_along(p)], p), logical(1))
  } else {
    function(k) startsWith(k, prefix)
  }
  from <- if (!is.null(start)) start else prefix
  skip_first <- FALSE
  repeat {
    want <- min(chunk, n - length(out_keys)) + skip_first
    batch <- if (values) {
      engine_try(mdbx::mdbx_items(txn, limit = want, as = "raw", db = db, start = from, reverse = reverse, keys_as = as))
    } else {
      list(keys = engine_try(mdbx::mdbx_keys(txn, limit = want, as = as, db = db, start = from, reverse = reverse)))
    }
    got <- length(batch$keys)
    keys <- batch$keys
    vals <- batch$values
    if (skip_first && got > 0L) {
      keys <- keys[-1L]
      if (values) vals <- vals[-1L]
    }
    ok <- matches(keys)
    stop_here <- !all(ok)
    if (stop_here) {
      first_bad <- which(!ok)[[1L]]
      keep <- seq_len(first_bad - 1L)
      keys <- keys[keep]
      if (values) vals <- vals[keep]
    }
    out_keys <- c(out_keys, keys)
    if (values) out_values <- c(out_values, vals)
    if (stop_here || got < want || length(out_keys) >= n) break
    from <- batch$keys[[got]]
    skip_first <- TRUE
  }
  if (values) list(keys = out_keys, values = out_values) else out_keys
}

engine_info <- function(e) {
  engine_try(mdbx::mdbx_env_info(e$env))
}

engine_flags <- function(e) {
  engine_try(mdbx::mdbx_env_get_flags(e$env))
}

# Errors -----------------------------------------------------------------------

# Evaluate one mdbx call, translating its failure by class (design.md §13).
# dastash's own conditions pass through untouched.
engine_try <- function(expr, call = NULL) {
  tryCatch(expr, error = function(cnd) engine_translate(cnd, call))
}

engine_translate <- function(cnd, call) {
  if (inherits(cnd, "dastash_error")) {
    rlang::cnd_signal(cnd)
  }
  if (inherits(cnd, "mdbx_map_full")) {
    abort_store_full(
      c(
        "The stash's database is full: it reached its `map_size`.",
        i = "Reopen it with a larger `map_size` in `stash()`."
      ),
      parent = cnd, call = call
    )
  }
  abort_engine_error("The storage engine failed.", parent = cnd, call = call)
}

# Release the reader slots of processes that died holding a read transaction.
# Returns how many.
engine_reader_check <- function(e) {
  as.integer(engine_try(mdbx::mdbx_env_reader_check(e$env)))
}
