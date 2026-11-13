# Extracted from test-key.R:466

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "dazcache", path = "..")
attach(test_env, warn.conflicts = FALSE)

# test -------------------------------------------------------------------------
set.seed(133)
pick <- function(x, n = 1) x[sample.int(length(x), n, replace = TRUE)]
specials <- c("", "a", "b", ",", "=", "[", "]", "{", "}", "(", ")", ":", "!", "~", "%",
    "%2C", "#", "\\", "\n", "\t", "é", "é", "中", "s:a", "i:1", "D{", "~x")
text <- function(n) {
    vapply(seq_len(n), function(i) paste(pick(specials, sample.int(3, 1)), collapse = ""), "")
  }
doubles <- c(0, 1, -1, 2^53, -2^53, 2^53 + 2, 0.1, 1 / 3, -1.5, 1e300, 5e-324, NaN, NA, Inf, -Inf)
days <- c(0, -1, 59, 60, -719528, 2932896, 2932897, -719529, 1e12, -4e15, 2^52)
secs <- c(0, -1, 0.5, 1e-6, -1e-6, 86399.999999, 253402300800, 1e15, -1e15)
atom <- function() {
    n <- pick(c(1L, 1L, 2L, 3L))
    switch(
      pick(c("s", "f", "l", "r", "d", "t", "e", "u")),
      s = text(n),
      f = pick(doubles, n),
      l = pick(c(TRUE, FALSE, NA), n),
      r = as.raw(sample.int(256, n, replace = TRUE) - 1L),
      d = structure(pick(days, n), class = "Date"),
      t = .POSIXct(pick(secs, n), tz = "UTC"),
      e = factor(text(n)),
      u = as.difftime(pick(doubles[is.finite(doubles)], n), units = "secs")
    )
  }
named <- function(x) {
    if (length(x) > 0L && runif(1) < 0.3) {
      nms <- make.unique(text(length(x)))
      nms[!nzchar(nms)] <- "z"
      names(x) <- make.unique(nms)
    }
    x
  }
value <- function(depth = 0L) {
    r <- runif(1)
    if (depth >= 3L || r < 0.55) return(named(atom()))
    if (r < 0.62) return(NULL)
    if (r < 0.70) {
      cols <- sample.int(3, 1)
      rows <- sample.int(3, 1)
      df <- lapply(seq_len(cols), function(j) pick(doubles, rows))
      names(df) <- make.unique(paste0("c", text(cols)))
      return(as.data.frame(df, optional = TRUE))
    }
    named(lapply(seq_len(sample.int(3, 1) - 1L), function(i) value(depth + 1L)))
  }
values <- lapply(seq_len(3000), function(i) value())
values <- values[!duplicated(values)]
keys <- vapply(values, cache_key_chr, "")
dup <- which(duplicated(keys))
if (length(dup) > 0L) {
    first <- match(keys[dup[[1L]]], keys)
    fail(paste(
      "Two different values share a key:",
      paste(deparse(values[[first]]), collapse = ""),
      paste(deparse(values[[dup[[1L]]]]), collapse = ""),
      keys[[first]],
      sep = "\n"
    ))
  }
