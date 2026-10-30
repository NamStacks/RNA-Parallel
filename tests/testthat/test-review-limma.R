## Review fixes for the limma companions: the non-finite row split, the entry-point backend check
## in removeBatchEffect_parallel, the refusal wording and the help text.

skip_if_no_limma <- function() {
  testthat::skip_if_not_installed("limma")
  testthat::skip_if_not_installed("statmod")
}

na_fixture <- function(G = 120L, S = 12L, n_na = 10L, seed = 3L) {
  set.seed(seed)
  M <- matrix(stats::rnorm(G * S), G, S,
              dimnames = list(sprintf("g%03d", seq_len(G)), sprintf("s%02d", seq_len(S))))
  rows <- sort(sample(G, n_na))
  M[cbind(rows, sample(S, n_na, TRUE))] <- NA
  list(M = M, design = cbind(Intercept = 1, Group = rep(0:1, each = S / 2)), rows = rows,
       block = rep(seq_len(S / 2), each = 2L))
}

recording <- function() {
  seen <- list()
  list(backend = function(idx, f, workers) { seen[[length(seen) + 1L]] <<- idx; lapply(idx, f) },
       seen = function() seen)
}

## The suite zeroes every gate. This restores the least-squares one, so the matrix is under it
## and only the non-finite rescue can send the call to a worker.
local_ls_gate <- function(.env = parent.frame()) {
  withr::local_options(combat.min.ls.cells = 6e6, combat.min.cells = 0, combat.min.wt.genes = 0,
                       .local_envir = .env)
}

expect_chunks_hold_bad_row <- function(idx, M) {
  expect_true(all(vapply(idx, function(i) any(!is.finite(M[i, , drop = FALSE])), NA)))
  expect_true(all(lengths(idx) >= 2L))
  expect_identical(sort(unlist(idx)), seq_len(nrow(M)))
}

test_that("a matrix with several non-finite rows splits under the least-squares gate, identically", {
  skip_if_no_limma()
  local_ls_gate()
  for (cfg in list(c(10L, 2L), c(10L, 3L), c(10L, 5L), c(2L, 3L))) {
    d <- na_fixture(n_na = cfg[1L])
    spy <- recording()
    got <- lmFit_parallel(d$M, d$design, workers = 2L, chunks = cfg[2L],
                          parallel_backend = spy$backend)
    info <- paste("rows", cfg[1L], "chunks", cfg[2L])
    expect_identical(got, limma::lmFit(d$M, d$design), info = info)
    expect_length(spy$seen(), 1L)
    idx <- spy$seen()[[1L]]
    expect_length(idx, min(cfg))
    expect_chunks_hold_bad_row(idx, d$M)
  }
})

test_that("one non-finite row, or none, stays one plain original call", {
  skip_if_no_limma()
  local_ls_gate()
  d <- na_fixture(n_na = 1L)
  spy <- recording()
  expect_identical(lmFit_parallel(d$M, d$design, workers = 2L, chunks = 3L,
                                  parallel_backend = spy$backend),
                   limma::lmFit(d$M, d$design))
  expect_length(spy$seen(), 0L)

  clean <- na_fixture(n_na = 0L)
  spy <- recording()
  expect_identical(lmFit_parallel(clean$M, clean$design, workers = 2L, chunks = 3L,
                                  parallel_backend = spy$backend),
                   limma::lmFit(clean$M, clean$design))
  expect_length(spy$seen(), 0L)
})

test_that("the weighted gates still decide a non-finite matrix", {
  skip_if_no_limma()
  local_ls_gate()
  d <- na_fixture()
  spy <- recording()
  withr::with_options(list(combat.min.wt.genes = 1e6), {
    expect_identical(lmFit_parallel(d$M, d$design, workers = 2L, chunks = 3L,
                                    parallel_backend = spy$backend),
                     limma::lmFit(d$M, d$design))
  })
  withr::with_options(list(combat.min.cells = 1e9), {
    expect_identical(lmFit_parallel(d$M, d$design, workers = 2L, chunks = 3L,
                                    parallel_backend = spy$backend),
                     limma::lmFit(d$M, d$design))
  })
  expect_length(spy$seen(), 0L)
})

