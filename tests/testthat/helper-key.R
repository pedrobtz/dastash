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

# Every golden vector against the encoding, in whatever session this runs in.
expect_golden_vectors <- function() {
  g <- golden()
  expect_gt(nrow(g), 100)
  for (i in seq_len(nrow(g))) {
    row <- g[i, ]
    # A missing bit64 skips its own rows, not every row after them.
    if (grepl("bit64::", row$expr, fixed = TRUE) && !requireNamespace("bit64", quietly = TRUE)) next
    value <- eval(parse(text = row$expr, encoding = "UTF-8"))
    if (name_reread_by_locale(value)) next
    text <- cache_key_chr(value)
    if (startsWith(row$canon, "<") && endsWith(row$canon, " bytes>")) {
      expect_identical(
        paste0("<", nchar(text, type = "bytes"), " bytes>"), row$canon,
        label = row$expr
      )
    } else {
      expect_identical(text, enc2utf8(row$canon), label = row$expr)
    }
    expect_identical(cache_key_hash(value), row$hash, label = row$expr)
    expect_identical(key_storage(text)$stored, enc2utf8(row$stored), label = row$expr)
  }
}
