counted <- function() {
  env <- new.env()
  env$n <- 0
  env$f <- function(x, y = 2, verbose = FALSE, ...) {
    env$n <- env$n + 1
    x * y
  }
  env
}

test_that("a memoised function computes once and then reads back", {
  s <- local_stash()
  c <- counted()
  f <- c$f
  mf <- stash_memoise(f, s)
  expect_identical(mf(3), 6)
  expect_identical(mf(3), 6)
  expect_identical(c$n, 1)
  expect_true(is_stash_memoised(mf))
  expect_false(is_stash_memoised(f))
  expect_s3_class(mf, "dastash_memoised")
  expect_identical(names(formals(mf)), names(formals(f)))
})

test_that("positional, named and default arguments are one call", {
  s <- local_stash()
  c <- counted()
  f <- c$f
  mf <- stash_memoise(f, s)
  mf(3)
  mf(x = 3)
  mf(3, y = 2)
  mf(y = 2, 3)
  mf(3, 2, FALSE)
  expect_identical(c$n, 1)
  mf(3, y = 5)
  expect_identical(c$n, 2)
  expect_identical(stash_memoise_key(mf, 3), "f/v1/{verbose=l:F,x=i:3,y=i:2}")
  expect_identical(stash_memoise_key(mf, 3L), stash_memoise_key(mf, 3))
})

test_that("omit keeps an argument out of the key", {
  s <- local_stash()
  c <- counted()
  f <- c$f
  mf <- stash_memoise(f, s, omit = "verbose")
  mf(3, verbose = TRUE)
  mf(3, verbose = FALSE)
  expect_identical(c$n, 1)
  expect_identical(stash_memoise_key(mf, 3, verbose = TRUE), "f/v1/{x=i:3,y=i:2}")
})

test_that("key replaces how arguments are keyed, under the same prefix", {
  s <- local_stash()
  c <- counted()
  f <- c$f
  mf <- stash_memoise(f, s, key = function(args) args$x)
  mf(3, y = 2)
  mf(3, y = 9)
  expect_identical(c$n, 1)
  expect_identical(stash_memoise_key(mf, 3), "f/v1/i:3")
})

test_that("dots are keyed by position and name", {
  s <- local_stash()
  c <- counted()
  f <- c$f
  mf <- stash_memoise(f, s)
  mf(1, 2, FALSE, "a", b = "c")
  mf(1, 2, FALSE, "a", b = "c")
  mf(1, 2, FALSE, b = "c", "a")
  expect_identical(c$n, 2)
})

test_that("arguments are evaluated once, and lazily only as keys need", {
  s <- local_stash()
  evaluated <- 0
  arg <- function() {
    evaluated <<- evaluated + 1
    5
  }
  mf <- stash_memoise(function(x) x + 1, s, name = "plus_one")
  expect_identical(mf(arg()), 6)
  expect_identical(evaluated, 1)
})

test_that("a default that depends on the body is left out of the key", {
  s <- local_stash()
  f <- function(x, n = length(y)) {
    y <- rep(x, 3)
    n
  }
  mf <- stash_memoise(f, s)
  expect_identical(mf(1), 3L)
  expect_identical(stash_memoise_key(mf, 1), "f/v1/{x=i:1}")
})

test_that("version and name are part of the key", {
  s <- local_stash()
  c <- counted()
  f <- c$f
  v1 <- stash_memoise(f, s)
  v2 <- stash_memoise(f, s, version = 2)
  other <- stash_memoise(f, s, name = "g")
  v1(1)
  v2(1)
  other(1)
  expect_identical(c$n, 3)
  expect_identical(stash_memoise_key(v2, 1), "f/v2/{verbose=l:F,x=i:1,y=i:2}")
})

test_that("forget drops one call and forget_all every call of the function", {
  s <- local_stash()
  c <- counted()
  f <- c$f
  mf <- stash_memoise(f, s)
  stash_set(s, "unrelated", 1)
  mf(1)
  mf(2)
  expect_invisible(stash_forget(mf, 1))
  expect_identical(stash_keys(s), c(stash_memoise_key(mf, 2), "unrelated"))
  mf(1)
  expect_identical(c$n, 3)
  stash_forget_all(mf)
  expect_identical(stash_keys(s), "unrelated")
})

