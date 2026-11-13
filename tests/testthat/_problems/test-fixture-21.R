# Extracted from test-fixture.R:21

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "dazcache", path = "..")
attach(test_env, warn.conflicts = FALSE)

# prequel ----------------------------------------------------------------------
local_fixture_store <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  file.copy(test_path("fixtures", "store-0.1.0"), dir, recursive = TRUE)
  dir <- file.path(dir, "store-0.1.0")
  # git keeps no modes: blobs are 0444 as 0.1.0 wrote them.
  Sys.chmod(list.files(file.path(dir, "blobs"), recursive = TRUE, full.names = TRUE), "0444")
  dir
}

# test -------------------------------------------------------------------------
dir <- local_fixture_store()
s <- cache(dir, readonly = TRUE)
withr::defer(cache_close(s))
entries <- fixture_entries(test_path("fixtures", "fixture-file.txt"))
for (e in entries) {
    got <- cache_get(s, e$key)
    if (identical(e$result, "file")) {
      expect_identical(readLines(got), readLines(e$value))
      expect_true(startsWith(normalizePath(got), normalizePath(dir)))
    } else {
      expect_identical(got, e$value, label = paste(cache_key_chr(e$key) |> substr(1, 40)))
    }
  }
