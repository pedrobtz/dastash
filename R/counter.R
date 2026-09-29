# Counters (design.md §3.4, D6): a signed 64-bit integer in eight big-endian
# bytes, two's complement, under the internal codec "counter". The value is
# exchanged with R as a double, so it is limited to whole numbers within ±2^53,
# where every integer is exact.

COUNTER_MAX <- 2^53

codec_counter <- function() {
  new_codec(
    "counter",
    encode = function(value, path) writeBin(counter_bytes(value), path),
    decode = function(path, meta) counter_value(readBin(path, "raw", n = 8L)),
    supports = is_counter_value,
    encode_bytes = function(value) list(bytes = counter_bytes(value)),
    decode_bytes = function(bytes, meta) counter_value(bytes)
  )
}

is_counter_value <- function(x) {
  is.numeric(x) && length(x) == 1L && !is.na(x) && is.finite(x) &&
    x == trunc(x) && abs(x) <= COUNTER_MAX
}

# Split into a signed high word and an unsigned low word, each exact in a
# double, and write both as 32-bit big-endian two's complement.
counter_bytes <- function(x) {
  x <- as.double(x)
  hi <- floor(x / 2^32)
  lo <- x - hi * 2^32
  if (hi < 0) hi <- hi + 2^32
  c(u32_bytes(hi), u32_bytes(lo))
}

counter_value <- function(bytes) {
  hi <- u32_value(bytes[1:4])
  lo <- u32_value(bytes[5:8])
  if (hi >= 2^31) hi <- hi - 2^32
  hi * 2^32 + lo
}

u32_bytes <- function(n) {
  as.raw(c(n %/% 2^24, (n %/% 2^16) %% 256, (n %/% 2^8) %% 256, n %% 256))
}

u32_value <- function(bytes) {
  sum(as.integer(bytes) * c(2^24, 2^16, 2^8, 1))
}

#' @rdname stash_add
#' @export
stash_incr <- function(stash, key, ..., by = 1, default = 0) {
  rlang::check_dots_empty()
  counter_add(stash, key, by, default)
}

#' @rdname stash_add
#' @export
stash_decr <- function(stash, key, ..., by = 1, default = 0) {
  rlang::check_dots_empty()
  counter_add(stash, key, -by, default)
}

counter_add <- function(stash, key, by, default, call = rlang::caller_env()) {
  check_writable(stash, call)
  if (!is_counter_value(by)) {
    abort_type_error("`by` must be a whole number within \u00b12^53.", call = call)
  }
  if (!is_counter_value(default)) {
    abort_type_error("`default` must be a whole number within \u00b12^53.", call = call)
  }
  key <- store_key(key, call = call)
  codec <- codec_counter()
  engine_write(stash$engine, function(txn) {
    now <- unclass(Sys.time())
    record <- store_live_record(stash, txn, key, now)
    if (is.null(record)) {
      current <- as.double(default)
      expire <- Inf
      tags <- character()
    } else {
      if (!identical(record$codec, "counter")) {
        abort_type_error(
          sprintf("The key %s holds a value that is not a counter.", display_key(key$text)),
          key = key$text, call = call
        )
      }
      current <- counter_value(engine_get(txn, engine_db(stash$engine, "values"), key$stored))
      expire <- record$expire
      tags <- record$tags
    }
    value <- current + by
    if (abs(value) > COUNTER_MAX) {
      abort_type_error(
        sprintf("The counter %s would pass \u00b12^53.", display_key(key$text)),
        key = key$text, call = call
      )
    }
    enc <- codec_encode_value(codec, value, stage = function() NULL, call = call)
    store_put_entry(stash, txn, key, enc, now, expire = expire, tags = tags)
    value
  }, timeout = stash$timeout, call = call)
}
