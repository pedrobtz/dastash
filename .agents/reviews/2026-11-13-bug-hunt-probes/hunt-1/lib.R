.libPaths(c("<W>/lib", .libPaths()))
suppressMessages(library(dazcache))
tr <- function(expr) tryCatch(expr, error = function(e) paste0("<", class(e)[1], "> ", paste(conditionMessage(e), collapse=" | ")), warning=function(w) paste0("<WARN ", class(w)[1], "> ", conditionMessage(w)))
