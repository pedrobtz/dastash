# Order-preserving encodings for index keys (design.md §7.4). libmdbx sorts
# keys as unsigned bytes, so a number must be written so that byte order is
# numeric order. Index encodings are revisable (index_encoding_version) since
# every index is rebuilt from `meta`; the key encoding is not.

INDEX_ENCODING_VERSION <- 1L

# Eight bytes, big-endian IEEE-754, with negatives' bits all inverted and
# non-negatives' sign bit set. Plain big-endian IEEE-754 would sort -1 above
# every positive number and negatives in reverse. -Inf sorts first, Inf last;
# NaN has no position and is refused.
enc_f64 <- function(x, call = rlang::caller_env()) {
  if (!is.numeric(x) || length(x) != 1L || is.na(x)) {
    abort_type_error("An ordered time or quantity must be one number, not NA or NaN.", call = call)
  }
  bytes <- writeBin(as.double(x), raw(), size = 8L, endian = "big")
  if (as.integer(bytes[[1L]]) >= 128L) {
    !bytes
  } else {
    bytes[[1L]] <- bytes[[1L]] | as.raw(0x80)
    bytes
  }
}

dec_f64 <- function(bytes) {
  if (as.integer(bytes[[1L]]) >= 128L) {
    bytes[[1L]] <- bytes[[1L]] & as.raw(0x7F)
  } else {
    bytes <- !bytes
  }
  readBin(bytes, "double", size = 8L, endian = "big")
}

# Eight bytes, big-endian, for a whole number in [0, 2^53].
enc_u64 <- function(n, call = rlang::caller_env()) {
  if (!is.numeric(n) || length(n) != 1L || is.na(n) || n < 0 || n > 2^53 || n != trunc(n)) {
    abort_type_error("An ordered count must be one whole number between 0 and 2^53.", call = call)
  }
  n <- as.double(n)
  out <- raw(8L)
  for (i in 8:1) {
    out[[i]] <- as.raw(n %% 256)
    n <- n %/% 256
  }
  out
}

dec_u64 <- function(bytes) {
  sum(as.integer(bytes) * 256^(7:0))
}
