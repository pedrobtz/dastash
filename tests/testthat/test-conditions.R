test_that("every class in the taxonomy has a constructor", {
  ns <- asNamespace("dastash")
  for (class in dastash_conditions) {
    expect_true(
      exists(paste0("abort_", class), envir = ns, inherits = FALSE),
      label = paste0("abort_", class, "()")
    )
  }
})

test_that("every constructor raises its class under dastash_error", {
  ns <- asNamespace("dastash")
  for (class in dastash_conditions) {
    ctor <- get(paste0("abort_", class), envir = ns)
    cnd <- rlang::catch_cnd(ctor("Something went wrong."), "error")
    expect_s3_class(cnd, paste0("dastash_", class))
    expect_identical(
      class(cnd),
      c(paste0("dastash_", class), "dastash_error", "rlang_error", "error", "condition")
    )
    expect_identical(conditionMessage(cnd), "Something went wrong.")
  }
})

test_that("conditions carry structured fields", {
  cnd <- rlang::catch_cnd(
    abort_not_found("No entry for key \"k\".", key = "k", dir = "/tmp/s"),
    "error"
  )
  expect_identical(cnd$key, "k")
  expect_identical(cnd$dir, "/tmp/s")
})

test_that("a parent condition is chained", {
  original <- simpleError("MDBX_PANIC")
  cnd <- rlang::catch_cnd(
    abort_engine_error("The storage engine failed.", parent = original),
    "error"
  )
  expect_identical(cnd$parent, original)
})

test_that("the error names the verb that raised it", {
  verb <- function() abort_readonly("This stash is read-only.")
  cnd <- rlang::catch_cnd(verb(), "error")
  expect_identical(rlang::call_name(cnd$call), "verb")
})

test_that("an unknown class is refused", {
  expect_error(dastash_abort("nope", "x"), "unknown dastash condition class")
})
