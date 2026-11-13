test_that("a memoised function computes once and then reads back", {
  s <- local_cache()
  c <- counted()
  f <- c$f
  mf <- cache_memoise(f, s)
  expect_identical(mf(3), 6)
  expect_identical(mf(3), 6)
  expect_identical(c$n, 1)
  expect_true(is_cache_memoised(mf))
  expect_false(is_cache_memoised(f))
  expect_s3_class(mf, "dazcache_memoised")
  expect_identical(names(formals(mf)), names(formals(f)))
})

test_that("positional, named and default arguments are one call", {
  s <- local_cache()
  c <- counted()
  f <- c$f
  mf <- cache_memoise(f, s)
  mf(3)
  mf(x = 3)
  mf(3, y = 2)
  mf(y = 2, 3)
  mf(3, 2, FALSE)
  expect_identical(c$n, 1)
  mf(3, y = 5)
  expect_identical(c$n, 2)
  expect_identical(cache_memoise_key(mf, 3), "f/v1/{verbose=l:F,x=i:3,y=i:2}")
  expect_identical(cache_memoise_key(mf, 3L), cache_memoise_key(mf, 3))
})

test_that("omit keeps an argument out of the key", {
  s <- local_cache()
  c <- counted()
  f <- c$f
  mf <- cache_memoise(f, s, omit = "verbose")
  mf(3, verbose = TRUE)
  mf(3, verbose = FALSE)
  expect_identical(c$n, 1)
  expect_identical(cache_memoise_key(mf, 3, verbose = TRUE), "f/v1/{x=i:3,y=i:2}")
})

test_that("key replaces how arguments are keyed, under the same prefix", {
  s <- local_cache()
  c <- counted()
  f <- c$f
  mf <- cache_memoise(f, s, key = function(args) args$x)
  mf(3, y = 2)
  mf(3, y = 9)
  expect_identical(c$n, 1)
  expect_identical(cache_memoise_key(mf, 3), "f/v1/i:3")
})

test_that("dots are keyed by position and name", {
  s <- local_cache()
  c <- counted()
  f <- c$f
  mf <- cache_memoise(f, s)
  mf(1, 2, FALSE, "a", b = "c")
  mf(1, 2, FALSE, "a", b = "c")
  mf(1, 2, FALSE, b = "c", "a")
  expect_identical(c$n, 2)
})

test_that("arguments are evaluated once, and lazily only as keys need", {
  s <- local_cache()
  evaluated <- 0
  arg <- function() {
    evaluated <<- evaluated + 1
    5
  }
  mf <- cache_memoise(function(x) x + 1, s, name = "plus_one")
  expect_identical(mf(arg()), 6)
  expect_identical(evaluated, 1)
})

test_that("a default that depends on the body is left out of the key", {
  s <- local_cache()
  f <- function(x, n = length(y)) {
    y <- rep(x, 3)
    n
  }
  mf <- cache_memoise(f, s)
  expect_identical(mf(1), 3L)
  expect_identical(cache_memoise_key(mf, 1), "f/v1/{x=i:1}")
})

test_that("version and name are part of the key", {
  s <- local_cache()
  c <- counted()
  f <- c$f
  v1 <- cache_memoise(f, s)
  v2 <- cache_memoise(f, s, version = 2)
  other <- cache_memoise(f, s, name = "g")
  v1(1)
  v2(1)
  other(1)
  expect_identical(c$n, 3)
  expect_identical(cache_memoise_key(v2, 1), "f/v2/{verbose=l:F,x=i:1,y=i:2}")
})

test_that("forget drops one call and forget_all every call of the function", {
  s <- local_cache()
  c <- counted()
  f <- c$f
  mf <- cache_memoise(f, s)
  cache_set(s, "unrelated", 1)
  mf(1)
  mf(2)
  expect_invisible(cache_forget(mf, 1))
  expect_identical(cache_keys(s), c(cache_memoise_key(mf, 2), "unrelated"))
  mf(1)
  expect_identical(c$n, 3)
  cache_forget_all(mf)
  expect_identical(cache_keys(s), "unrelated")
})

