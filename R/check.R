# cache_check() (design.md §11.3). Indexes, refcounts and counters are all
# projections of the meta records, so almost any damage is found by comparing
# what the records imply with what is there, and repaired by making the
# projections agree again.

#' Check a cache, and repair it
#'
#' @description
#' Compares every index, reference count and counter with what the entries
#' imply, and every stored file with its records. Returns one row per problem
#' found. With `repair = TRUE` it fixes them, in one transaction: rebuilding
#' index rows, recounting, removing entries whose file is gone or damaged, and
#' deleting files and staging leftovers nothing refers to.
#'
#' A crash leaves at most unreferenced files; `cache_check(repair = TRUE)` is
#' how they are reclaimed. `hash = TRUE` also reads every stored file and
#' checks its bytes against its name, which is slow on a large cache.
#'
#' @inheritParams cache_expire
#' @param repair Fix what is found.
#' @param hash Verify the content of every stored file.
#'
#' @return A data frame with columns `kind`, `key`, `path`, `detail` and
#'   `repaired`, one row per finding. The kinds are `index_orphan`,
#'   `index_missing`, `record_corrupt`, `value_orphan`, `value_missing`,
#'   `value_corrupt`, `blob_missing`, `blob_orphan`, `blob_corrupt`,
#'   `blob_mode`, `refcount_drift`, `counter_drift`, `tmp_stale` and
#'   `reader_stale`.
#'
#' @examples
#' s <- local_cache()
#' cache_set(s, "a", runif(1e4))
#' cache_check(s)
#' @export
cache_check <- function(cache, ..., repair = FALSE, hash = FALSE) {
  check_dots()
  check_flag(repair, "repair")
  check_flag(hash, "hash")
  if (repair) {
    check_writable(cache)
  } else {
    check_open(cache)
  }
  e <- cache$engine

  corrupt <- character()
  if (hash) {
    snap <- engine_read(e, function(txn) check_snapshot(cache, txn))
    corrupt <- check_hashes(cache, snap)
  }
  if (!repair) {
    snap <- engine_read(e, function(txn) check_snapshot(cache, txn))
    findings <- check_findings(cache, snap, corrupt)
    return(rbind(findings, check_tmp(cache, repair = FALSE)))
  }

  findings <- engine_write(
    e,
    function(txn) {
      snap <- check_snapshot(cache, txn)
      findings <- check_findings(cache, snap, corrupt)
      reap <- check_repair(cache, txn, snap, findings)
      # Unlinked once the deletes are durable: after this commit, or inside
      # cache_transact() after the outer one, never while they can still abort.
      if (length(reap) > 0L) {
        blob_defer_reap(cache, reap)
      }
      findings
    },
    timeout = cache$timeout
  )
  # A misplaced file is at no path a read could reach, so it can go at once.
  misplaced <- findings$kind == "blob_orphan" &
    findings$detail %in% "not where its name puts it"
  for (path in findings$path[misplaced]) {
    blob_unlink(path)
  }
  findings$repaired <- rep(TRUE, nrow(findings))
  readers <- engine_reader_check(e)
  if (readers > 0) {
    findings <- rbind(
      findings,
      finding(
        "reader_stale",
        detail = sprintf("%d reader slots of dead processes cleared", readers),
        repaired = TRUE
      )
    )
  }
  rbind(findings, check_tmp(cache, repair = TRUE))
}

