# The store: layout on disk, the store-level records, and the entry operations
# a verb runs inside its transaction (design.md §7, §12).

# Settings every process on a store must agree on (design.md §12).
store_level_settings <- c("size_limit", "eviction", "inline_max", "codec")

# The named databases this configuration uses (design.md §7.2): one eviction
# index, the one the policy walks, and none for `eviction = "none"`.
store_databases <- function(config) {
  c("meta", "values", "expiry", "blobs", "tags", eviction_index(config$eviction))
}

eviction_index <- function(eviction) {
  switch(eviction,
    "least-recently-stored" = "stored",
    NULL
  )
}

store_create_layout <- function(dir) {
  for (sub in c("blobs", "tmp")) {
    path <- file.path(dir, sub)
    if (!dir.exists(path)) dir.create(path, recursive = TRUE, showWarnings = FALSE)
  }
}

# Write the format, config and counters records of a new store, or check an
# existing store's against this package and this call. Returns the store-level
# settings in force.
store_init <- function(s, config, explicit, call) {
  e <- s$engine
  read_records <- function(txn) {
    list(format = engine_get(txn, NULL, "format"), config = engine_get(txn, NULL, "config"))
  }
  # An existing store is only read, so opening it never waits for the write
  # lock; only a new one takes it, to write its records.
  found <- engine_read(e, read_records, call = call)
  if (!is.null(found$format)) {
    return(store_check(found, config, explicit, s$dir, call))
  }
  if (e$readonly) {
    abort_not_found(sprintf("%s is not a dastash stash.", encodeString(s$dir, quote = "\"")), dir = s$dir, call = call)
  }
  engine_write(e, function(txn) {
    found <- read_records(txn)
    if (is.null(found$format)) {
      engine_put(txn, NULL, "format", record_encode(record_format()))
      engine_put(txn, NULL, "config", record_encode(config))
      engine_put(txn, NULL, "counters", record_encode(record_counters()))
      return(config)
    }
    store_check(found, config, explicit, s$dir, call)
  }, timeout = s$timeout, call = call)
}

store_check <- function(found, config, explicit, dir, call) {
  format <- record_decode(found$format)
  newer <- c(
    format = format$format_version > FORMAT_VERSION,
    `key encoding` = format$key_encoding_version > KEY_ENCODING_VERSION,
    `index encoding` = format$index_encoding_version > INDEX_ENCODING_VERSION
  )
  if (any(newer)) {
    abort_version_unsupported(
      c(
        sprintf("This stash was written with a newer %s than this version of dastash reads.", names(newer)[newer][[1L]]),
        i = "Update dastash to open it."
      ),
      dir = dir, call = call
    )
  }
  persisted <- record_decode(found$config)
  differ <- vapply(store_level_settings, function(name) {
    isTRUE(explicit[[name]]) && !identical(config[[name]], persisted[[name]])
  }, logical(1))
  if (any(differ)) {
    name <- store_level_settings[differ][[1L]]
    abort_config_conflict(
      c(
        sprintf(
          "`%s = %s` disagrees with this stash's %s.",
          name, format_setting(config[[name]]), format_setting(persisted[[name]])
        ),
        i = "Store-level settings are fixed when a stash is created; leave the argument out to use the stored value."
      ),
      dir = dir, setting = name, call = call
    )
  }
  persisted
}

format_setting <- function(x) {
  if (is.character(x)) encodeString(x, quote = "\"") else format(x)
}

store_counters_add <- function(txn, delta) {
  counters <- record_decode(engine_get(txn, NULL, "counters"))
  for (name in names(delta)) counters[[name]] <- counters[[name]] + delta[[name]]
  engine_put(txn, NULL, "counters", record_encode(counters))
}

store_counters <- function(txn) {
  record_decode(engine_get(txn, NULL, "counters"))
}

# The meta record stored under `stored`, or NULL.
store_get_record <- function(s, txn, stored) {
  bytes <- engine_get(txn, engine_db(s$engine, "meta"), stored)
  if (is.null(bytes)) NULL else record_decode(bytes)
}

