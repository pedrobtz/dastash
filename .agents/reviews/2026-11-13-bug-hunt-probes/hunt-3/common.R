LIB <- "<W>/lib"
.libPaths(c(LIB, .libPaths()))
library(dazcache)
LP <- c(LIB, .libPaths())
tr <- function(expr) tryCatch(expr, condition = function(c) paste0("<", paste(class(c)[1:2], collapse="/"), "> ", conditionMessage(c)))
show <- function(label, x) { cat("==", label, ":\n"); print(x) }
files <- function(d) list.files(d, recursive = TRUE)
