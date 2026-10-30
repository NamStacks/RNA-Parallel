# Cross-file review fixes: SummarizedExperiment input, per-chunk payloads on serializing backends,
# the shared prologue's `chunks` check.

skip_if_not_installed("edgeR")

xf_counts <- function(G = 300L, S = 12L, seed = 21L) {
  set.seed(seed)
  lib <- round(exp(stats::rnorm(S, log(2e6), 0.3)))
  p <- 2^pmax(stats::rnorm(G, 3, 2), -1); p <- p / sum(p)
  cts <- matrix(stats::rnbinom(G * S, mu = outer(p, lib), size = 10), G, S)
  dimnames(cts) <- list(sprintf("g%04d", seq_len(G)), sprintf("s%02d", seq_len(S)))
  cts
}

xf_copy_free <- function(value) {
  f <- if (value) function(...) TRUE else function(...) FALSE
  environment(f) <- asNamespace("rnaparallel")
  f
}

xf_nosrc <- function(e) if (inherits(e, "srcfile")) "srcfile" else NULL

xf_spy <- function() {
  n <- 0L; bytes <- numeric(); fbytes <- numeric()
  list(backend = function(idx, f, workers) {
         n <<- n + 1L
         fbytes[length(fbytes) + 1L] <<- length(serialize(f, NULL, refhook = xf_nosrc))
         lapply(idx, function(i) { bytes[length(bytes) + 1L] <<- length(serialize(i, NULL)); f(i) })
       },
       count = function() n, bytes = function() bytes, fbytes = function() fbytes)
}

test_that("SummarizedExperiment input reaches the parallel dispatch and is identical to edgeR", {
  skip_if_not_installed("SummarizedExperiment")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  cts <- xf_counts()
  se <- SummarizedExperiment::SummarizedExperiment(assays = list(counts = cts))
  for (m in c("TMM", "TMMwsp", "RLE", "upperquartile")) {
    spy <- xf_spy()
    got <- calcNormFactors_parallel(se, method = m, workers = 2L, parallel_backend = spy$backend)
    expect_identical(got, edgeR_norm(se, method = m), info = m)
    expect_true(spy$count() >= 1L, info = m)
    expect_s4_class(got, "DGEList")
  }
})

test_that("a SummarizedExperiment above the default dispatch gate dispatches and is identical to edgeR", {
  skip_if_not_installed("SummarizedExperiment")
  skip_on_cran()
  withr::local_options(combat.min.norm.cells = NULL, combat.min.order.cells = NULL)
  spy <- xf_spy()
# The unset gate is 2e5 cells where a worker inherits the matrix and 2e6 where it is copied, so the matrix is sized from the gate this backend resolves.
  gate <- rnaparallel:::rp_norm_min_cells(spy$backend)
  cts <- xf_counts(G = max(6000L, as.integer(ceiling(gate / 40L)) + 1L), S = 40L)
  expect_gte(length(cts), gate)
  se <- SummarizedExperiment::SummarizedExperiment(assays = list(counts = cts))
  expect_identical(calcNormFactors_parallel(se, workers = 2L, parallel_backend = spy$backend),
                   edgeR_norm(se))
  expect_gte(spy$count(), 1L)
  expect_identical(calcNormFactors_parallel(se, workers = 2L), edgeR_norm(se))
  small <- SummarizedExperiment::SummarizedExperiment(assays = list(counts = xf_counts()))
  spy0 <- xf_spy()
  expect_identical(calcNormFactors_parallel(small, workers = 2L, parallel_backend = spy0$backend),
                   edgeR_norm(small))
  expect_identical(spy0$count(), 0L)
})

test_that("an SE method that stops calling the generic as a bare symbol is refused", {
  skip_if_not_installed("SummarizedExperiment")
  ns <- asNamespace("edgeR")
  generic <- rnaparallel:::rp_edger_generic()
  nm <- paste0(generic, ".SummarizedExperiment")
  skip_if(!exists(nm, envir = ns, inherits = FALSE), "no SummarizedExperiment method to gate")
  orig <- get(nm, envir = ns, inherits = FALSE)
  txt <- paste(deparse(body(orig)), collapse = "\n")
  skip_if(!grepl(paste0("\\b", generic, "\\("), txt), "original body is not shaped as expected")
  drifted <- orig
  body(drifted) <- parse(text = sub(paste0("(?<![.:\\w])", generic, "\\("),
                                    paste0("edgeR::", generic, "("), txt, perl = TRUE))[[1L]]
  withr::defer({ assign(nm, orig, envir = ns); lockBinding(nm, ns) })
  unlockBinding(nm, ns); assign(nm, drifted, envir = ns)
  se <- SummarizedExperiment::SummarizedExperiment(assays = list(counts = xf_counts()))
  expect_error(calcNormFactors_parallel(se, workers = 2L), "no longer calls")
})