# Write one entry in the open transaction, replacing whatever the key held. An
# inline value goes into `values`; a blob gets its reference first, then the
# old value is released, so replacing an entry with the same bytes never lets
# their file go.
store_put_entry <- function(s, txn, key, enc, now, expire = Inf, tags = character()) {
  e <- s$engine
  old <- store_get_record(s, txn, key$stored)
  inline <- is.null(enc$blob)
  record <- record_entry(enc, key, now, inline = inline, expire = expire)
  record$tags <- tags
  if (inline) {
    engine_put(txn, engine_db(e, "values"), key$stored, enc$bytes)
    store_counters_add(txn, list(bytes_inline = record$bytes))
  } else {
    record$blob <- enc$blob$hash
    record$ext <- enc$blob$ext
    store_ref_blob(s, txn, enc$blob)
  }
  if (!is.null(old)) {
    store_release(s, txn, key$stored, old, value_replaced = inline)
  }
  engine_put(txn, engine_db(e, "meta"), key$stored, record_encode(record))
  store_index(s, txn, key$stored, record)
  invisible(record)
}

# Undo what a record held: its index rows, and its inline value or its
# reference to a blob.
store_release <- function(s, txn, stored, old, value_replaced = FALSE) {
  store_unindex(s, txn, stored, old)
  if (isTRUE(old$inline)) {
    if (!value_replaced) engine_del(txn, engine_db(s$engine, "values"), stored)
    store_counters_add(txn, list(bytes_inline = -old$bytes))
  } else {
    store_unref_blob(s, txn, record_blob_name(old))
  }
}

# Rewrite an entry's record, keeping its value, and its index rows with it.
store_update_record <- function(s, txn, stored, old, record) {
  store_unindex(s, txn, stored, old)
  engine_put(txn, engine_db(s$engine, "meta"), stored, record_encode(record))
  store_index(s, txn, stored, record)
  invisible(record)
}

# The index rows one record implies, as a list of `db` and `key`. Every index
# is a projection of the record, so this is the only place that knows which
# rows exist (design.md §7.2, §7.5), and stash_check() rebuilds from it. A
# never-expiring entry has no expiry row (D7).
index_rows <- function(s, stored, record) {
  rows <- list()
  if (is.finite(record$expire)) {
    rows[[length(rows) + 1L]] <- list(db = "expiry", key = index_key(record$expire, stored))
  }
  if (identical(s$config$eviction, "least-recently-stored")) {
    rows[[length(rows) + 1L]] <- list(db = "stored", key = index_key(record$stored, stored))
  }
  for (tag in record$tags) {
    rows[[length(rows) + 1L]] <- list(db = "tags", key = tag_key(tag, stored))
  }
  rows
}

store_index <- function(s, txn, stored, record) {
  for (row in index_rows(s, stored, record)) {
    engine_put(txn, engine_db(s$engine, row$db), row$key, raw())
  }
}

store_unindex <- function(s, txn, stored, record) {
  for (row in index_rows(s, stored, record)) {
    engine_del(txn, engine_db(s$engine, row$db), row$key)
  }
}

# `tag ‖ 0x00 ‖ key`: every key carrying a tag is one prefix scan.
tag_key <- function(tag, stored) {
  c(charToRaw(tag), as.raw(0L), charToRaw(stored))
}

tag_key_stored <- function(bytes) {
  nul <- which(bytes == as.raw(0L))[[1L]]
  stored <- rawToChar(bytes[-seq_len(nul)])
  Encoding(stored) <- "UTF-8"
  stored
}

# An ordered index key: eight bytes of order, then the stored key, so rows are
# unique and a walk learns what to delete without a second lookup.
index_key <- function(value, stored) {
  c(enc_f64(value), charToRaw(stored))
}

index_key_parts <- function(bytes) {
  stored <- rawToChar(bytes[-(1:8)])
  Encoding(stored) <- "UTF-8"
  list(value = dec_f64(bytes[1:8]), stored = stored)
}

# Remove one entry in the open transaction. Returns whether it existed.
store_delete_entry <- function(s, txn, stored) {
  e <- s$engine
  old <- store_get_record(s, txn, stored)
  if (is.null(old)) {
    return(FALSE)
  }
  engine_del(txn, engine_db(e, "meta"), stored)
  store_release(s, txn, stored, old)
  TRUE
}

