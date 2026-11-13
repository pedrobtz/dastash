# R keeps a non-ASCII name's bytes but not their UTF-8 mark. In a session whose
# native encoding reads those bytes as other text (Latin-1: "Ã©" for "é"), the
# name is that text, so a golden expression does not build its row's value.
name_reread_by_locale <- function(value) {
  nms <- names(value)
  if (is.null(nms) || l10n_info()$`UTF-8`) {
    return(FALSE)
  }
  unmarked <- nms[!is.na(nms) & Encoding(nms) == "unknown"]
  native <- iconv(unmarked, from = "", to = "UTF-8")
  # Bytes, not text: as text, a converted string equals its source.
  changed <- vapply(
    seq_along(unmarked),
    function(i) !is.na(native[[i]]) && !identical(charToRaw(native[[i]]), charToRaw(unmarked[[i]])),
    logical(1)
  )
  any(changed)
}

golden <- function() {
  utils::read.csv(
    test_path("golden", "key-vectors.csv"),
    colClasses = "character", encoding = "UTF-8", na.strings = character()
  )
}