test_that("a serializing backend ships each chunk its own columns and stays identical", {
  testthat::local_mocked_bindings(rp_copy_free = xf_copy_free(FALSE), .package = "rnaparallel")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  cts <- xf_counts(G = 2000L, S = 16L)
  whole <- length(serialize(cts, NULL))
  for (m in c("TMM", "TMMwsp", "RLE", "upperquartile")) {
    spy <- xf_spy()
    got <- calcNormFactors_parallel(cts, method = m, workers = 4L, chunks = 4L,
                                    parallel_backend = spy$backend)
    expect_identical(got, edgeR_norm(cts, method = m), info = m)
    expect_gte(spy$count(), 1L)
    expect_lt(max(spy$bytes()), 0.6 * whole, label = paste(m, "task bytes"))
    expect_gt(max(spy$bytes()), 0.1 * whole, label = paste(m, "task bytes"))
    expect_gt(sum(spy$bytes()), 0.5 * whole, label = paste(m, "total task bytes"))
    expect_lt(max(spy$fbytes()), 0.6 * whole, label = paste(m, "closure bytes"))
  }
})

test_that("a copy-free backend keeps the whole-matrix closure and stays identical", {
  testthat::local_mocked_bindings(rp_copy_free = xf_copy_free(TRUE), .package = "rnaparallel")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  cts <- xf_counts(G = 2000L, S = 16L)
  whole <- length(serialize(cts, NULL))
  spy <- xf_spy()
  got <- calcNormFactors_parallel(cts, workers = 4L, chunks = 4L, parallel_backend = spy$backend)
  expect_identical(got, edgeR_norm(cts))
  expect_lt(max(spy$bytes()), 0.01 * whole)
  expect_gt(max(spy$fbytes()), 0.9 * whole)
})

test_that("slices are built only for a dispatch that leaves this process", {
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  cts <- xf_counts(G = 2000L, S = 16L)
  orig <- rnaparallel:::rp_norm_cols
  sliced <- logical()
  testthat::local_mocked_bindings(
    rp_norm_cols = function(ncols, cells, f, workers, chunks, parallel_backend, min_cells,
                            what, slice = NULL) {
      sliced[length(sliced) + 1L] <<- !is.null(slice)
      orig(ncols, cells, f, workers, chunks, parallel_backend, min_cells, what, slice)
    }, .package = "rnaparallel")

  testthat::local_mocked_bindings(rp_copy_free = xf_copy_free(FALSE), .package = "rnaparallel")
  spy <- xf_spy()
  calcNormFactors_parallel(cts, workers = 4L, chunks = 4L, parallel_backend = spy$backend)
  expect_true(length(sliced) >= 1L && all(sliced))

  sliced <- logical()
  old <- future::plan(future::sequential)
  withr::defer(future::plan(old))
  got <- suppressWarnings(calcNormFactors_parallel(cts, workers = 4L, chunks = 4L,
                                                   parallel_backend = "future"))
  expect_identical(got, edgeR_norm(cts))
  expect_true(length(sliced) >= 1L && !any(sliced))
  expect_false(rnaparallel:::rp_ship_slices("future", 4L, 1e7, 2e6))

  sliced <- logical()
  withr::local_envvar(RNAPARALLEL_IN_WORKER = "1")
  spy <- xf_spy()
  calcNormFactors_parallel(cts, workers = 4L, chunks = 4L, parallel_backend = spy$backend)
  expect_true(length(sliced) >= 1L && !any(sliced))
})

test_that("a socket plan with workers still ships slices", {
  skip_on_cran()
  skip_if_not_installed("future.apply")
  local_socket_plan(2L)
  expect_true(rnaparallel:::rp_ship_slices("future", 4L, 1e7, 2e6))
})

test_that("combat_parallel_lapply hands a payload to f and still checks idx", {
  idx <- list(1:2, 3:5)
  seen <- NULL
  f <- function(p) { seen[[length(seen) + 1L]] <<- p; length(p$v) }
  got <- rnaparallel:::combat_parallel_lapply(
    idx, f, 2L, parallel_backend = function(idx, f, workers) lapply(idx, f),
    payload = list(list(v = 1:2), list(v = 3:5)))
  expect_identical(unlist(got), c(2L, 3L))
  expect_error(rnaparallel:::combat_parallel_lapply(idx, f, 2L, payload = list(1)),
               "one element per chunk")
})

test_that("a fractional or vector `chunks` is refused at the door by every entry point", {
  skip_if_not_installed("limma")
  cts <- xf_counts()
  expect_error(calcNormFactors_parallel(cts, workers = 2L, chunks = 1:2), "single number")
  expect_error(calcNormFactors_parallel(cts, workers = 2.5), "whole number")
  y <- log2(cts + 1)
  d <- stats::model.matrix(~ rep(c("a", "b"), each = ncol(cts) / 2))
  expect_error(lmFit_parallel(y, d, workers = 2L, chunks = 1:2), "single number")
  expect_error(removeBatchEffect_parallel(y, batch = rep(1:2, each = ncol(cts) / 2),
                                          workers = 2L, chunks = 1:2), "single number")
  expect_error(duplicateCorrelation_parallel(y, d, block = rep(1:6, each = 2),
                                             workers = 2L, chunks = 1:2), "single number")
})
