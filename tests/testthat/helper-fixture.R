# The entries of the 0.1.0 fixture store (fixtures/make-store-0.1.0.R): one of
# each kind the format records. `file` is the source of the codec_file() entry.
fixture_entries <- function(file) {
  list(
    list(key = "inline", value = list(a = 1L, b = "two", c = c(3.5, NA))),
    list(key = "blob", value = seq(0, 1, length.out = 500)),
    list(key = "raw", value = as.raw(0:255), codec = codec_raw()),
    list(key = "text", value = "café 中文"),
    list(key = "hits", value = 41, kind = "counter"),
    list(key = "tagged", value = 1:3, tags = c("alpha", "beta")),
    list(key = "expiring", value = "until 2100", expire = as.POSIXct("2100-01-01", tz = "UTC")),
    list(key = list(id = 7L, at = as.Date("2026-11-13")), value = "structured"),
    list(key = strrep("long", 150), value = "digested, text kept"),
    list(key = strrep("longer", 1000), value = "digested, preview only"),
    list(key = "file", value = file, codec = codec_file(), result = "file")
  )
}