test_that("Inf cells, array weights and a blocked fit split the same way", {
  skip_if_no_limma()
  local_ls_gate()
  d <- na_fixture(n_na = 8L)
  Minf <- d$M
  Minf[cbind(c(3L, 40L, 77L), c(2L, 5L, 9L))] <- c(Inf, -Inf, Inf)
  spy <- recording()
  expect_identical(lmFit_parallel(Minf, d$design, workers = 2L, chunks = 3L,
                                  parallel_backend = spy$backend),
                   limma::lmFit(Minf, d$design))
  expect_length(spy$seen(), 1L)
  expect_chunks_hold_bad_row(spy$seen()[[1L]], Minf)

  aw <- seq(0.5, 2, length.out = ncol(d$M))
  spy <- recording()
  expect_identical(lmFit_parallel(d$M, d$design, weights = aw, workers = 2L, chunks = 3L,
                                  parallel_backend = spy$backend),
                   limma::lmFit(d$M, d$design, weights = aw))
  expect_length(spy$seen(), 1L)
  expect_chunks_hold_bad_row(spy$seen()[[1L]], d$M)

  spy <- recording()
  expect_identical(lmFit_parallel(d$M, d$design, block = d$block, correlation = 0.2,
                                  workers = 2L, chunks = 3L, parallel_backend = spy$backend),
                   limma::lmFit(d$M, d$design, block = d$block, correlation = 0.2))
  expect_length(spy$seen(), 1L)
  expect_chunks_hold_bad_row(spy$seen()[[1L]], d$M)
})

test_that("array weights that punch a cell still stand down", {
  skip_if_no_limma()
  local_ls_gate()
  d <- na_fixture(n_na = 8L)
  aw <- rep(1, ncol(d$M)); aw[3L] <- 0
  spy <- recording()
  expect_identical(lmFit_parallel(d$M, d$design, weights = aw, workers = 2L, chunks = 3L,
                                  parallel_backend = spy$backend),
                   limma::lmFit(d$M, d$design, weights = aw))
  expect_length(spy$seen(), 0L)
})

test_that("a stood-down lmFit says so in the timing line", {
  skip_if_no_limma()
  local_ls_gate()
  withr::local_options(combat.timing = TRUE, combat.timing.min = 0, combat.progress = FALSE)
  d <- na_fixture(n_na = 0L)
  msgs <- testthat::capture_messages(lmFit_parallel(d$M, d$design, workers = 2L))
  expect_match(paste(msgs, collapse = ""), "1 gated")
})

test_that("rp_nonfinite_rows reports cells, not overflowing sums", {
  M <- matrix(c(1, 2, 3, 4,
                1e308, 1e308, 1e308, 1e308,
                1, NA, 3, 4,
                1, Inf, 3, 4), 4, 4, byrow = TRUE)
  expect_identical(rnaparallel:::rp_nonfinite_rows(M, NULL, "lm"), c(3L, 4L))
  expect_identical(rnaparallel:::rp_nonfinite_rows(M[1:2, ], NULL, "lm"), integer())
  expect_identical(rnaparallel:::rp_nonfinite_rows(M, c(1, 1, 0, 1), "lm"), integer())
  expect_identical(rnaparallel:::rp_nonfinite_rows(M, c(1, 1, 1e-20, 1), "lm"), c(3L, 4L))
  expect_identical(rnaparallel:::rp_nonfinite_rows(M, c(1, 1, 1e-20, 1), "gls"), integer())
})

test_that("rp_nonfinite_chunks gives every chunk a non-finite row and two or more rows", {
  ch <- rnaparallel:::rp_nonfinite_chunks
  bad <- c(2L, 5L, 9L)
  for (k in 2:5) {
    idx <- ch(12L, bad, workers = k, chunks = NULL, ncol = 8L)
    expect_true(length(idx) >= 2L && length(idx) <= 3L)
    expect_true(all(vapply(idx, function(i) any(i %in% bad), NA)))
    expect_true(all(lengths(idx) >= 2L))
    expect_identical(sort(unlist(idx)), 1:12)
  }
  expect_null(ch(12L, 4L, workers = 4L, chunks = NULL, ncol = 8L))
  expect_null(ch(12L, integer(), workers = 4L, chunks = NULL, ncol = 8L))
  expect_null(ch(3L, 1:3, workers = 4L, chunks = NULL, ncol = 8L))
  expect_length(ch(4L, 1:4, workers = 4L, chunks = NULL, ncol = 8L), 2L)
})

