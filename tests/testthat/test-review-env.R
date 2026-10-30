# Identical chunk failures say environment only on environment evidence; a shared data or argument fault keeps its own text.

skip_on_os("windows")

lazy_text <- "lazy-load database '/lib/rnaparallel/R/rnaparallel.rdb' is corrupt"

dispatch_error <- function(f, backend = "mclapply", n = 6L) {
  idx <- lapply(seq_len(n), function(i) i)
  tryCatch(
    combat_parallel_check(combat_parallel_lapply(idx, f, 2L, backend), "stage x", idx),
    error = function(e) e)
}

test_that("a data fault shared by every chunk is not reported as an environment fault", {
  e <- dispatch_error(function(ii) stop("no data rows with required number of counts"))
  expect_s3_class(e, "rnaparallel_dispatch_error")
  expect_false(grepl("environment", conditionMessage(e), fixed = TRUE))
  expect_match(conditionMessage(e), "all 6 chunk(s) failed with the identical error",
               fixed = TRUE)
  expect_match(conditionMessage(e), "no data rows with required number of counts",
               fixed = TRUE)
  expect_s3_class(e$cause, "simpleError")
  expect_identical(conditionMessage(e$cause), "no data rows with required number of counts")
  expect_identical(e$n_errored, 6L)
})

test_that("identical lazy-load failures still point at the environment and say to restart", {
  e <- dispatch_error(function(ii) stop(lazy_text))
  expect_s3_class(e, "rnaparallel_dispatch_error")
  expect_match(conditionMessage(e), "points at the environment rather than the data",
               fixed = TRUE)
  expect_match(conditionMessage(e), "Restart R", fixed = TRUE)
  expect_match(conditionMessage(e), "lazy-load database", fixed = TRUE)
  expect_s3_class(e$cause, "error")
})

test_that("a missing function is read as an environment fault", {
  e <- dispatch_error(function(ii) stop("could not find function \"rp_not_there\""))
  expect_match(conditionMessage(e), "points at the environment rather than the data",
               fixed = TRUE)
})

test_that("a stale install is read as an environment fault whatever the chunks said", {
  testthat::local_mocked_bindings(rnaparallel_stale = function() TRUE)
  e <- dispatch_error(function(ii) stop("plain data error"))
  expect_match(conditionMessage(e), "points at the environment rather than the data",
               fixed = TRUE)
  expect_match(conditionMessage(e), "Restart R", fixed = TRUE)
})

test_that("a stale check that cannot run counts as stale", {
  testthat::local_mocked_bindings(
    rnaparallel_stale = function() stop("could not find function \"rnaparallel_stale\""))
  e <- dispatch_error(function(ii) stop("plain data error"))
  expect_match(conditionMessage(e), "points at the environment rather than the data",
               fixed = TRUE)
})

test_that("identical failures that name no environment evidence stay neutral", {
  diag <- rnaparallel:::rp_dispatch_diagnosis
  for (txt in c("cannot allocate vector of size 2.1 Gb", "object 'x' not found",
                "no data rows with required number of counts")) {
    expect_identical(diag(rep(txt, 4L), 4L),
                     sprintf("all 4 chunk(s) failed with the identical error: %s", txt), info = txt)
  }
})

test_that("a missing package shared by every chunk is read as an environment fault", {
  for (txt in c("there is no package called 'edgeR'", "package 'rnaparallel' is not installed")) {
    expect_match(diag <- rnaparallel:::rp_dispatch_diagnosis(rep(txt, 3L), 3L),
                 "points at the environment rather than the data", fixed = TRUE)
    expect_match(diag, txt, fixed = TRUE)
  }
})

test_that("chunks that fail differently, or one chunk alone, keep the plain wording", {
  e <- dispatch_error(function(ii) stop("bad ", ii))
  expect_match(conditionMessage(e), "6 chunk(s) raised an error, first was: bad 1", fixed = TRUE)
  expect_false(grepl("environment", conditionMessage(e), fixed = TRUE))
  e1 <- dispatch_error(function(ii) if (ii == 3L) stop("only three") else ii)
  expect_match(conditionMessage(e1), "1 chunk(s) raised an error, first was: only three",
               fixed = TRUE)
})

test_that("warnings and messages a chunk raised before it failed reach the master", {
  f <- function(ii) { message("Note: before the error ", ii); stop("boom") }
  expect_message(dispatch_error(f), "Note: before the error 1")
  expect_message(dispatch_error(f), "Note: before the error 4")
})