# Everything the check compares, read in one transaction. Records are decoded
# one by one, so a damaged one is a finding rather than the end of the check.
check_snapshot <- function(s, txn) {
  e <- s$engine
  meta <- engine_scan(
    txn,
    engine_db(e, "meta"),
    as = "character",
    values = TRUE
  )
  records <- lapply(meta$values, record_try_decode)
  names(records) <- meta$keys
  damaged <- meta$keys[vapply(records, is.null, logical(1))]
  records <- records[!names(records) %in% damaged]
  index <- list()
  for (db in setdiff(store_databases(s$config), c("meta", "values", "blobs"))) {
    rows <- engine_scan(txn, engine_db(e, db))
    index[[db]] <- vapply(rows, raw_hex, character(1))
  }
  blobs <- engine_scan(
    txn,
    engine_db(e, "blobs"),
    as = "character",
    values = TRUE
  )
  rows <- lapply(blobs$values, record_try_decode)
  names(rows) <- blobs$keys
  values <- engine_scan(
    txn,
    engine_db(e, "values"),
    as = "character",
    values = TRUE
  )
  # A file counts as a blob only at the path its name implies; one anywhere
  # else under blobs/ is an orphan whatever its name.
  listed <- list.files(file.path(s$dir, "blobs"), recursive = TRUE)
  placed <- listed == file.path(substr(basename(listed), 1L, 2L), basename(listed))
  list(
    records = records,
    damaged = damaged,
    values = values$keys,
    value_sizes = stats::setNames(lengths(values$values), values$keys),
    index = index,
    blobs = rows[!vapply(rows, is.null, logical(1))],
    blob_rows = blobs$keys,
    files = basename(listed[placed]),
    misplaced = file.path(s$dir, "blobs", listed[!placed]),
    counters = record_try_decode(engine_get(txn, NULL, "counters"))
  )
}

# Names of blobs whose bytes do not hash to their name: every file a record
# or a blobs row names, counted or not.
check_hashes <- function(s, snap) {
  named <- unlist(lapply(snap$records, function(r) {
    if (!isTRUE(r$inline)) record_blob_name(r)
  }))
  stored <- intersect(union(names(snap$blobs), named), snap$files)
  bad <- vapply(
    stored,
    function(name) {
      !identical(hash_file(blob_path(s, name)), sub("\\..*$", "", name))
    },
    logical(1)
  )
  stored[bad]
}

check_findings <- function(s, snap, corrupt = character()) {
  out <- list()
  add <- function(...) out[[length(out) + 1L]] <<- finding(...)
  records <- snap$records

  for (k in snap$damaged) {
    add("record_corrupt", key = k, detail = "meta record unreadable")
  }

  # Index rows: what the records imply against what is there.
  expected <- list()
  for (k in names(records)) {
    for (row in index_rows(s, k, records[[k]])) {
      expected[[row$db]] <- c(expected[[row$db]], raw_hex(row$key))
    }
  }
  for (db in names(snap$index)) {
    have <- snap$index[[db]]
    want <- expected[[db]] %||% character()
    for (h in setdiff(have, want)) {
      add("index_orphan", key = index_row_key(db, h), detail = db)
    }
    for (h in setdiff(want, have)) {
      add("index_missing", key = index_row_key(db, h), detail = db)
    }
  }

  # Inline values.
  inline <- names(records)[vapply(
    records,
    function(r) isTRUE(r$inline),
    logical(1)
  )]
  for (k in setdiff(inline, snap$values)) {
    add("value_missing", key = k)
  }
  for (k in intersect(inline, snap$values)) {
    if (snap$value_sizes[[k]] != records[[k]]$bytes) {
      add(
        "value_corrupt",
        key = k,
        detail = sprintf(
          "%d bytes where %s were written",
          snap$value_sizes[[k]],
          format(records[[k]]$bytes)
        )
      )
    }
  }
  for (k in setdiff(snap$values, c(inline, snap$damaged))) {
    add("value_orphan", key = k)
  }

  # Blobs: every reference against its row and its file.
  refs <- table(unlist(lapply(records, function(r) {
    if (!isTRUE(r$inline)) record_blob_name(r)
  })))
  for (k in names(records)) {
    r <- records[[k]]
    if (isTRUE(r$inline)) {
      next
    }
    name <- record_blob_name(r)
    path <- blob_path(s, name)
    # Whether the file is right is asked before whether it is counted: a
    # repair adopts an uncounted file, and must not adopt a damaged one.
    if (!name %in% snap$files) {
      add("blob_missing", key = k, path = path, detail = "file absent")
    } else if (file.size(path) != r$bytes || name %in% corrupt) {
      add(
        "blob_corrupt",
        key = k,
        path = path,
        detail = if (name %in% corrupt) {
          "bytes do not match the name"
        } else {
          "wrong size"
        }
      )
    } else if (is.null(snap$blobs[[name]])) {
      add(
        "refcount_drift",
        key = k,
        path = path,
        detail = if (name %in% snap$blob_rows) {
          "file present but its count is unreadable"
        } else {
          "file present but not counted"
        }
      )
    } else if (blob_is_writable(path)) {
      add("blob_mode", key = k, path = path, detail = "writable, not read-only")
    }
  }
  for (name in names(snap$blobs)) {
    n <- if (name %in% names(refs)) as.double(refs[[name]]) else 0
    if (!identical(snap$blobs[[name]]$refs, n)) {
      add(
        "refcount_drift",
        path = blob_path(s, name),
        detail = sprintf(
          "%s references counted, %s found",
          snap$blobs[[name]]$refs,
          n
        )
      )
    }
  }
  for (name in setdiff(snap$files, names(snap$blobs))) {
    if (!name %in% names(refs)) add("blob_orphan", path = blob_path(s, name))
  }
  for (path in snap$misplaced) {
    add("blob_orphan", path = path, detail = "not where its name puts it")
  }
  for (name in setdiff(snap$blob_rows, c(names(snap$blobs), names(refs)))) {
    add("refcount_drift", path = blob_path(s, name), detail = "count unreadable")
  }

  # Counters.
  if (is.null(snap$counters)) {
    add("counter_drift", detail = "counters record unreadable")
    return(do.call(rbind, out))
  }
  bytes_inline <- sum(vapply(records[inline], function(r) r$bytes, numeric(1)))
  bytes_blob <- sum(vapply(snap$blobs, function(r) r$bytes, numeric(1)))
  if (!isTRUE(all.equal(snap$counters$bytes_inline, bytes_inline))) {
    add(
      "counter_drift",
      detail = sprintf(
        "bytes_inline %s, entries hold %s",
        snap$counters$bytes_inline,
        bytes_inline
      )
    )
  }
  if (!isTRUE(all.equal(snap$counters$bytes_blob, bytes_blob))) {
    add(
      "counter_drift",
      detail = sprintf(
        "bytes_blob %s, files hold %s",
        snap$counters$bytes_blob,
        bytes_blob
      )
    )
  }
  if (length(out) == 0L) finding() else do.call(rbind, out)
}

