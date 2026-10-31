counted <- function() {
  env <- new.env()
  env$n <- 0
  env$f <- function(x, y = 2, verbose = FALSE, ...) {
    env$n <- env$n + 1
    x * y
  }
  env
}