test_that("future and BiocParallel failures carry the dispatch class and keep their own text", {
  skip_if_not_installed("future.apply")
  withr::local_options(rnaparallel.verbose = FALSE)
  old <- future::plan(future::sequential)
  withr::defer(future::plan(old))
  e <- suppressWarnings(dispatch_error(function(ii) stop("boom"), backend = "future"))
  expect_s3_class(e, "rnaparallel_dispatch_error")
  expect_s3_class(e, "simpleError")
  expect_identical(conditionMessage(e), "boom")
  expect_s3_class(e$cause, "simpleError")

  skip_if_not_installed("BiocParallel")
  b <- dispatch_error(function(ii) stop("boom"), backend = "BiocParallel")
  expect_s3_class(b, "rnaparallel_dispatch_error")
  expect_s3_class(b, "bperror")
  expect_match(conditionMessage(b), "boom", fixed = TRUE)
  expect_false(inherits(b$cause, "bplist_error"))
  expect_match(conditionMessage(b$cause), "boom", fixed = TRUE)
  expect_identical(b$n_errored, 6L)
})

held_chunk <- function(ii) {
  h <- rp_hold({
    warning("Warn: before the error ", ii)
    message("Note: before the error ", ii)
    stop("boom")
  })
  h$value
}

held_run <- function(backend, workers = 2L, n = 6L) {
  idx <- lapply(seq_len(n), function(i) i)
  warns <- msgs <- character()
  err <- withCallingHandlers(
    tryCatch(combat_parallel_check(combat_parallel_lapply(idx, held_chunk, workers, backend),
                                   "stage x", idx), error = function(e) e),
    warning = function(w) { warns <<- c(warns, conditionMessage(w)); invokeRestart("muffleWarning") },
    message = function(m) { msgs <<- c(msgs, conditionMessage(m)); invokeRestart("muffleMessage") })
  list(err = err, warns = warns, msgs = msgs)
}

test_that("a failing chunk's held conditions reach the master on every forking backend", {
  skip_if_not_installed("BiocParallel")
  skip_if_not_installed("future.apply")
  skip_if_not_installed("doParallel")
  withr::local_options(rnaparallel.verbose = FALSE)
  old <- future::plan(future::sequential)
  withr::defer(future::plan(old))
  for (be in c("mclapply", "foreach", "future", "BiocParallel")) {
    r <- suppressWarnings(held_run(be))
    expect_s3_class(r$err, "rnaparallel_dispatch_error")
    expect_true("Note: before the error 1\n" %in% r$msgs, info = be)
    expect_true("Warn: before the error 1" %in% r$warns, info = be)
  }
})

test_that("a failing chunk's held conditions reach the master when the dispatch runs in this process", {
  runs <- list(
    serial = quote(held_run("serial")),
    one_worker = quote(held_run("mclapply", workers = 1L)),
    no_fork = quote({ withr::local_options(combat.fork = FALSE); held_run("mclapply") }),
    nested_worker = quote({ withr::local_envvar(RNAPARALLEL_IN_WORKER = "1"); held_run("mclapply") }))
  for (nm in names(runs)) {
    r <- eval(runs[[nm]])
    expect_s3_class(r$err, "error")
    expect_identical(conditionMessage(r$err), "boom", info = nm)
    expect_identical(r$msgs, "Note: before the error 1\n", info = nm)
    expect_identical(r$warns, "Warn: before the error 1", info = nm)
  }
})

test_that("an in-process failure keeps the failing frames and raises each held condition once", {
  inner <- function() stop("deep")
  chunk <- function(ii) rp_hold({ message("Note: once"); inner() })$value
  seen <- NULL
  msgs <- character()
  e <- tryCatch(
    withCallingHandlers(
      combat_parallel_lapply(list(1L, 2L), chunk, 2L, "serial"),
      error = function(e) seen <<- vapply(sys.calls(), function(cl) deparse(cl[[1L]])[1L], ""),
      message = function(m) { msgs <<- c(msgs, conditionMessage(m)); invokeRestart("muffleMessage") }),
    error = function(e) e)
  expect_identical(conditionMessage(e), "deep")
  expect_true("inner" %in% seen)
  expect_identical(msgs, "Note: once\n")
  expect_null(e$rp_held)
})

test_that("a lazy-load failure on the future backend gets the restart advice", {
  skip_if_not_installed("future.apply")
  old <- future::plan(future::sequential)
  withr::defer(future::plan(old))
  e <- suppressWarnings(dispatch_error(function(ii) stop(lazy_text), backend = "future"))
  expect_s3_class(e, "rnaparallel_dispatch_error")
  expect_match(conditionMessage(e), lazy_text, fixed = TRUE)
  expect_match(conditionMessage(e), "Restart R", fixed = TRUE)
})

