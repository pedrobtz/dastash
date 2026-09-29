# Store-level records and the per-key meta record (design.md §7.2, §7.3).
#
# A record is a named list written with serialize(version = 3). That is allowed
# here and nowhere else near identity: nothing is ever hashed from these bytes,
# and R reads older serialisations. A record grows by adding names, which is
# how later fields arrive without a migration.

FORMAT_VERSION <- 1L

record_encode <- function(record) {
  serialize(record, NULL, version = 3L)
}

record_decode <- function(bytes) {
  unserialize(bytes)
}

record_format <- function() {
  list(
    format_version = FORMAT_VERSION,
    key_encoding_version = KEY_ENCODING_VERSION,
    index_encoding_version = INDEX_ENCODING_VERSION,
    created_at = unclass(Sys.time()),
    created_by = paste("dastash", getNamespaceVersion("dastash"))
  )
}

record_counters <- function() {
  list(bytes_inline = 0, bytes_blob = 0, hits = 0, misses = 0, evictions = 0, expired = 0)
}

# The meta record of one entry. `enc` is what codec_encode_value() returned;
# `key` what key_storage() did.
record_entry <- function(enc, key, now, inline) {
  record <- list(
    stored = now,
    expire = Inf,
    accessed = now,
    hits = 0,
    bytes = as.double(enc$size),
    codec = enc$codec,
    codec_version = enc$version,
    codec_meta = enc$meta,
    inline = inline,
    tags = character(),
    shape = if (identical(enc$codec, "file")) "file" else "value",
    retain_until = NA_real_
  )
  if (isTRUE(key$digested)) {
    record$key_bytes <- key$key_bytes
    record$key_text <- key$key_text
    record$key_preview <- key$key_preview
  }
  record
}
