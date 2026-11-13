# Extracted from test-fixture.R:45

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
s <- cache(dir)
withr::defer(cache_close(s))
expect_identical(cache_incr(s, "hits"), 42)
cache_set(s, "new", runif(500))
cache_delete(s, "blob")
cache_expire(s)
expect_identical(cache_get(s, "expiring"), "until 2100")