test_that("removeBatchEffect_parallel checks parallel_backend before limma runs", {
  skip_if_no_limma()
  set.seed(2)
  y <- matrix(stats::rnorm(100), 10, 10)
  expect_error(removeBatchEffect_parallel(y, parallel_backend = "typo"), "should be one of")
  msgs <- character()
  err <- withCallingHandlers(
    tryCatch(removeBatchEffect_parallel(y, batch = rep(1:2, 5), parallel_backend = "typo"),
             error = function(e) e),
    message = function(m) { msgs <<- c(msgs, conditionMessage(m)); invokeRestart("muffleMessage") })
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "should be one of")
  expect_length(msgs, 0L)
  suppressMessages(expect_identical(
    removeBatchEffect_parallel(y, batch = rep(1:2, 5), design = matrix(1, 10, 1),
                               parallel_backend = "serial"),
    limma::removeBatchEffect(y, batch = rep(1:2, 5), design = matrix(1, 10, 1))))
})

test_that("refusals name the original limma function for the caller's own entry point", {
  skip_if_no_limma()
  d <- na_fixture(n_na = 0L)
  b <- rep(1:2, 6)
  msg <- function(expr) tryCatch({ expr; "" }, error = conditionMessage)
  m1 <- msg(removeBatchEffect_parallel(d$M, batch = b, method = "robust", workers = 2L))
  expect_match(m1, "robust")
  expect_match(m1, "limma::removeBatchEffect", fixed = TRUE)
  m2 <- msg(lmFit_parallel(d$M, d$design, ndups = 2L, workers = 2L))
  expect_match(m2, "unwrapdups")
  expect_match(m2, "limma::lmFit", fixed = TRUE)
  m3 <- msg(lmFit_parallel(d$M, d$design, method = "robust", workers = 2L))
  expect_match(m3, "mrlm")
  expect_match(m3, "limma::lmFit", fixed = TRUE)
})

test_that("help text and file headers say what the code does", {
  root <- testthat::test_path("..", "..", "R")
  skip_if_not(dir.exists(root), "package sources are not present")
  lm_src <- readLines(file.path(root, "limma_lmFit_parallel.R"))
  dc_src <- readLines(file.path(root, "limma_dupcor_parallel.R"))
  rox <- grep("^#'", lm_src, value = TRUE)
  expect_false(any(grepl('\\"', rox, fixed = TRUE)))
  expect_false(any(grepl("refusals above", rox, fixed = TRUE)))
  expect_false(any(grepl("19.25%", rox, fixed = TRUE)))
  for (src in list(lm_src, dc_src)) {
    expect_match(paste(src[1:6], collapse = " "), "verbose.R", fixed = TRUE)
    expect_match(paste(grep("^#'", src, value = TRUE), collapse = " "),
                 "performance-core count", fixed = TRUE)
  }
})

test_that("the source-only recipe in the file headers runs in a clean session", {
  skip_if_no_limma()
  skip_on_cran()
  root <- testthat::test_path("..", "..", "R")
  skip_if_not(dir.exists(root), "package sources are not present")
  files <- c("verbose.R", "helper_seq_parallel.R", "helper_limma_parallel.R",
             "limma_lmFit_parallel.R", "limma_dupcor_parallel.R")
  code <- c(
    sprintf("for (f in %s) source(file.path(%s, f))", paste(deparse(files), collapse = ""),
            deparse(normalizePath(root))),
    "stopifnot(!('rnaparallel' %in% loadedNamespaces()))",
    "options(combat.min.cells = 0, combat.min.wt.genes = 0, combat.min.ls.cells = 0, combat.min.dupcor.cells = 0, combat.mem.guard = FALSE, combat.progress = FALSE)",
    "set.seed(1); y <- matrix(rnorm(240), 20, 12); d <- cbind(1, rep(0:1, each = 6))",
    "stopifnot(identical(lmFit_parallel(y, d, workers = 2L), limma::lmFit(y, d)))",
    "blk <- rep(1:6, each = 2)",
    "stopifnot(identical(duplicateCorrelation_parallel(y, d, block = blk, workers = 2L), limma::duplicateCorrelation(y, d, block = blk)))",
    "cat('RECIPE_OK\\n')")
  f <- tempfile(fileext = ".R"); on.exit(unlink(f), add = TRUE)
  writeLines(code, f)
  out <- suppressWarnings(system2(file.path(R.home("bin"), "Rscript"),
                                  c("--no-save", "--no-restore", "--no-init-file", shQuote(f)),
                                  stdout = TRUE, stderr = TRUE))
  expect_true(any(grepl("RECIPE_OK", out, fixed = TRUE)), info = paste(out, collapse = "\n"))
})
