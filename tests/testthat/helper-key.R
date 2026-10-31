golden <- function() {
  utils::read.csv(
    test_path("golden", "key-vectors.csv"),
    colClasses = "character", encoding = "UTF-8", na.strings = character()
  )
}
