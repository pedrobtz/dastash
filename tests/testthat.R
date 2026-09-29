# This file is part of the standard setup for testthat.
# It is recommended that you do not modify it.
#
# Where should you do additional test configuration?
# Learn more about the roles of various files in:
# * https://r-pkgs.org/testing-design.html#sec-tests-files-overview
# * https://testthat.r-lib.org/articles/special-files.html

# testthat is a suggested package: without it, as on CRAN's noSuggests check,
# the tests are skipped rather than failing.
if (requireNamespace("testthat", quietly = TRUE)) {
  library(testthat)
  library(dastash)

  test_check("dastash")
}