# Make every projection agree with the records, in the open transaction.
# Entries whose file is gone or damaged go; a counted file nothing refers to is
# returned for reaping after the commit.
check_repair <- function(s, txn, snap, findings) {
  e <- s$engine
  records <- snap$records
  drop <- unique(findings$key[
    findings$kind %in%
      c("record_corrupt", "value_missing", "value_corrupt", "blob_missing", "blob_corrupt")
  ])
  for (k in drop) {
    engine_del(txn, engine_db(e, "meta"), k)
    engine_del(txn, engine_db(e, "values"), k)
    records[[k]] <- NULL
  }
  for (k in findings$key[findings$kind == "value_orphan"]) {
    engine_del(txn, engine_db(e, "values"), k)
  }
  # Rebuild every index from the records that remain.
  for (db in names(snap$index)) {
    engine_clear_db(txn, engine_db(e, db))
  }
  for (k in names(records)) {
    store_index(s, txn, k, records[[k]])
  }

  # Recount references; a row nothing refers to goes, and so does its file.
  refs <- list()
  exts <- list()
  for (r in records) {
    if (isTRUE(r$inline)) {
      next
    }
    name <- record_blob_name(r)
    refs[[name]] <- (refs[[name]] %||% 0) + 1
    exts[name] <- list(r$ext)
  }
  db <- engine_db(e, "blobs")
  corrupt <- basename(findings$path[findings$kind == "blob_corrupt"])
  reap <- unique(c(setdiff(snap$files, names(refs)), corrupt))
  for (name in snap$blob_rows) {
    if (is.null(refs[[name]]) || name %in% corrupt) {
      engine_del(txn, db, name)
    }
  }
  for (path in findings$path[findings$kind == "blob_mode"]) {
    Sys.chmod(path, "0444", use_umask = FALSE)
  }
  bytes_blob <- 0
  for (name in names(refs)) {
    path <- blob_path(s, name)
    row <- list(
      refs = refs[[name]],
      bytes = as.double(file.size(path)),
      ext = exts[[name]]
    )
    engine_put(txn, db, name, record_encode(row))
    bytes_blob <- bytes_blob + row$bytes
  }
  counters <- snap$counters %||% record_counters()
  counters$bytes_inline <- sum(vapply(
    records,
    function(r) if (isTRUE(r$inline)) r$bytes else 0,
    numeric(1)
  ))
  counters$bytes_blob <- bytes_blob
  engine_put(txn, NULL, "counters", record_encode(counters))
  reap
}

