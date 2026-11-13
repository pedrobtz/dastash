test_that("as_cachem() has the cachem methods and semantics", {
  s <- local_cache()
  cache <- as_cachem(s)
  expect_s3_class(cache, "cachem")
  expect_named(cache, c("get", "set", "exists", "remove", "reset", "keys", "prune", "size", "info"))
  expect_true(inherits(cache$get("absent"), "key_missing"))
  expect_identical(cache$get("absent", missing = NA), NA)
  cache$set("abc", 1)
  cache$set("x_1-y", list(2))
  expect_identical(cache$get("abc"), 1)
  expect_true(cache$exists("abc"))
  expect_setequal(cache$keys(), c("abc", "x_1-y"))
  expect_identical(cache$size(), 2L)
  cache$remove("abc")
  expect_false(cache$exists("abc"))
  cache_set(s, "outside", 1)
  cache$reset()
  expect_identical(cache$size(), 0L)
  expect_identical(cache_keys(s), "outside")
  expect_identical(cache$info()$prefix, "cachem/")
  expect_true(cache$prune())
  expect_output(print(cache), "dazcache_cachem")
})

test_that("cachem keys follow cachem's rule", {
  cache <- as_cachem(local_cache())
  for (bad in list("Upper", "has.dot", "a/b", "", NA_character_, 1, c("a", "b"))) {
    expect_error(cache$set(bad, 1), class = "dazcache_key_invalid")
  }
})

test_that("as_cachem() checks its prefix and passes expire through", {
  s <- local_cache()
  expect_error(as_cachem(s, prefix = "{x"), class = "dazcache_key_invalid")
  cache <- as_cachem(s, prefix = "c/", expire = 0)
  cache$set("k", 1)
  expect_false(cache$exists("k"))
})

test_that("memoise::memoise() works on a cache through as_cachem()", {
  skip_if_not_installed("memoise")
  s <- local_cache()
  n <- 0
  f <- memoise::memoise(function(x) {
    n <<- n + 1
    x + 1
  }, cache = as_cachem(s))
  expect_identical(f(1), 2)
  expect_identical(f(1), 2)
  expect_identical(n, 1)
  expect_identical(length(cache_keys(s, prefix = "cachem/")), 1L)
})

test_that("base generics read, write and count", {
  s <- local_cache()
  s[["a"]] <- 1
  s[[list(n = 1)]] <- "structured"
  expect_identical(s[["a"]], 1)
  expect_identical(s[[list(n = 1)]], "structured")
  expect_error(s[["missing"]], class = "dazcache_not_found")
  expect_identical(length(s), 2L)
  expect_identical(as.list(s), list(a = 1, `{n=i:1}` = "structured"))
  # The handle's own fields are still reachable.
  expect_identical(s$dir, cache_dir(s))
})

test_that("as.list() warns on a large cache", {
  s <- local_cache()
  cache_mset(s, stats::setNames(as.list(1:1001), sprintf("k%04d", 1:1001)))
  expect_warning(out <- as.list(s), "1001")
  expect_length(out, 1001L)
})

test_that("an adapter owns only its own keys, and a prefix must be delimited (#108)", {
  s <- local_cache()
  expect_error(as_cachem(s, prefix = "cachem"), class = "dazcache_key_invalid")
  a <- as_cachem(s, prefix = "a/")
  a2 <- as_cachem(s, prefix = "a2/")
  a$set("x", 1)
  a2$set("y", 2)
  cache_set(s, "a/deeper/z", 3)
  expect_identical(a$keys(), "x")
  expect_identical(a$size(), 1L)
  a$reset()
  expect_identical(sort(cache_keys(s)), c("a/deeper/z", "a2/y"))
  expect_identical(a2$get("y"), 2)
})