# The key a caller named, and where it is stored. A digested key is found by
# its digest; its record's text confirms it is the key asked for.
store_key <- function(key, call = rlang::caller_env()) {
  text <- key_canon(key, call = call)
  c(list(text = text), key_storage(text))
}

store_record_matches <- function(record, key) {
  !isTRUE(key$digested) || is.null(record$key_text) || identical(record$key_text, key$text)
}

# The key text to report for a stored key: itself, or for a digested key the
# text its record kept, or the digest form when the text was too long to keep.
store_display_key <- function(s, txn, stored) {
  if (!startsWith(stored, "#")) {
    return(stored)
  }
  record <- store_get_record(s, txn, stored)
  record$key_text %||% stored
}

# Prefix scans --------------------------------------------------------------

# Whether a record belongs to a digested key: one longer than KEY_MAX, stored
# under `#` and the SHA-256 of its text (design.md §5.3).
record_digested <- function(record) {
  !is.null(record$key_bytes)
}

# Whether a digested key's text begins with `prefix`, judged by the text its
# record kept, or by its preview when the prefix fits inside the preview. A
# key too long to keep, with a prefix longer than its preview, cannot be told
# and does not match.
record_key_starts_with <- function(record, prefix) {
  if (!is.null(record$key_text)) {
    return(startsWith(record$key_text, prefix))
  }
  preview <- record$key_preview
  !is.null(preview) && nchar(prefix, type = "bytes") <= nchar(preview, type = "bytes") &&
    startsWith(preview, prefix)
}

# Whether each stored key in `x` sorts at or after `start`, in byte order.
stored_at_or_after <- function(x, start) {
  vapply(x, function(k) order(c(start, k), method = "radix")[[1L]] == 1L, logical(1), USE.NAMES = FALSE)
}

# The entries whose key *text* begins with `prefix`, at or after the stored key
# `start`, in stored-key order: at most `n` of them, and only live ones when
# `now` is given. Returns a list of `stored` keys and their `records`.
#
# A key up to KEY_MAX bytes is stored as itself, so the prefix is a range of
# `meta`, scanned in order. A longer key is stored by digest under `#`, where
# its prefix says nothing about where it sorts, so every digested record is
# read and judged by its text. Digested keys are expected to be few.
store_scan_prefix <- function(s, txn, prefix, start = NULL, n = Inf, now = NULL) {
  meta <- engine_db(s$engine, "meta")
  keep <- function(stored, records) {
    ok <- if (is.null(now)) rep(TRUE, length(records)) else vapply(records, is_live, logical(1), now = now)
    if (!is.null(start)) ok <- ok & stored_at_or_after(stored, start)
    ok
  }

  # Plain keys: the prefix's range, a chunk at a time until `n` are found.
  from <- if (!is.null(start) && stored_at_or_after(start, prefix)) start else prefix
  stored <- character()
  records <- list()
  first <- TRUE
  repeat {
    remaining <- n - length(stored)
    ask <- if (is.finite(remaining)) remaining + !first else Inf
    got <- engine_scan(txn, meta, prefix = prefix, start = from, n = ask, as = "character", values = TRUE)
    keys <- got$keys
    recs <- lapply(got$values, record_decode)
    if (!first && length(keys) > 0L) {
      keys <- keys[-1L]
      recs <- recs[-1L]
    }
    ok <- keep(keys, recs) & !vapply(recs, record_digested, logical(1))
    stored <- c(stored, keys[ok])
    records <- c(records, recs[ok])
    if (!is.finite(ask) || length(got$keys) < ask || length(stored) >= n) break
    from <- got$keys[[length(got$keys)]]
    first <- FALSE
  }

  # Digested keys: every one, judged by its text.
  got <- engine_scan(txn, meta, prefix = "#", as = "character", values = TRUE)
  recs <- lapply(got$values, record_decode)
  ok <- vapply(recs, function(r) record_digested(r) && record_key_starts_with(r, prefix), logical(1))
  ok <- ok & keep(got$keys, recs)
  stored <- c(stored, got$keys[ok])
  records <- c(records, recs[ok])

  o <- order(stored, method = "radix")
  o <- o[seq_len(min(length(o), n))]
  list(stored = stored[o], records = records[o])
}
