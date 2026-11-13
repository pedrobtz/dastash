# Extracted from test-key.R:12

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "dazcache", path = "..")
attach(test_env, warn.conflicts = FALSE)

# test -------------------------------------------------------------------------
withr::local_options(OutDec = ",", scipen = -5, digits = 3, warn = 2)
withr::local_collate("C")
withr::local_timezone("Pacific/Chatham")
expect_golden_vectors()