# Whether a blob file has a write bit: blobs are 0444 (design.md §7.1), and a
# writable one is what a crash between the chmod and the rename of a replace
# leaves. The mode is read rather than access() asked, which says yes to root.
# Windows has no mode bits to compare.
blob_is_writable <- function(path) {
  .Platform$OS.type == "unix" &&
    bitwAnd(as.integer(file.info(path, extra_cols = FALSE)$mode), strtoi("222", 8L)) != 0L
}

# Staging files left by processes that are gone. A file whose process is known
# to be dead is stale at once; where liveness cannot be asked (Windows), a file
# is stale once it is an hour old. Its age is from the later of its
# modification and change times: codec_file() copies a file's modification
# time with it, so a file staged a moment ago can look a year old.
check_tmp <- function(s, repair) {
  dir <- file.path(s$dir, "tmp")
  files <- list.files(dir, full.names = TRUE)
  out <- list()
  for (path in files) {
    pid <- suppressWarnings(as.integer(sub("-.*$", "", basename(path))))
    info <- file.info(path)
    age <- as.double(difftime(
      Sys.time(),
      max(info$mtime, info$ctime),
      units = "secs"
    ))
    if (is.na(pid) || is.na(age)) {
      next
    }
    if (pid == Sys.getpid()) {
      # This process's own files are in use; another with its PID is from an
      # earlier process the PID was reused from, and is stale.
      if (startsWith(basename(path), stage_prefix())) {
        next
      }
    } else if (!pid_known_dead(pid) && (age < 3600 || pid_alive(pid))) {
      next
    }
    if (repair) {
      blob_unlink(path)
    }
    out[[length(out) + 1L]] <- finding(
      "tmp_stale",
      path = path,
      detail = sprintf("process %d, %.0f seconds old", pid, age),
      repaired = repair
    )
  }
  if (length(out) == 0L) finding() else do.call(rbind, out)
}

# Whether a process is certainly not running: only where signal 0 can ask.
pid_known_dead <- function(pid) {
  .Platform$OS.type == "unix" && !pid_alive(pid)
}

# Whether a process is running. On Windows there is no signal 0 to ask with,
# so a staging file is judged by its age alone.
pid_alive <- function(pid) {
  if (.Platform$OS.type != "unix") {
    return(FALSE)
  }
  isTRUE(tools::pskill(pid, 0L))
}

finding <- function(
  kind = character(),
  key = NA_character_,
  path = NA_character_,
  detail = NA_character_,
  repaired = FALSE
) {
  n <- length(kind)
  data.frame(
    kind = kind,
    key = rep_len(key, n),
    path = rep_len(path, n),
    detail = rep_len(detail, n),
    repaired = rep_len(repaired, n),
    stringsAsFactors = FALSE
  )
}

raw_hex <- function(bytes) {
  paste(format(bytes), collapse = "")
}

hex_raw <- function(hex) {
  as.raw(strtoi(
    substring(hex, seq(1L, nchar(hex), 2L), seq(2L, nchar(hex), 2L)),
    16L
  ))
}

# The stored key an index row belongs to, for reporting.
index_row_key <- function(db, hex) {
  bytes <- hex_raw(hex)
  if (db == "tags") tag_key_stored(bytes) else index_key_parts(bytes)$stored
}
