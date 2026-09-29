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
