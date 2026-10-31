# Round trip through a codec, via a real file.
round_trip <- function(codec, value) {
  path <- withr::local_tempfile(.local_envir = parent.frame())
  info <- codec_encode(codec, value, path)
  codec_decode(codec, path, info$meta)
}

# Values codec_rds() must bring back identical.
rds_values <- list(
  NULL, 1L, c(1.5, NA, NaN, Inf), c(TRUE, NA), "x", c("a", NA, "é"),
  as.raw(0:255), 1i,
  factor(c("b", "a"), levels = c("a", "b", "z")),
  as.Date("2026-08-29"), as.POSIXct("2026-08-29 10:00:00.5", tz = "Europe/Zurich"),
  as.difftime(3, units = "hours"),
  structure(1:3, class = "my_class", extra = list(a = 1)),
  list(a = 1, b = list(c = "d")), list(),
  data.frame(x = 1:3, y = c("a", "b", NA), row.names = c("r1", "r2", "r3")),
  matrix(1:6, 2, dimnames = list(c("a", "b"), NULL))
)
