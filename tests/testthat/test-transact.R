test_that("a block commits as a unit and returns its value", {
  s <- local_stash()
  out <- stash_transact(s, {
    stash_set(s, "a", 1)
    stash_set(s, "b", 2)
    stash_incr(s, "n")
    "done"
  })
  expect_identical(out, "done")
  expect_identical(stash_mget(s, c("a", "b", "n")), list(a = 1, b = 2, n = 1))
})

test_that("an error aborts the whole block", {
  s <- local_stash()
  stash_set(s, "a", "before")
  expect_error(
    stash_transact(s, {
      stash_set(s, "a", "after")
      stash_set(s, "b", 1)
      abort_type_error("changed my mind")
    }),
    class = "dastash_type_error"
  )
  expect_identical(stash_get(s, "a"), "before")
  expect_false(stash_has(s, "b"))
  expect_null(s$engine$txn)
})

test_that("reads inside a block see its writes", {
  s <- local_stash()
  stash_transact(s, {
    stash_set(s, "k", 1)
    expect_identical(stash_get(s, "k"), 1)
    expect_identical(stash_keys(s), "k")
    stash_delete(s, "k")
    expect_false(stash_has(s, "k"))
  })
})

test_that("nested blocks and other handles join the transaction", {
  dir <- withr::local_tempdir()
  s1 <- stash(dir)
  s2 <- stash(dir)
  withr::defer({
    stash_close(s1)
    stash_close(s2)
  })
  expect_error(
    stash_transact(s1, {
      stash_transact(s1, stash_set(s1, "inner", 1))
      stash_set(s2, "other-handle", 2)
      expect_identical(stash_get(s2, "inner"), 1)
      abort_type_error("undo both")
    }),
    class = "dastash_type_error"
  )
  expect_false(any(stash_has(s1, c("inner", "other-handle"))))
})

test_that("an aborted block with files leaves at most orphans", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "kept", runif(100))
  kept <- stash_path(s, "kept")
  try(stash_transact(s, {
    stash_set(s, "new", runif(100))
    stash_delete(s, "kept")
    abort_type_error("no")
  }), silent = TRUE)
  expect_true(file.exists(kept))
  expect_identical(stash_get(s, "kept"), readRDS(kept))
  expect_false(stash_has(s, "new"))
  expect_identical(store_violations(s), character())
  stash_check(s, repair = TRUE)
  expect_length(list.files(file.path(s$dir, "blobs"), recursive = TRUE), 1L)
})

test_that("a committed block unlinks what it released, after the commit", {
  s <- local_stash(inline_max = 100)
  stash_set(s, "a", runif(100))
  path <- stash_path(s, "a")
  stash_transact(s, {
    stash_delete(s, "a")
    # Released but not yet unlinked: the transaction has not committed.
    expect_true(file.exists(path))
  })
  expect_false(file.exists(path))
})

test_that("pop inside a block reads a file that is not yet gone", {
  s <- local_stash(inline_max = 100)
  x <- runif(100)
  stash_set(s, "k", x)
  got <- stash_transact(s, stash_pop(s, "k"))
  expect_identical(got, x)
  expect_false(stash_has(s, "k"))
})

test_that("a read-only or closed stash refuses a transaction", {
  dir <- withr::local_tempdir()
  stash_close(stash(dir))
  ro <- stash(dir, readonly = TRUE)
  expect_error(stash_transact(ro, NULL), class = "dastash_readonly")
  stash_close(ro)
  expect_error(stash_transact(ro, NULL), class = "dastash_closed")
})

test_that("a transaction in another process makes writes busy, not reads", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- stash(dir, timeout = 0.3)
  withr::defer(stash_close(s))
  stash_set(s, "k", "before")
  ready <- file.path(dir, "ready")
  holder <- callr::r_bg(function(dir, ready) {
    s <- dastash::stash(dir)
    on.exit(dastash::stash_close(s))
    dastash::stash_transact(s, {
      dastash::stash_set(s, "k", "inside")
      file.create(ready)
      Sys.sleep(3)
    })
  }, args = list(dir = dir, ready = ready))
  withr::defer(holder$kill())
  for (i in 1:200) if (file.exists(ready)) break else Sys.sleep(0.05)
  expect_error(stash_set(s, "x", 1), class = "dastash_busy")
  # A reader sees the last commit, not the open transaction.
  expect_identical(stash_get(s, "k"), "before")
  holder$wait(timeout = 30000)
  expect_identical(stash_get(s, "k"), "inside")
})

test_that("a process joining an open stash takes its durability", {
  skip_unless_children_see_this_build()
  skip_on_cran()
  dir <- withr::local_tempdir()
  s <- stash(dir, durability = "fast")
  withr::defer(stash_close(s))
  expect_identical(stash_stats(s)$durability, "fast")
  joined <- callr::r(function(dir) {
    s <- dastash::stash(dir, durability = "safe")
    on.exit(dastash::stash_close(s))
    dastash::stash_stats(s)$durability
  }, args = list(dir = dir))
  expect_identical(joined, "fast")
})