test_that("ComBat-seq on data edgeR cannot fit does not blame the environment", {
  skip_if_not_installed("sva")
  withr::local_options(combat.min.batch.cells = 0, combat.min.cells = 0)
  set.seed(11)
  cts <- matrix(rbinom(200 * 12, 1, 0.5), nrow = 200)
  bat <- rep(1:3, each = 4L)
  ref <- tryCatch(quietly(sva::ComBat_seq(cts, batch = bat, group = NULL)),
                  error = function(e) e)
  skip_if(!inherits(ref, "error"), "this edgeR/sva version fits the 0/1 matrix")
  e <- tryCatch(quietly(ComBat_seq_parallel(cts, batch = bat, group = NULL, workers = 2L,
                                            parallel_backend = "mclapply")),
                error = function(e) e)
  expect_s3_class(e, "rnaparallel_dispatch_error")
  expect_false(grepl("environment", conditionMessage(e), fixed = TRUE))
  expect_match(conditionMessage(e), conditionMessage(ref), fixed = TRUE)
  expect_identical(conditionMessage(e$cause), conditionMessage(ref))
})

test_that("calcNormFactors_parallel with a bad argument does not blame the environment", {
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0,
                       combat.min.cells = 0)
  set.seed(12)
  cts <- matrix(rnbinom(300 * 30, mu = 50, size = 5), nrow = 300)
  ref <- tryCatch(edgeR::normLibSizes(cts, method = "upperquartile", p = 2),
                  error = function(e) e)
  expect_s3_class(ref, "error")
  e <- tryCatch(suppressWarnings(
    calcNormFactors_parallel(cts, method = "upperquartile", p = 2, workers = 3L)),
    error = function(e) e)
  expect_s3_class(e, "rnaparallel_dispatch_error")
  expect_false(grepl("environment", conditionMessage(e), fixed = TRUE))
  expect_match(conditionMessage(e), conditionMessage(ref), fixed = TRUE)
  expect_no_warning(tryCatch(calcNormFactors_parallel(cts, method = "upperquartile", p = 2,
                                                      workers = 3L), error = function(e) NULL),
                    message = "function calls resulted in an error")
})

test_that("lmFit_parallel with an invalid correlation does not blame the environment", {
  withr::local_options(combat.min.cells = 0, combat.min.ls.cells = 0, combat.min.wt.genes = 0)
  set.seed(13)
  y <- matrix(rnorm(400 * 8), nrow = 400)
  design <- cbind(1, rep(0:1, 4L))
  blk <- rep(1:4, each = 2L)
  ref <- tryCatch(limma::lmFit(y, design, block = blk, correlation = 1), error = function(e) e)
  expect_s3_class(ref, "error")
  e <- tryCatch(lmFit_parallel(y, design, block = blk, correlation = 1, workers = 3L),
                error = function(e) e)
  expect_s3_class(e, "rnaparallel_dispatch_error")
  expect_false(grepl("environment", conditionMessage(e), fixed = TRUE))
  expect_match(conditionMessage(e), conditionMessage(ref), fixed = TRUE)
  expect_identical(conditionMessage(e$cause), conditionMessage(ref))
})

test_that("duplicateCorrelation_parallel keeps limma's note and does not blame the environment", {
  withr::local_options(combat.min.dupcor.cells = 0, combat.min.cells = 0)
  set.seed(14)
  y <- matrix(rnorm(300 * 12), nrow = 300)
  grp <- rep(c("a", "b"), each = 6L)
  design <- cbind(model.matrix(~ grp), dup = model.matrix(~ grp)[, 2L])
  blk <- rep(1L, 12L)

  note <- NULL
  ref <- withCallingHandlers(
    tryCatch(limma::duplicateCorrelation(y, design, block = blk), error = function(e) e),
    message = function(m) { note <<- conditionMessage(m); invokeRestart("muffleMessage") })
  expect_s3_class(ref, "error")
  skip_if(is.null(note), "limma raised no rank note for this design")

  got <- NULL
  e <- withCallingHandlers(
    tryCatch(duplicateCorrelation_parallel(y, design, block = blk, workers = 3L),
             error = function(e) e),
    message = function(m) { got <<- c(got, conditionMessage(m)); invokeRestart("muffleMessage") })
  expect_s3_class(e, "rnaparallel_dispatch_error")
  expect_false(grepl("environment", conditionMessage(e), fixed = TRUE))
  expect_match(conditionMessage(e), conditionMessage(ref), fixed = TRUE)
  expect_true(note %in% got)
  expect_identical(sum(got == note), 1L)
})
