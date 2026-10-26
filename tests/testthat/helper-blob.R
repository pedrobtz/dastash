blob_files <- function(s) {
  list.files(file.path(s$dir, "blobs"), recursive = TRUE)
}

crash_writer <- function(dir, point, fn) {
  callr::r(
    function(dir, fn) {
      s <- dastash::stash(dir, inline_max = 100)
      fn(s)
    },
    args = list(dir = dir, fn = fn),
    env = c(callr::rcmd_safe_env(), DASTASH_CRASH = point),
    error = "error"
  )
}
