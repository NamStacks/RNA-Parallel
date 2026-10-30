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

test_that("an RLE closure calling a helper held above its frame keeps that environment", {
  testthat::local_mocked_bindings(rp_copy_free = function(...) FALSE, .package = "rnaparallel")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  ns <- asNamespace("edgeR")
  e <- new.env(parent = ns)
  e$med <- function(v) stats::median(v)
  rle <- function(data) {
    gm <- exp(rowMeans(log(data)))
    apply(data, 2, function(u) med((u / gm)[gm > 0]))
  }
  environment(rle) <- e
  e$.calcFactorRLE <- rle
  be <- get(paste0(rnaparallel:::rp_edger_generic(), ".default"), envir = ns, inherits = FALSE)
  environment(be) <- e
  cts <- norm_counts()
  got <- calcNormFactors_parallel(cts, method = "RLE", workers = 2L, chunks = 4L,
                                  parallel_backend = "mclapply", backend = be)
  expect_identical(got, be(cts, method = "RLE"))
  skip_on_os("windows")
  skip_if_not_installed("doParallel")
  got <- calcNormFactors_parallel(cts, method = "RLE", workers = 2L, chunks = 4L,
                                  parallel_backend = "foreach", backend = be)
  expect_identical(got, be(cts, method = "RLE"))
})

test_that("a one-chunk dispatch does not slice a payload copy", {
  testthat::local_mocked_bindings(rp_copy_free = function(...) FALSE, .package = "rnaparallel")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  orig <- rnaparallel:::combat_parallel_lapply
  nulls <- logical()
  testthat::local_mocked_bindings(
    combat_parallel_lapply = function(idx, f, workers, ..., payload = NULL) {
      nulls[length(nulls) + 1L] <<- is.null(payload)
      orig(idx, f, workers, ..., payload = payload)
    }, .package = "rnaparallel")
  cts <- norm_counts()
  inproc <- function(idx, f, workers) lapply(idx, f)
  for (m in c("RLE", "TMM")) {
    nulls <- logical()
    got <- calcNormFactors_parallel(cts, method = m, workers = 2L, chunks = 1L,
                                    parallel_backend = inproc)
    expect_identical(got, edgeR_norm(cts, method = m))
    expect_gt(length(nulls), 0L)
    expect_true(all(nulls), info = m)
    nulls <- logical()
    calcNormFactors_parallel(cts, method = m, workers = 2L, chunks = 4L,
                             parallel_backend = inproc)
    expect_false(all(nulls), info = m)
  }
})


# ---- environments above the RLE closure's frame, on a real socket pool ---------------

local_psock_foreach <- function(.env = parent.frame()) {
  skip_on_cran()
  skip_if_not_installed("doParallel")
  cl <- parallel::makeCluster(2L, type = "PSOCK")
  withr::defer({
    foreach::registerDoSEQ()
    try(parallel::stopCluster(cl), silent = TRUE)
  }, envir = .env)
  rp_cluster_load(cl)
  doParallel::registerDoParallel(cl)
  invisible(cl)
}

rle_backend <- function(e, per_col) {
  rle <- eval(bquote(function(data) {
    gm <- exp(rowMeans(log(data)))
    apply(data, 2, function(u) .(per_col))
  }))
  environment(rle) <- e
  e$.calcFactorRLE <- rle
  be <- get(paste0(rnaparallel:::rp_edger_generic(), ".default"), envir = asNamespace("edgeR"),
            inherits = FALSE)
  environment(be) <- e
  be
}

expect_psock_identical <- function(be, info) {
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  cts <- norm_counts(G = 400L)
  want <- be(cts, method = "RLE")
  for (pb in c("mclapply", "foreach")) {
    got <- calcNormFactors_parallel(cts, method = "RLE", workers = 2L, chunks = 4L,
                                    parallel_backend = pb, backend = be)
    expect_identical(got, want, info = paste(info, pb))
  }
  invisible(want)
}

test_that("an S3 method held in the backend's environment reaches a socket worker", {
  local_psock_foreach()
  e <- new.env(parent = asNamespace("edgeR"))
  e$median.numeric <- function(x, na.rm = FALSE, ...) stats::quantile(x, 0.5, type = 1, names = FALSE)
  be <- rle_backend(e, quote(median((u / gm)[gm > 0])))
  want <- expect_psock_identical(be, "S3")
  expect_false(identical(want, edgeR_norm(norm_counts(G = 400L), method = "RLE")))
})

test_that("a helper reached by do.call on its name reaches a socket worker", {
  local_psock_foreach()
  e <- new.env(parent = asNamespace("edgeR"))
  e$med <- function(v) stats::median(v)
  be <- rle_backend(e, quote(do.call("med", list((u / gm)[gm > 0]))))
  expect_psock_identical(be, "do.call")
})

test_that("a promise in the backend's environment is neither forced nor shipped", {
  local_psock_foreach()
  e <- new.env(parent = asNamespace("edgeR"))
  delayedAssign("tmpv", stop("never read"), eval.env = baseenv(), assign.env = e)
  be <- rle_backend(e, quote({ tmpv <- median((u / gm)[gm > 0]); tmpv }))
  expect_psock_identical(be, "promise")
})

