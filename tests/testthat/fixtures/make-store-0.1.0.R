# Writes tests/testthat/fixtures/store-0.1.0.tar.gz, the store test-fixture.R
# reads back. An archive, because blob paths are longer than the 100 bytes a
# portable tarball allows. Run from the package root with the 0.1.0 sources loaded:
#
#   Rscript -e 'devtools::load_all(); source("tests/testthat/fixtures/make-store-0.1.0.R")'
#
# It is the on-disk format every later release must read (CLAUDE.md: a release
# before 1.0.0 writes the final format). After 0.1.0 is released, never
# regenerate it: a failing fixture test means a reader drifted. Its entries
# are listed in fixture_entries(), in tests/testthat/helper-fixture.R.

source("tests/testthat/helper-fixture.R")
dir <- file.path(tempdir(), "store-0.1.0")
unlink(dir, recursive = TRUE)
s <- cache(dir, inline_max = 1024, map_size = 2^20)
for (e in fixture_entries("tests/testthat/fixtures/fixture-file.txt")) {
  if (identical(e$kind, "counter")) {
    cache_incr(s, e$key, by = e$value)
  } else {
    cache_set(s, e$key, e$value, expire = e$expire, tags = e$tags, codec = e$codec)
  }
}
stopifnot(nrow(cache_check(s, hash = TRUE)) == 0L)
cache_close(s)
unlink(file.path(dir, "cache.mdbx-lck"))
unlink(file.path(dir, "tmp"), recursive = TRUE)
old <- setwd(dirname(dir))
utils::tar(
  file.path(old, "tests/testthat/fixtures/store-0.1.0.tar.gz"),
  files = "store-0.1.0",
  compression = "gzip",
  tar = "internal"
)
setwd(old)
