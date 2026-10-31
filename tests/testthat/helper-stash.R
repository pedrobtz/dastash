lines_codec <- function() {
  codec(
    "lines",
    encode = function(value, path) writeLines(value, path, useBytes = TRUE),
    decode = function(path, meta) readLines(path, encoding = "UTF-8"),
    supports = function(value) is.character(value) && !anyNA(value)
  )
}
