# An engine on a fresh directory, closed when the calling test ends.
local_engine <- function(..., dir = withr::local_tempdir(.local_envir = env), env = parent.frame()) {
  e <- engine_open(file.path(dir, "cache.mdbx"), ...)
  withr::defer(while (!is.null(engine_registry[[e$path]])) engine_close(e), envir = env)
  e
}

# Put key -> value pairs (strings) into a database in one write.
engine_fill <- function(e, pairs, db = NULL) {
  engine_write(e, function(txn) {
    for (k in names(pairs)) engine_put(txn, engine_db(e, db), k, pairs[[k]])
  })
}

# A child process loads dastash from the library, not from the sources under
# test. R CMD check installs the copy it checks; devtools::test() does not, so
# there the child tests run only when DASTASH_TEST_CHILDREN=true says the
# installed copy is current (after R CMD INSTALL .).
skip_unless_children_see_this_build <- function() {
  skip_if_not_installed("callr")
  if (!testthat::is_checking() && !isTRUE(as.logical(Sys.getenv("DASTASH_TEST_CHILDREN")))) {
    skip("child processes would load an installed dastash, not this build")
  }
}

# Every storage invariant that must hold between transactions (design.md §7, §8,
# cache-model.md §11.3), as a character vector of violations; empty when sound.
# Orphan files are allowed: they are harmless and stash_check() reclaims them.
store_violations <- function(s) {
  e <- s$engine
  engine_read(e, function(txn) {
    out <- character()
    meta <- engine_scan(txn, engine_db(e, "meta"), as = "character", values = TRUE)
    records <- lapply(meta$values, record_decode)
    names(records) <- meta$keys
    blobs <- engine_scan(txn, engine_db(e, "blobs"), as = "character", values = TRUE)
    rows <- lapply(blobs$values, record_decode)
    names(rows) <- blobs$keys

    refs <- list()
    bytes_inline <- 0
    for (k in names(records)) {
      r <- records[[k]]
      if (isTRUE(r$inline)) {
        v <- engine_get(txn, engine_db(e, "values"), k)
        if (is.null(v)) out <- c(out, paste("no value row for", k))
        else if (length(v) != r$bytes) out <- c(out, paste("value size differs for", k))
        bytes_inline <- bytes_inline + r$bytes
      } else {
        name <- record_blob_name(r)
        refs[[name]] <- (refs[[name]] %||% 0) + 1
        path <- blob_path(s, name)
        if (is.null(rows[[name]])) out <- c(out, paste("no blobs row for", k))
        if (!file.exists(path)) out <- c(out, paste("dangling record", k, "->", name))
        else if (file.size(path) != r$bytes) out <- c(out, paste("wrong file size for", k))
      }
    }
    for (name in names(rows)) {
      if (!identical(rows[[name]]$refs, refs[[name]] %||% 0)) {
        out <- c(out, sprintf("refcount of %s is %s, records say %s", name, rows[[name]]$refs, refs[[name]] %||% 0))
      }
      if (!file.exists(blob_path(s, name))) out <- c(out, paste("blobs row without a file:", name))
    }
    counters <- store_counters(txn)
    if (!isTRUE(all.equal(counters$bytes_inline, bytes_inline))) out <- c(out, "bytes_inline drifted")
    blob_bytes <- sum(vapply(rows, function(r) r$bytes, 0))
    if (!isTRUE(all.equal(counters$bytes_blob, blob_bytes))) out <- c(out, "bytes_blob drifted")
    n_expiring <- sum(vapply(records, function(r) is.finite(r$expire), logical(1)))
    if (engine_count(txn, engine_db(e, "expiry")) != n_expiring) out <- c(out, "expiry rows differ from records")
    out
  })
}
