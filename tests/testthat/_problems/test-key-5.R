# Extracted from test-key.R:5

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "dazcache", path = "..")
attach(test_env, warn.conflicts = FALSE)

# test -------------------------------------------------------------------------
expect_golden_vectors()