test_that("results are stored with expire, tags and codec", {
  s <- local_cache()
  mf <- cache_memoise(function(x) paste0("v", x), s, name = "tagged", expire = 3600, tags = "results", codec = codec_rds())
  mf(1)
  e <- cache_entries(s, tag = "results")
  expect_identical(e$key, cache_memoise_key(mf, 1))
  expect_identical(e$codec, "rds")
  expect_false(is.na(e$expires))
  short <- cache_memoise(function(x) x, s, name = "short", expire = 0)
  short(1)
  expect_false(cache_has(s, cache_memoise_key(short, 1)))
})

test_that("a stored NULL is a hit, and visibility is kept on a miss", {
  s <- local_cache()
  n <- 0
  mf <- cache_memoise(function(x) {
    n <<- n + 1
    invisible(NULL)
  }, s, name = "nothing")
  expect_invisible(mf(1))
  expect_null(mf(1))
  expect_identical(n, 1)
})

test_that("unkeyable arguments are refused with a hint", {
  s <- local_cache()
  mf <- cache_memoise(function(env) 1, s, name = "uses_env")
  cnd <- expect_error(mf(globalenv()), class = "dazcache_key_invalid")
  expect_match(conditionMessage(cnd), "omit")
  ok <- cache_memoise(function(env) 1, s, name = "omits_env", omit = "env")
  expect_identical(ok(globalenv()), 1)
})

test_that("cache_memoise() checks what it is given", {
  s <- local_cache()
  expect_error(cache_memoise(function(x) x, s), class = "dazcache_key_invalid")
  expect_error(cache_memoise(1, s), class = "dazcache_type_error")
  expect_error(cache_memoise(identity, s, name = "a/b"), class = "dazcache_key_invalid")
  expect_error(cache_memoise(identity, s, name = "{x"), class = "dazcache_key_invalid")
  expect_error(cache_memoise(identity, s, key = "x"), class = "dazcache_type_error")
  expect_error(cache_memoise(identity, s, expire = NA), class = "dazcache_type_error")
  expect_error(cache_memoise(identity, s, "extra"), class = "dazcache_type_error")
  mf <- cache_memoise(identity, s)
  expect_error(cache_memoise(mf, s), class = "dazcache_type_error")
  expect_error(cache_memoise_key(identity, 1), class = "dazcache_type_error")
  expect_identical(cache_memoise_key(cache_memoise(base::identity, s), 1), "identity/v1/{x=i:1}")
})

test_that("a memoised function prints what it is", {
  s <- local_cache()
  mf <- cache_memoise(identity, s)
  expect_output(print(mf), "<dazcache_memoised> identity v1")
})

test_that("a memoised function on a closed cache says so", {
  s <- cache(withr::local_tempdir())
  mf <- cache_memoise(identity, s)
  cache_close(s)
  expect_error(mf(1), class = "dazcache_closed")
})

