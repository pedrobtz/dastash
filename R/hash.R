# SHA-256, the one hash dastash uses: for digested keys (design.md §5.3) and
# for content-addressed blobs (§6.1). Every hash goes through these functions,
# so the implementation can change without anything else noticing; the output
# cannot, since stored keys and blob names are made of it.
#
# tools::sha256sum() is base R from 4.5.0, computes in C, and streams a file
# without reading it into memory (D13).

hash_bytes <- function(bytes) {
  tools::sha256sum(bytes = bytes)
}

# `text` must already be UTF-8 (utf8_text()); its bytes are what is hashed.
hash_text <- function(text) {
  hash_bytes(charToRaw(text))
}

hash_file <- function(path) {
  unname(tools::sha256sum(path))
}