test_that("results are stored with expire, tags and codec", {
  s <- local_stash()
  mf <- stash_memoise(function(x) paste0("v", x), s, name = "tagged", expire = 3600, tags = "results", codec = codec_rds())
  mf(1)
  e <- stash_entries(s, tag = "results")
  expect_identical(e$key, stash_memoise_key(mf, 1))
  expect_identical(e$codec, "rds")
  expect_false(is.na(e$expires))
  short <- stash_memoise(function(x) x, s, name = "short", expire = 0)
  short(1)
  expect_false(stash_has(s, stash_memoise_key(short, 1)))
})

test_that("a stored NULL is a hit, and visibility is kept on a miss", {
  s <- local_stash()
  n <- 0
  mf <- stash_memoise(function(x) {
    n <<- n + 1
    invisible(NULL)
  }, s, name = "nothing")
  expect_invisible(mf(1))
  expect_null(mf(1))
  expect_identical(n, 1)
})

test_that("unkeyable arguments are refused with a hint", {
  s <- local_stash()
  mf <- stash_memoise(function(env) 1, s, name = "uses_env")
  cnd <- expect_error(mf(globalenv()), class = "dastash_key_invalid")
  expect_match(conditionMessage(cnd), "omit")
  ok <- stash_memoise(function(env) 1, s, name = "omits_env", omit = "env")
  expect_identical(ok(globalenv()), 1)
})

test_that("stash_memoise() checks what it is given", {
  s <- local_stash()
  expect_error(stash_memoise(function(x) x, s), class = "dastash_key_invalid")
  expect_error(stash_memoise(1, s), class = "dastash_type_error")
  expect_error(stash_memoise(identity, s, name = "a/b"), class = "dastash_key_invalid")
  expect_error(stash_memoise(identity, s, name = "{x"), class = "dastash_key_invalid")
  expect_error(stash_memoise(identity, s, key = "x"), class = "dastash_type_error")
  expect_error(stash_memoise(identity, s, expire = NA), class = "dastash_type_error")
  expect_error(stash_memoise(identity, s, "extra"), class = "rlib_error_dots_nonempty")
  mf <- stash_memoise(identity, s)
  expect_error(stash_memoise(mf, s), class = "dastash_type_error")
  expect_error(stash_memoise_key(identity, 1), class = "dastash_type_error")
  expect_identical(stash_memoise_key(stash_memoise(base::identity, s), 1), "identity/v1/{x=i:1}")
})

test_that("a memoised function prints what it is", {
  s <- local_stash()
  mf <- stash_memoise(identity, s)
  expect_output(print(mf), "<dastash_memoised> identity v1")
})

test_that("a memoised function on a closed stash says so", {
  s <- stash(withr::local_tempdir())
  mf <- stash_memoise(identity, s)
  stash_close(s)
  expect_error(mf(1), class = "dastash_closed")
})

test_that("eight processes calling one memoised function agree", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- stash(dir)
  withr::defer(stash_close(s))
  jobs <- lapply(1:8, function(i) {
    callr::r_bg(function(dir) {
      s <- dastash::stash(dir)
      on.exit(dastash::stash_close(s))
      slow <- function(x) {
        cat("computed\n", file = file.path(dir, "log"), append = TRUE)
        Sys.sleep(0.2)
        x * 10
      }
      f <- dastash::stash_memoise(slow, s)
      f(7)
    }, args = list(dir = dir))
  })
  results <- lapply(jobs, function(job) {
    job$wait(timeout = 60000)
    job$get_result()
  })
  expect_true(all(vapply(results, identical, logical(1), 70)))
  computed <- length(readLines(file.path(dir, "log")))
  expect_gte(computed, 1)
  expect_lte(computed, 8)
  expect_identical(stash_count(s), 1L)
})
