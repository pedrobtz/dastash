source("h.R")
dir <- commandArgs(TRUE)[1]; mode <- commandArgs(TRUE)[2]
cat("locale:", Sys.getlocale("LC_CTYPE"), " utf8:", l10n_info()$`UTF-8`, "\n")
u <- "héllo 日本"; l1 <- iconv("héllo", "UTF-8", "latin1"); by <- u; Encoding(by) <- "bytes"; unk <- rawToChar(charToRaw(u)); bad <- rawToChar(as.raw(c(0x68, 0xe9, 0x6c)))
vals <- list(u = u, l1 = l1, by = by, unk = unk, bad = bad, na = NA_character_, vec = c(u, l1), named = c(a = "x"), raw = charToRaw(u), cls = structure("x", class = "foo"), fac = factor("a"), big = strrep(u, 5000), empty = character(0))
s <- cache(dir, inline_max = 100)
desc <- function(x) if (is.character(x)) paste(class(x)[1], paste(Encoding(x), collapse="/"), paste(sprintf("%s", sapply(x, function(z) if (is.na(z)) "NA" else paste(charToRaw(z)[1:min(8, nchar(z, "bytes"))], collapse=""))), collapse="|")) else paste(class(x)[1], length(x))
if (mode == "write") {
  for (n in names(vals)) { r <- try_(cache_set(s, n, vals[[n]])); if (inherits(r, "err")) { cat(n, ": "); print(r) } }
  for (n in names(vals)) { r <- try_(cache_set(s, paste0("raw_", n), vals[[n]], codec = codec_raw())); if (inherits(r, "err")) { cat("raw_", n, ": "); print(r) } }
}
e <- cache_entries(s); e <- e[order(e$key), ]
for (i in seq_len(nrow(e))) { v <- try_(cache_get(s, e$key[i])); cat(sprintf("%-10s %-4s %6g inl=%-5s %s | %s\n", e$key[i], e$codec[i], e$bytes[i], e$inline[i], substr(e$blob[i] %||% "", 1, 8), if (inherits(v,"err")) paste("ERR", v$msg) else desc(v))) }
`%||%` <- function(a,b) if (is.null(a)) b else a
cat("identical roundtrip (this session):", sapply(names(vals), function(n) { v <- try_(cache_get(s, n)); !inherits(v, "err") && identical(v, vals[[n]]) }), "\n")
print(nrow(cache_check(s, hash = TRUE)))
