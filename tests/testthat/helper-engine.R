# An engine on a fresh directory, closed when the calling test ends.
local_engine <- function(..., dir = withr::local_tempdir(.local_envir = env), env = parent.frame()) {
  e <- engine_open(file.path(dir, "cache.mdbx"), ...)
  withr::defer(while (!is.null(engine_registry[[e$path]])) engine_close(e), envir = env)
  e
}

# Put key -> value pairs (strings) into a database in one write.
engine_fill <- function(e, pairs, db = NULL) {
  engine_write(e, function(txn) {
    for (k in names(pairs)) engine_put(txn, engine_db(e, db), k, pairs[[k]])
  })
}

# A child process loads dastash from the library, not from the sources under
# test. R CMD check installs the copy it checks; devtools::test() does not, so
# there the child tests run only when DASTASH_TEST_CHILDREN=true says the
# installed copy is current (after R CMD INSTALL .).
skip_unless_children_see_this_build <- function() {
  skip_if_not_installed("callr")
  if (!testthat::is_checking() && !isTRUE(as.logical(Sys.getenv("DASTASH_TEST_CHILDREN")))) {
    skip("child processes would load an installed dastash, not this build")
  }
}
