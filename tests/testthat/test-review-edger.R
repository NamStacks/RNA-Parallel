# A DGEList call is read by edgeR's DGEList formals, where the second positional argument is `method`.

skip_if_not_installed("edgeR")

norm_counts <- function(G = 200L, S = 12L, seed = 11L) {
  set.seed(seed)
  lib <- round(exp(stats::rnorm(S, log(2e6), 0.3)))
  p <- 2^pmax(stats::rnorm(G, 3, 2), -1); p <- p / sum(p)
  cts <- matrix(stats::rnbinom(G * S, mu = outer(p, lib), size = 10), G, S)
  dimnames(cts) <- list(sprintf("g%04d", seq_len(G)), sprintf("s%02d", seq_len(S)))
  cts
}

spy_backend <- function() {
  n <- 0L
  list(backend = function(idx, f, workers) { n <<- n + 1L; lapply(idx, f) },
       count = function() n)
}

test_that("a positional method on a DGEList selects that method, as in edgeR", {
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  dge <- edgeR::DGEList(norm_counts())
  want <- c(TMMwsp = 1L, RLE = 1L, upperquartile = 1L)
  for (m in names(want)) {
    spy <- spy_backend()
    got <- calcNormFactors_parallel(dge, m, workers = 2L, chunks = 4L,
                                    parallel_backend = spy$backend)
    expect_identical(got, edgeR_norm(dge, m), info = m)
    expect_false(identical(got, edgeR_norm(dge)), info = m)
    expect_identical(spy$count(), want[[m]], info = m)
  }
  spy <- spy_backend()
  expect_identical(calcNormFactors_parallel(dge, "TMM", workers = 2L, chunks = 4L,
                                            parallel_backend = spy$backend),
                   edgeR_norm(dge, "TMM"))
  expect_identical(spy$count(), 2L)
})

test_that("positional arguments after the method follow edgeR's DGEList signature", {
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  dge <- edgeR::DGEList(norm_counts())
  spy <- spy_backend()
  got <- calcNormFactors_parallel(dge, "TMM", 3, workers = 2L, chunks = 4L,
                                  parallel_backend = spy$backend)
  expect_identical(got, edgeR_norm(dge, "TMM", 3))
  expect_false(identical(got, edgeR_norm(dge)))
  expect_identical(spy$count(), 1L)

  expect_identical(calcNormFactors_parallel(dge, "TMM", 3, 0.2, 0.1, workers = 2L),
                   edgeR_norm(dge, "TMM", 3, 0.2, 0.1))
})

test_that("a named, partial or dots-forwarded method still reaches a DGEList call", {
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  dge <- edgeR::DGEList(norm_counts())
  ref <- edgeR_norm(dge, "RLE")
  spy <- spy_backend()
  expect_identical(calcNormFactors_parallel(dge, method = "RLE", workers = 2L, chunks = 4L,
                                            parallel_backend = spy$backend), ref)
  expect_identical(spy$count(), 1L)
  expect_identical(calcNormFactors_parallel(dge, meth = "RLE", workers = 2L), ref)
  expect_identical(calcNormFactors_parallel(method = "RLE", object = dge, workers = 2L), ref)

  spy <- spy_backend()
  got <- lapply(list(dge), calcNormFactors_parallel, "RLE", workers = 2L, chunks = 4L,
                parallel_backend = spy$backend)
  expect_identical(got[[1L]], ref)
  expect_identical(spy$count(), 1L)
})

test_that("a named lib.size is ignored for a DGEList and stays the second argument of a matrix", {
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  cts <- norm_counts()
  dge <- edgeR::DGEList(cts)
  expect_identical(calcNormFactors_parallel(dge, lib.size = colSums(cts) * 2, workers = 2L),
                   edgeR_norm(dge))

  ls <- colSums(cts) * seq(0.8, 1.2, length.out = ncol(cts))
  spy <- spy_backend()
  got <- calcNormFactors_parallel(cts, ls, workers = 2L, chunks = 4L,
                                  parallel_backend = spy$backend)
  expect_identical(got, edgeR_norm(cts, ls))
  expect_false(identical(got, edgeR_norm(cts)))
  expect_identical(spy$count(), 2L)
})

test_that("the timing label names the method a positional argument selected", {
  skip_if_not_installed("SummarizedExperiment")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0,
                       combat.timing = TRUE, combat.timing.min = 0)
  cts <- norm_counts()
  dge <- edgeR::DGEList(cts)
  se <- SummarizedExperiment::SummarizedExperiment(assays = list(counts = cts))
  line <- function(expr) paste(testthat::capture_messages(suppressWarnings(expr)), collapse = "")
  for (x in list(dge, se)) {
    expect_match(line(calcNormFactors_parallel(x, "RLE", workers = 2L)),
                 "calcNormFactors RLE", fixed = TRUE)
    expect_match(line(calcNormFactors_parallel(x, "TMMwzp", workers = 2L)),
                 "calcNormFactors TMMwsp", fixed = TRUE)
    expect_match(line(calcNormFactors_parallel(x, method = "upperquartile", workers = 2L)),
                 "calcNormFactors upperquartile", fixed = TRUE)
    expect_match(line(calcNormFactors_parallel(x, workers = 2L)), "calcNormFactors TMM",
                 fixed = TRUE)
  }
  expect_match(line(calcNormFactors_parallel(cts, workers = 2L)), "calcNormFactors TMM",
               fixed = TRUE)
})

test_that("an RLE closure calling a helper from its own frame keeps that frame", {
  testthat::local_mocked_bindings(rp_copy_free = function(...) FALSE, .package = "rnaparallel")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  ns <- asNamespace("edgeR")
  e <- new.env(parent = ns)
  rle <- function(data) {
    gm <- exp(rowMeans(log(data)))
    med <- function(v) stats::median(v)
    apply(data, 2, function(u) med((u / gm)[gm > 0]))
  }
  environment(rle) <- e
  e$.calcFactorRLE <- rle
  be <- get(paste0(rnaparallel:::rp_edger_generic(), ".default"), envir = ns, inherits = FALSE)
  environment(be) <- e
  cts <- norm_counts()
  spy <- spy_backend()
  got <- calcNormFactors_parallel(cts, method = "RLE", workers = 2L, chunks = 4L,
                                  parallel_backend = spy$backend, backend = be)
  expect_identical(got, be(cts, method = "RLE"))
  expect_identical(spy$count(), 1L)
})
