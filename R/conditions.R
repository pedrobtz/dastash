#' Conditions raised by dazcache
#'
#' @description
#' Every error dazcache raises inherits from `dazcache_error`, and from exactly
#' one class that says what went wrong. Catch the specific class to tell "compute
#' it again" apart from "the store is broken":
#'
#' | Class | Raised when |
#' |---|---|
#' | `dazcache_key_invalid` | An object the key encoding does not cover; a partially named vector; an anonymous memoised function without `name` |
#' | `dazcache_not_found` | A read of an absent or expired key without `default`; `cache()` with `create = FALSE` on a missing directory |
#' | `dazcache_type_error` | A counter operation on a non-counter or past 2^53; a path or lazy read of an entry of the wrong shape; a value a codec cannot store; an `expire` that is `NA` or `NaN` |
#' | `dazcache_codec_error` | Encoding or decoding failed; a codec's package is not installed; a record names a codec the handle does not know |
#' | `dazcache_blob_corrupt` | A read finds the bytes behind a record, a file or an inline value, missing or not the size its record holds |
#' | `dazcache_busy` | The write lock was not acquired within `timeout` |
#' | `dazcache_store_full` | The database reached its `map_size` |
#' | `dazcache_readonly` | A write on a read-only handle |
#' | `dazcache_config_conflict` | An explicit store-level setting disagrees with the stored one |
#' | `dazcache_version_unsupported` | The store was written by a newer format or key encoding |
#' | `dazcache_forked` | A handle used in a process that did not open it |
#' | `dazcache_closed` | A verb on a closed handle |
#' | `dazcache_unsupported` | The platform or this release cannot do it |
#' | `dazcache_engine_error` | Any other failure of the storage engine, with the original condition as `parent` |
#'
#' Conditions carry structured fields where they apply, such as `key`, `dir`,
#' `path` and `codec`, so a handler can act on them without parsing the message.
#'
#' dazcache raises one warning, of class `dazcache_memoise_unstored` and
#' `dazcache_warning`: a memoised function computed a result but the cache was
#' busy, full or read-only, so it was returned without being stored. Its
#' `parent` is the error that prevented storing it.
#'
#' @name dazcache-conditions
NULL

# The fixed taxonomy of design.md §13. A class not listed here cannot be raised.
dazcache_conditions <- c(
  "key_invalid",
  "not_found",
  "type_error",
  "codec_error",
  "blob_corrupt",
  "busy",
  "store_full",
  "readonly",
  "config_conflict",
  "version_unsupported",
  "forked",
  "closed",
  "unsupported",
  "engine_error"
)

# Every dazcache error goes through here, so the class chain is always
# `dazcache_<class>`, `dazcache_error`, `rlang_error`, `error`, `condition`.
# Structured fields go in `...`; `parent` chains an underlying condition.
dazcache_abort <- function(
  class,
  message,
  ...,
  call = rlang::caller_env(),
  parent = NULL
) {
  if (
    !is.character(class) ||
      length(class) != 1L ||
      !class %in% dazcache_conditions
  ) {
    rlang::abort(
      sprintf(
        "Internal error: unknown dazcache condition class %s.",
        format(class)
      ),
      call = NULL
    )
  }
  rlang::abort(
    message,
    class = c(paste0("dazcache_", class), "dazcache_error"),
    ...,
    call = call,
    parent = parent
  )
}

abort_key_invalid <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("key_invalid", message, ..., call = call)
}

abort_not_found <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("not_found", message, ..., call = call)
}

abort_type_error <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("type_error", message, ..., call = call)
}

abort_codec_error <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("codec_error", message, ..., call = call)
}

abort_blob_corrupt <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("blob_corrupt", message, ..., call = call)
}

abort_busy <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("busy", message, ..., call = call)
}

abort_store_full <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("store_full", message, ..., call = call)
}

abort_readonly <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("readonly", message, ..., call = call)
}

abort_config_conflict <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("config_conflict", message, ..., call = call)
}

abort_version_unsupported <- function(
  message,
  ...,
  call = rlang::caller_env()
) {
  dazcache_abort("version_unsupported", message, ..., call = call)
}

abort_forked <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("forked", message, ..., call = call)
}

abort_closed <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("closed", message, ..., call = call)
}

abort_unsupported <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("unsupported", message, ..., call = call)
}

abort_engine_error <- function(message, ..., call = rlang::caller_env()) {
  dazcache_abort("engine_error", message, ..., call = call)
}

# The one warning (D22): a memoised result returned without being stored.
warn_unstored <- function(message, ..., parent = NULL) {
  rlang::warn(
    message,
    class = c("dazcache_memoise_unstored", "dazcache_warning"),
    ...,
    parent = parent
  )
}
