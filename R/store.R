# The store: layout on disk, the store-level records, and the entry operations
# a verb runs inside its transaction (design.md §7, §12).

# Settings every process on a store must agree on (design.md §12).
store_level_settings <- c("size_limit", "eviction", "inline_max", "codec")

# The named databases this configuration uses. Later stages add the eviction,
# tag and blob indexes.
store_databases <- function(config) {
  c("meta", "values", "expiry")
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
  if (e$readonly) {
    found <- engine_read(e, read_records, call = call)
    if (is.null(found$format)) {
      abort_not_found(sprintf("%s is not a dastash stash.", encodeString(s$dir, quote = "\"")), dir = s$dir, call = call)
    }
    return(store_check(found, config, explicit, s$dir, call))
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

# Write one entry (its record and its inline value) in the open transaction,
# replacing whatever the key held.
store_put_entry <- function(s, txn, key, enc, now, expire = Inf) {
  e <- s$engine
  old <- store_get_record(s, txn, key$stored)
  if (!is.null(old)) {
    store_unindex(s, txn, key$stored, old)
  }
  record <- record_entry(enc, key, now, inline = TRUE, expire = expire)
  engine_put(txn, engine_db(e, "meta"), key$stored, record_encode(record))
  engine_put(txn, engine_db(e, "values"), key$stored, enc$bytes)
  store_index(s, txn, key$stored, record)
  delta <- record$bytes - if (!is.null(old) && isTRUE(old$inline)) old$bytes else 0
  store_counters_add(txn, list(bytes_inline = delta))
  invisible(record)
}

# Rewrite an entry's record, keeping its value, and its index rows with it.
store_update_record <- function(s, txn, stored, old, record) {
  store_unindex(s, txn, stored, old)
  engine_put(txn, engine_db(s$engine, "meta"), stored, record_encode(record))
  store_index(s, txn, stored, record)
  invisible(record)
}

# The index rows of one entry. Every index is a projection of the record, so
# these two are the only places that know which rows a record implies
# (design.md §7.2, §7.5). A never-expiring entry has no expiry row (D7).
store_index <- function(s, txn, stored, record) {
  if (is.finite(record$expire)) {
    engine_put(txn, engine_db(s$engine, "expiry"), index_key(record$expire, stored), raw())
  }
}

store_unindex <- function(s, txn, stored, record) {
  if (is.finite(record$expire)) {
    engine_del(txn, engine_db(s$engine, "expiry"), index_key(record$expire, stored))
  }
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
  engine_del(txn, engine_db(e, "values"), stored)
  store_unindex(s, txn, stored, old)
  if (isTRUE(old$inline)) {
    store_counters_add(txn, list(bytes_inline = -old$bytes))
  }
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