test_that("eight processes calling one memoised function agree", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- cache(dir)
  withr::defer(cache_close(s))
  jobs <- lapply(1:8, function(i) {
    callr::r_bg(function(dir) {
      s <- dazcache::cache(dir)
      on.exit(dazcache::cache_close(s))
      slow <- function(x) {
        cat("computed\n", file = file.path(dir, "log"), append = TRUE)
        Sys.sleep(0.2)
        x * 10
      }
      f <- dazcache::cache_memoise(slow, s)
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
  expect_identical(cache_count(s), 1L)
})

test_that("cache_forget_all() forgets results whose keys are too long to store as text", {
  s <- local_cache()
  c <- counted()
  f <- c$f
  mf <- cache_memoise(f, s)
  mf(1:3)
  mf(as.double(1:300)) # canonicalises to a key over KEY_MAX bytes, stored digested
  mf(as.double(1:3000)) # over CANON_KEEP_MAX: only a preview of its text is kept
  expect_identical(c$n, 3)
  expect_gt(
    nchar(cache_memoise_key(mf, as.double(1:300)), type = "bytes"),
    KEY_MAX
  )
  expect_gt(
    nchar(cache_memoise_key(mf, as.double(1:3000)), type = "bytes"),
    CANON_KEEP_MAX
  )
  expect_length(cache_keys(s, prefix = "f/"), 3L)
  expect_identical(nrow(cache_entries(s, prefix = "f/")), 3L)
  cache_forget_all(mf)
  expect_identical(cache_count(s), 0L)
  mf(as.double(1:300))
  mf(as.double(1:3000))
  expect_identical(c$n, 5)
})

test_that("a memoised function with its own codec reads back what it stored", {
  s <- local_cache()
  m <- cache_memoise(function(n) rep("x", n), s, codec = lines_codec(), name = "xs")
  expect_identical(m(3), rep("x", 3))
  expect_identical(m(3), rep("x", 3))
})

test_that("a result the cache cannot store is returned, with a warning", {
  dir <- withr::local_tempdir()
  cache_close(cache(dir))
  ro <- local_cache(dir, readonly = TRUE)
  calls <- 0
  m <- cache_memoise(function(x) {
    calls <<- calls + 1
    x * 2
  }, ro, name = "double")
  expect_warning(out <- m(2), class = "dazcache_memoise_unstored")
  expect_identical(out, 4)
  w <- tryCatch(m(2), dazcache_memoise_unstored = function(cnd) cnd)
  expect_s3_class(w$parent, "dazcache_readonly")
  expect_identical(calls, 2)
})

test_that("a file-backed result is the same path on a miss and a hit", {
  s <- local_cache()
  produce <- function(x) {
    p <- withr::local_tempfile(fileext = ".csv", .local_envir = globalenv())
    writeLines(as.character(x), p)
    p
  }
  m <- cache_memoise(produce, s, codec = codec_file(), name = "produce")
  p1 <- m(1)
  p2 <- m(1)
  expect_identical(p1, p2)
  expect_identical(p1, cache_path(s, cache_memoise_key(m, 1)))
  expect_identical(readLines(p1), "1")
})

test_that("a file-backed result the cache cannot store is the producer's path", {
  dir <- withr::local_tempdir()
  cache_close(cache(dir))
  ro <- local_cache(dir, readonly = TRUE)
  p <- withr::local_tempfile(fileext = ".txt", lines = "x")
  m <- cache_memoise(function(x) p, ro, codec = codec_file(), name = "ro_file")
  expect_warning(out <- m(1), class = "dazcache_memoise_unstored")
  expect_identical(out, p)
})

test_that("a codec that refuses a result stays an error", {
  s <- local_cache()
  m <- cache_memoise(function(x) list(x), s, codec = codec_raw(), name = "listed")
  expect_error(m(1), class = "dazcache_type_error")
})

test_that("cache_forget_all() takes only the function's versions, not keys that extend its name (#108)", {
  s <- local_cache()
  f <- function(x) x
  m1 <- cache_memoise(f, s, name = "q", version = 1)
  m10 <- cache_memoise(f, s, name = "q", version = 10)
  m1(1)
  m10(2)
  m1(strrep("a", 5000))
  users <- c("q/video", "q/v", "q/v1x", "q/v1", "q/vv/1")
  for (k in users) cache_set(s, k, k)
  cache_forget_all(m1)
  expect_identical(sort(cache_keys(s)), sort(users))
})

test_that("a hit is as visible as the producer's result was on the miss (#109)", {
  s <- local_cache()
  quiet <- cache_memoise(function(x) invisible(x), s, name = "quiet")
  loud <- cache_memoise(function(x) x, s, name = "loud")
  for (i in 1:2) {
    expect_false(withVisible(quiet(1))$visible)
    expect_true(withVisible(loud(1))$visible)
  }
})
