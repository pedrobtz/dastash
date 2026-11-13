# Extracted from test-key.R:178

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "dazcache", path = "..")
attach(test_env, warn.conflicts = FALSE)

# test -------------------------------------------------------------------------
far <- structure(c(1e12, -4e15, 1e12 + 1), class = "Date")
expect_identical(anyDuplicated(vapply(seq_along(far), function(i) cache_key_chr(far[i]), "")), 0L)
s <- local_cache()
cache_set(s, far[1], "first")
expect_identical(cache_get(s, far[2], default = "miss"), "miss")
