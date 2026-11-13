# Extracted from test-key.R:207

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "dazcache", path = "..")
attach(test_env, warn.conflicts = FALSE)

# test -------------------------------------------------------------------------
expect_identical(cache_key_chr(structure(2^52, class = "Date")), "d:12330436978418-07-07")
