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

# Run a crash_writer() call and expect its child to have died at the crash
# point, killed by SIGKILL: an ordinary error before the window would leave the
# store looking the same and test nothing.
expect_killed <- function(expr) {
  cnd <- tryCatch(
    {
      expr
      NULL
    },
    callr_status_error = function(cnd) cnd
  )
  expect_s3_class(cnd, "callr_status_error")
  expect_identical(cnd$status, -9L)
}
