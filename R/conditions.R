#' Conditions raised by dastash
#'
#' @description
#' Every error dastash raises inherits from `dastash_error`, and from exactly
#' one class that says what went wrong. Catch the specific class to tell "compute
#' it again" apart from "the store is broken":
#'
#' | Class | Raised when |
#' |---|---|
#' | `dastash_key_invalid` | An object the key encoding does not cover; a partially named vector; an anonymous memoised function without `name` |
#' | `dastash_not_found` | A read of an absent or expired key without `default`; `stash()` with `create = FALSE` on a missing directory |
#' | `dastash_type_error` | A counter operation on a non-counter or past 2^53; a path or lazy read of an entry of the wrong shape; a value a codec cannot store; an `expire` that is `NA` or `NaN` |
#' | `dastash_codec_error` | Encoding or decoding failed; a codec's package is not installed; a record names a codec the handle does not know |
#' | `dastash_blob_corrupt` | A read finds the file behind a record missing |
#' | `dastash_busy` | The write lock was not acquired within `timeout` |
#' | `dastash_store_full` | The database reached its `map_size` |
#' | `dastash_readonly` | A write on a read-only handle |
#' | `dastash_config_conflict` | An explicit store-level setting disagrees with the stored one |
#' | `dastash_version_unsupported` | The store was written by a newer format or key encoding |
#' | `dastash_forked` | A handle used in a process that did not open it |
#' | `dastash_closed` | A verb on a closed handle |
#' | `dastash_unsupported` | The platform or this release cannot do it |
#' | `dastash_engine_error` | Any other failure of the storage engine, with the original condition as `parent` |
#'
#' Conditions carry structured fields where they apply, such as `key`, `dir`,
#' `path` and `codec`, so a handler can act on them without parsing the message.
#'
#' @name dastash-conditions
NULL

# The fixed taxonomy of design.md §13. A class not listed here cannot be raised.
dastash_conditions <- c(
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

# Every dastash error goes through here, so the class chain is always
# `dastash_<class>`, `dastash_error`, `rlang_error`, `error`, `condition`.
# Structured fields go in `...`; `parent` chains an underlying condition.
dastash_abort <- function(class, message, ..., call = rlang::caller_env(), parent = NULL) {
  if (!is.character(class) || length(class) != 1L || !class %in% dastash_conditions) {
    rlang::abort(
      sprintf("Internal error: unknown dastash condition class %s.", format(class)),
      call = NULL
    )
  }
  rlang::abort(
    message,
    class = c(paste0("dastash_", class), "dastash_error"),
    ...,
    call = call,
    parent = parent
  )
}

abort_key_invalid <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("key_invalid", message, ..., call = call)
}

abort_not_found <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("not_found", message, ..., call = call)
}

abort_type_error <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("type_error", message, ..., call = call)
}

abort_codec_error <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("codec_error", message, ..., call = call)
}

abort_blob_corrupt <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("blob_corrupt", message, ..., call = call)
}

abort_busy <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("busy", message, ..., call = call)
}

abort_store_full <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("store_full", message, ..., call = call)
}

abort_readonly <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("readonly", message, ..., call = call)
}

abort_config_conflict <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("config_conflict", message, ..., call = call)
}

abort_version_unsupported <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("version_unsupported", message, ..., call = call)
}

abort_forked <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("forked", message, ..., call = call)
}

abort_closed <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("closed", message, ..., call = call)
}

abort_unsupported <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("unsupported", message, ..., call = call)
}

abort_engine_error <- function(message, ..., call = rlang::caller_env()) {
  dastash_abort("engine_error", message, ..., call = call)
}
