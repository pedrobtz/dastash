# The catalogue (design.md §3.5): entries as a plain data frame, and the
# cache's statistics as one row.

#' The catalogue of a cache
#'
#' @description
#' `cache_entries()` returns one row per live entry. `prefix` and `tag` select
#' entries through the cache's indexes; filter the rest with ordinary data
#' frame tools. `cache_info()` returns the row for one key, or `NULL`.
#'
#' `cache_stats()` returns one row describing the whole cache.
#'
#' @inheritParams cache_keys
#' @param tag Only entries carrying this tag.
#'
#' @return `cache_entries()` and `cache_info()` return a data frame with columns
#'   `key`, `bytes`, `codec`, `inline`, `blob`, `tags` (a list of character
#'   vectors), `shape`, `stored`, `accessed`, `hits` and `expires` (`NA` for
#'   never). In this release `accessed` is always `stored` and `hits` always 0:
#'   reads are not yet recorded. `cache_stats()` returns a one-row data frame
#'   with `count`, `bytes_inline`, `bytes_blob`, `volume`, `size_limit`,
#'   `evictions`, `expired`, `eviction`, `durability`, `format_version` and
#'   `key_encoding_version`.
#'
#' @examples
#' s <- local_cache()
#' cache_set(s, "a", 1:10, tags = "small")
#' cache_set(s, "b", "text", expire = 3600)
#' cache_entries(s)
#' cache_entries(s, tag = "small")
#' cache_info(s, "b")
#' cache_stats(s)
#' @export
cache_entries <- function(cache, ..., prefix = NULL, tag = NULL, n = Inf) {
  rlang::check_dots_empty()
  check_open(cache)
  if (!is.null(prefix)) {
    check_string_or_empty(prefix, "prefix")
  }
  if (!is.null(tag)) {
    check_string(tag, "tag")
  }
  check_number(n, "n", min = 0, whole = TRUE, allow_inf = TRUE)
  e <- cache$engine
  now <- unclass(Sys.time())
  found <- engine_read(e, function(txn) {
    if (!is.null(tag)) {
      rows <- engine_scan(
        txn,
        engine_db(e, "tags"),
        prefix = c(charToRaw(utf8_text(tag)), as.raw(0L))
      )
      stored <- vapply(rows, tag_key_stored, character(1))
      records <- lapply(stored, function(k) store_get_record(cache, txn, k))
      if (!is.null(prefix)) {
        matches <- vapply(
          seq_along(stored),
          function(i) {
            r <- records[[i]]
            if (!is.null(r) && record_digested(r)) {
              record_key_starts_with(r, prefix)
            } else {
              startsWith(stored[[i]], prefix)
            }
          },
          logical(1)
        )
        stored <- stored[matches]
        records <- records[matches]
      }
    } else if (!is.null(prefix)) {
      return(store_scan_prefix(cache, txn, prefix, now = now))
    } else {
      got <- engine_scan(
        txn,
        engine_db(e, "meta"),
        as = "character",
        values = TRUE
      )
      stored <- got$keys
      records <- lapply(got$values, record_decode)
    }
    live <- vapply(
      records,
      function(r) !is.null(r) && is_live(r, now),
      logical(1)
    )
    list(stored = stored[live], records = records[live])
  })
  keep <- seq_len(min(length(found$stored), n))
  entries_frame(found$stored[keep], found$records[keep])
}

#' @rdname cache_entries
#' @inheritParams cache_get
#' @export
cache_info <- function(cache, key) {
  check_supplied("key")
  check_open(cache)
  key <- store_key(key)
  record <- engine_read(cache$engine, function(txn) {
    store_live_record(cache, txn, key)
  })
  if (is.null(record)) {
    return(NULL)
  }
  entries_frame(key$stored, list(record))
}

#' @rdname cache_entries
#' @export
cache_stats <- function(cache) {
  check_open(cache)
  e <- cache$engine
  got <- engine_read(e, function(txn) {
    list(
      counters = store_counters(txn),
      count = engine_count(txn, engine_db(e, "meta")),
      format = record_decode(engine_get(txn, NULL, "format"))
    )
  })
  counters <- got$counters
  data.frame(
    count = as.integer(got$count),
    bytes_inline = counters$bytes_inline,
    bytes_blob = counters$bytes_blob,
    volume = as.double(engine_info(e)$file_size) + counters$bytes_blob,
    size_limit = cache$config$size_limit,
    evictions = counters$evictions,
    expired = counters$expired,
    eviction = cache$config$eviction,
    durability = cache_durability(cache),
    format_version = got$format$format_version,
    key_encoding_version = got$format$key_encoding_version,
    stringsAsFactors = FALSE
  )
}

entries_frame <- function(stored, records) {
  field <- function(name, type) {
    vapply(records, function(r) r[[name]] %||% NA, type)
  }
  as_time <- function(x) structure(x, class = c("POSIXct", "POSIXt"))
  keys <- store_shown_keys(stored, records)
  expire <- field("expire", numeric(1))
  expire[!is.finite(expire)] <- NA
  inline <- field("inline", logical(1))
  blob <- vapply(
    records,
    function(r) if (isTRUE(r$inline)) NA_character_ else r$blob,
    character(1)
  )
  out <- data.frame(
    key = keys,
    bytes = field("bytes", numeric(1)),
    codec = field("codec", character(1)),
    inline = inline,
    blob = blob,
    stringsAsFactors = FALSE
  )
  out$tags <- lapply(records, function(r) r$tags %||% character())
  out$shape <- field("shape", character(1))
  out$stored <- as_time(field("stored", numeric(1)))
  out$accessed <- as_time(field("accessed", numeric(1)))
  out$hits <- field("hits", numeric(1))
  out$expires <- as_time(expire)
  out
}
