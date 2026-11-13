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
  is.numeric(x) &&
    length(x) == 1L &&
    !is.na(x) &&
    is.finite(x) &&
    x == trunc(x) &&
    abs(x) <= COUNTER_MAX
}

# Split into a signed high word and an unsigned low word, each exact in a
# double, and write both as 32-bit big-endian two's complement.
counter_bytes <- function(x) {
  x <- as.double(x)
  hi <- floor(x / 2^32)
  lo <- x - hi * 2^32
  if (hi < 0) {
    hi <- hi + 2^32
  }
  c(u32_bytes(hi), u32_bytes(lo))
}

counter_value <- function(bytes, call = rlang::caller_env()) {
  if (!is.raw(bytes) || length(bytes) != 8L) {
    abort_codec_error(
      sprintf(
        "A counter is stored in 8 bytes; this one has %d.",
        length(bytes)
      ),
      codec = "counter",
      call = call
    )
  }
  hi <- u32_value(bytes[1:4])
  lo <- u32_value(bytes[5:8])
  if (hi >= 2^31) {
    hi <- hi - 2^32
  }
  hi * 2^32 + lo
}

u32_bytes <- function(n) {
  as.raw(c(n %/% 2^24, (n %/% 2^16) %% 256, (n %/% 2^8) %% 256, n %% 256))
}

u32_value <- function(bytes) {
  sum(as.integer(bytes) * c(2^24, 2^16, 2^8, 1))
}

#' @rdname cache_add
#' @export
cache_incr <- function(cache, key, ..., by = 1, default = 0) {
  check_supplied("key")
  check_dots()
  counter_add(cache, key, by, default)
}

#' @rdname cache_add
#' @export
cache_decr <- function(cache, key, ..., by = 1, default = 0) {
  check_supplied("key")
  check_dots()
  counter_add(cache, key, -by, default)
}

counter_add <- function(cache, key, by, default, call = rlang::caller_env()) {
  check_writable(cache, call)
  if (!is_counter_value(by)) {
    abort_type_error(
      "`by` must be a whole number within \u00b12^53.",
      call = call
    )
  }
  if (!is_counter_value(default)) {
    abort_type_error(
      "`default` must be a whole number within \u00b12^53.",
      call = call
    )
  }
  # An integer64 `by` or `default` is exact here, and the count is a double.
  by <- as.double(by)
  default <- as.double(default)
  key <- store_key(key, call = call)
  codec <- codec_counter()
  engine_write(
    cache$engine,
    function(txn) {
      now <- unclass(Sys.time())
      record <- store_live_record(cache, txn, key, now)
      if (is.null(record)) {
        current <- as.double(default)
        expire <- Inf
        tags <- character()
      } else {
        if (!identical(record$codec, "counter")) {
          abort_type_error(
            sprintf(
              "The key %s holds a value that is not a counter.",
              display_key(key$text)
            ),
            key = key$text,
            call = call
          )
        }
        bytes <- engine_get(txn, engine_db(cache$engine, "values"), key$stored)
        # Damage is raised as cache_get() raises it.
        store_inline_ready(list(record = record, bytes = bytes), key, call)
        current <- counter_value(bytes, call = call)
        expire <- record$expire
        tags <- record$tags
      }
      # Checked before adding: past 2^53 the sum rounds back into range, and
      # the counter would stop moving with no error.
      if (current > COUNTER_MAX - max(by, 0) || current < -COUNTER_MAX - min(by, 0)) {
        abort_type_error(
          sprintf(
            "The counter %s would pass \u00b12^53.",
            display_key(key$text)
          ),
          key = key$text,
          call = call
        )
      }
      value <- current + by
      enc <- codec_encode_value(
        codec,
        value,
        stage = function() NULL,
        call = call
      )
      store_put_entry(cache, txn, key, enc, now, expire = expire, tags = tags)
      store_cull_step(cache, txn, protect = key$stored)
      value
    },
    timeout = cache$timeout,
    call = call
  )
}
