# Content-addressed blobs (design.md §6.1, §8): values of `inline_max` bytes or
# more, and every file-backed codec's value, live in
# <root>/blobs/<aa>/<hash>[.<ext>], named by the SHA-256 of their bytes, and
# the `blobs` database counts the records referring to each file.
#
# One invariant, kept at every instant: a `blobs` row exists only while its
# file does (cache-model.md §11.3). Two rules keep it, both run while holding
# the write lock, so no other process can interleave:
#
# * A new blob's file is renamed into place inside the writing transaction,
#   before the commit — published first, committed second. If the transaction
#   aborts, the file is an unreferenced orphan, which is harmless.
# * A file whose last reference went away is unlinked after that commit, in a
#   follow-up write transaction that checks it is still unreferenced — deleted
#   in the transaction, unlinked after it. A process that dies in between
#   leaves an orphan.
#
# Unlinking straight after the commit, without the lock, would race: another
# process could reference the same bytes again in between, and lose its file.

blob_name <- function(hash, ext) {
  if (is.null(ext) || !nzchar(ext)) hash else paste0(hash, ".", ext)
}

blob_path <- function(s, name) {
  file.path(s$dir, "blobs", substr(name, 1L, 2L), name)
}

record_blob_name <- function(record) {
  blob_name(record$blob, record$ext)
}

# Write an encoded value to a staging file in <root>/tmp and hash it, outside
# any transaction. Returns what the transaction needs to publish it.
blob_stage <- function(s, enc) {
  if (!is.null(enc$bytes)) {
    path <- stage_path(s)
    done <- FALSE
    on.exit(if (!done) unlink(path))
    writeBin(enc$bytes, path)
    hash <- hash_bytes(enc$bytes)
  } else {
    path <- enc$path
    hash <- hash_file(path)
  }
  out <- list(staged = path, hash = hash, ext = enc$ext, name = blob_name(hash, enc$ext), size = as.double(file.size(path)))
  done <- TRUE
  out
}

# In the open transaction: add a reference to a staged blob, publishing its file
# if this is the first.
store_ref_blob <- function(s, txn, blob) {
  e <- s$engine
  db <- engine_db(e, "blobs")
  row <- engine_get(txn, db, blob$name)
  if (!is.null(row)) {
    row <- record_decode(row)
    row$refs <- row$refs + 1
    engine_put(txn, db, blob$name, record_encode(row))
    return(invisible(FALSE))
  }
  blob_publish(s, blob)
  crash_point("publish")
  engine_put(txn, db, blob$name, record_encode(list(refs = 1, bytes = blob$size, ext = blob$ext)))
  store_counters_add(txn, list(bytes_blob = blob$size))
  invisible(TRUE)
}

# Move the staged file into place, replacing any orphan of the same name: the
# staged bytes were just hashed, while an orphan may be what a crash left.
blob_publish <- function(s, blob) {
  target <- blob_path(s, blob$name)
  dir <- dirname(target)
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  if (file.exists(target)) blob_unlink(target)
  Sys.chmod(blob$staged, "0444", use_umask = FALSE)
  if (!file.rename(blob$staged, target)) {
    abort_engine_error(
      sprintf("Could not move a new blob into %s.", encodeString(dir, quote = "\"")),
      path = target, call = NULL
    )
  }
  target
}

# In the open transaction: drop one reference to a blob. The last one removes
# its row and schedules the file for unlinking after the commit.
store_unref_blob <- function(s, txn, name) {
  e <- s$engine
  db <- engine_db(e, "blobs")
  row <- engine_get(txn, db, name)
  if (is.null(row)) {
    return(invisible(FALSE))
  }
  row <- record_decode(row)
  if (row$refs > 1) {
    row$refs <- row$refs - 1
    engine_put(txn, db, name, record_encode(row))
    return(invisible(FALSE))
  }
  engine_del(txn, db, name)
  store_counters_add(txn, list(bytes_blob = -row$bytes))
  engine_defer(e, function() blob_reap(s, name))
  invisible(TRUE)
}

# After a commit: unlink the files of blobs that are still unreferenced, under
# the write lock. If the lock is busy the files stay, as orphans for
# stash_check() to find; that is never unsafe.
blob_reap <- function(s, names) {
  crash_point("unlink")
  e <- s$engine
  tryCatch(
    engine_write(e, function(txn) {
      db <- engine_db(e, "blobs")
      for (name in names) {
        if (is.null(engine_get(txn, db, name))) blob_unlink(blob_path(s, name))
      }
    }, timeout = s$timeout),
    dastash_busy = function(cnd) NULL
  )
  invisible()
}

# Read-only files must be made writable before Windows will delete them.
blob_unlink <- function(path) {
  if (file.exists(path)) {
    Sys.chmod(path, "0644", use_umask = FALSE)
    unlink(path)
  }
  invisible()
}

# Crash injection for the tests of design.md §16: DASTASH_CRASH names a point,
# and the process dies there without cleaning up, exactly as a crash would.
crash_point <- function(name) {
  if (identical(Sys.getenv("DASTASH_CRASH"), name)) {
    if (.Platform$OS.type == "unix") {
      tools::pskill(Sys.getpid(), tools::SIGKILL)
    }
    quit(save = "no", status = 137L, runLast = FALSE)
  }
}