test_that("a non-function binding nearer the frame does not hide a farther function", {
  local_psock_foreach()
  far <- new.env(parent = asNamespace("edgeR"))
  far$sd <- function(v) stats::median(v)
  near <- new.env(parent = far)
  near$sd <- 5
  be <- rle_backend(near, quote(sd((u / gm)[gm > 0])))
  expect_psock_identical(be, "shadow")
})


test_that("a frame local reached by S3 dispatch, a string or a nested default keeps the frame", {
  testthat::local_mocked_bindings(rp_copy_free = function(...) FALSE, .package = "rnaparallel")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  inproc <- function(idx, f, workers) lapply(idx, f)
  cts <- norm_counts(G = 401L)
  mk <- function(setup, call) {
    e <- new.env(parent = asNamespace("edgeR"))
    rle <- eval(bquote(function(data) {
      gm <- exp(rowMeans(log(data)))
      .(setup)
      apply(data, 2, function(u) .(call))
    }))
    environment(rle) <- e
    e$.calcFactorRLE <- rle
    be <- get(paste0(rnaparallel:::rp_edger_generic(), ".default"),
              envir = asNamespace("edgeR"), inherits = FALSE)
    environment(be) <- e
    be
  }
  cases <- list(
    s3 = mk(quote(median.numeric <- function(x, na.rm = FALSE, ...)
              stats::quantile(x, 0.4, type = 1, names = FALSE)),
            quote(median((u / gm)[gm > 0]))),
    nested = mk(quote(kk <- 0.4),
                quote({ q <- function(v, k = kk) stats::quantile(v, k, type = 1, names = FALSE)
                        q((u / gm)[gm > 0]) })),
    string = mk(quote(medf <- function(v) stats::quantile(v, 0.4, type = 1, names = FALSE)),
                quote(do.call("medf", list((u / gm)[gm > 0])))))
  for (nm in names(cases)) {
    be <- cases[[nm]]
    got <- calcNormFactors_parallel(cts, method = "RLE", workers = 2L, chunks = 4L,
                                    parallel_backend = inproc, backend = be)
    expect_identical(got, be(cts, method = "RLE"), info = nm)
  }
  expect_false(identical(be(cts, method = "RLE"), edgeR_norm(cts, method = "RLE")))
})

test_that("a custom RLE body that looks up the frame's data by name keeps the frame", {
  testthat::local_mocked_bindings(rp_copy_free = function(...) FALSE, .package = "rnaparallel")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  inproc <- function(idx, f, workers) lapply(idx, f)
  cts <- norm_counts(G = 401L)
  mk <- function(call) {
    e <- new.env(parent = asNamespace("edgeR"))
    rle <- eval(bquote(function(data) {
      gm <- exp(rowMeans(log(data)))
      apply(data, 2, function(u) .(call))
    }))
    environment(rle) <- e
    e$.calcFactorRLE <- rle
    be <- get(paste0(rnaparallel:::rp_edger_generic(), ".default"),
              envir = asNamespace("edgeR"), inherits = FALSE)
    environment(be) <- e
    be
  }
  cases <- list(
    get = mk(quote({ n <- nrow(get("data")); stats::median((u / gm)[gm > 0]) * n / n })),
    exists = mk(quote({
      k <- if (exists("data", inherits = TRUE, mode = "numeric")) 1 else 0.5
      stats::quantile((u / gm)[gm > 0], k * 0.8, type = 1, names = FALSE) })))
  for (nm in names(cases)) {
    be <- cases[[nm]]
    got <- calcNormFactors_parallel(cts, method = "RLE", workers = 2L, chunks = 4L,
                                    parallel_backend = inproc, backend = be)
    expect_identical(got, be(cts, method = "RLE"), info = nm)
  }
})

test_that("a user environment holding an apply is kept when FUN is built by a factory in it", {
  testthat::local_mocked_bindings(rp_copy_free = function(...) FALSE, .package = "rnaparallel")
  withr::local_options(combat.min.norm.cells = 0, combat.min.order.cells = 0)
  inproc <- function(idx, f, workers) lapply(idx, f)
  e <- new.env(parent = asNamespace("edgeR"))
  e$apply <- function(X, MARGIN, FUN, ...) base::apply(X, MARGIN, FUN, ...)
  e$med <- function(v) stats::median(v)
  e$mk <- function(data, gm) function(u) med((u / gm)[gm > 0])
  e$.calcFactorRLE <- function(data) {
    gm <- exp(rowMeans(log(data)))
    apply(data, 2, mk(data, gm))
  }
  for (nm in names(e)) environment(e[[nm]]) <- e
  be <- get(paste0(rnaparallel:::rp_edger_generic(), ".default"),
            envir = asNamespace("edgeR"), inherits = FALSE)
  environment(be) <- e
  cts <- norm_counts()
  got <- calcNormFactors_parallel(cts, method = "RLE", workers = 2L, chunks = 4L,
                                  parallel_backend = inproc, backend = be)
  expect_identical(got, be(cts, method = "RLE"))
})
