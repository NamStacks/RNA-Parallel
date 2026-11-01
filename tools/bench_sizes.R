#!/usr/bin/env Rscript
## Times each companion against its original at every simulated size cited in REFERENCE.md and the help pages, at the package's default worker count, checking identical() on every pair and recording the worker count the memory guard allowed; run as `Rscript tools/bench_sizes.R <section>` once per section (dupcor, tmm, combat, rbe, lmfit, gates, memo) so each starts from a small parent process, or with no argument for all of them in one process.
suppressMessages({library(rnaparallel); library(edgeR); library(limma); library(sva)})
options(combat.progress = FALSE, warn = 1)
w <- rnaparallel:::combat_default_workers(NULL)
sec <- commandArgs(TRUE)
want <- function(x) !length(sec) || x %in% sec
# A short call is timed as a batch of repeats, so the 1 ms timer tick does not decide the ratio.
best <- function(f, agg = min, n = 5L) {
  t1 <- system.time(f())[["elapsed"]]
  if (t1 >= 2) return(agg(c(t1, system.time(f())[["elapsed"]], system.time(f())[["elapsed"]])))
  reps <- max(1L, ceiling(0.25 / max(t1, 1e-4)))
  agg(vapply(seq_len(n), function(i) system.time(for (k in seq_len(reps)) f())[["elapsed"]] / reps, numeric(1)))
}
sim <- function(G, N, seed) {
  set.seed(seed)
  mu <- exp(rnorm(G, mean = 4, sd = 1.8))
  m <- matrix(rnbinom(G * N, mu = mu, size = 1 / 0.15), G, N)
  storage.mode(m) <- "integer"
  m
}
res <- list()
run <- function(companion, G, N, orig, comp, time = best, wk = w) {
  used <- wk
# The memory guard lowers the worker count with a warning; the lowest count it chose is recorded and the warning muffled.
  guard <- function(cnd) {
    n <- regmatches(conditionMessage(cnd), regexpr("(?<=Using )[0-9]+(?= instead)", conditionMessage(cnd), perl = TRUE))
    if (length(n)) { used <<- min(used, as.integer(n)); invokeRestart("muffleWarning") }
  }
  withCallingHandlers({
    stopifnot(identical(orig(), comp()))
    t0 <- time(orig); t1 <- time(comp)
  }, warning = guard)
  res[[length(res) + 1L]] <<- data.frame(companion = companion, size = sprintf("%d x %d", G, N), workers = used,
                                          original_s = t0, companion_s = t1, speedup = round(t0 / t1, 2))
  cat(sprintf("%-30s %7d x %-4d %2d w %10.5f s %10.5f s %6.2fx\n", companion, G, N, used, t0, t1, t0 / t1))
}

if (want("dupcor")) for (s in list(c(200L, 12L), c(1000L, 24L), c(3000L, 50L), c(3000L, 100L))) {
  y <- cpm(sim(s[1], s[2], 1L), log = TRUE)
  blk <- rep(seq_len(s[2] / 2L), each = 2L)
  des <- model.matrix(~ factor(rep(1:2, length.out = s[2])))
  run("duplicateCorrelation", s[1], s[2],
      function() duplicateCorrelation(y, des, block = blk),
      function() duplicateCorrelation_parallel(y, des, block = blk, workers = w))
}
if (want("tmm")) for (s in list(c(2000L, 20L), c(5000L, 50L), c(20000L, 50L), c(20000L, 200L), c(20000L, 500L))) {
  d <- DGEList(sim(s[1], s[2], 2L))
  run("calcNormFactors (TMM)", s[1], s[2],
      function() normLibSizes(d),
      function() calcNormFactors_parallel(d, workers = w))
}
if (want("tmm")) for (m in c("TMMwsp", "RLE", "upperquartile")) {
  d <- DGEList(sim(2000L, 20L, 2L))
  run(sprintf("calcNormFactors (%s)", m), 2000L, 20L,
      function() normLibSizes(d, method = m),
      function() calcNormFactors_parallel(d, method = m, workers = w))
}
if (want("combat")) for (s in list(c(300L, 20L), c(6000L, 120L))) {
  cts <- sim(s[1], s[2], 3L)
  b <- factor(rep(1:2, each = s[2] / 2L))
  run("ComBat_seq", s[1], s[2],
      function() suppressMessages(ComBat_seq(cts, batch = b)),
      function() suppressMessages(ComBat_seq_parallel(cts, batch = b, workers = w)))
}
if (want("rbe")) for (s in list(c(2000L, 20L), c(20000L, 50L), c(20000L, 200L), c(20000L, 500L))) {
  y <- cpm(sim(s[1], s[2], 4L), log = TRUE)
  b <- factor(rep(1:2, length.out = s[2]))
  run("removeBatchEffect", s[1], s[2],
      function() suppressMessages(removeBatchEffect(y, batch = b)),
      function() suppressMessages(removeBatchEffect_parallel(y, batch = b, workers = w)))
}
# The weighted lmFit grid opens both gates so the split runs at every size, timed as a median of 9 batches.
med9 <- function(f) best(f, median, 9L)
old <- options(combat.min.wt.genes = 0, combat.min.cells = 0)
if (want("lmfit")) for (G in c(500L, 1000L, 2000L, 4000L, 8000L, 16000L)) for (N in c(8L, 24L, 48L)) {
  des <- model.matrix(~ factor(rep(1:2, length.out = N)))
  v <- voom(DGEList(sim(G, N, 5L)), des)
  run("lmFit voom, gate open", G, N,
      function() lmFit(v, des),
      function() lmFit_parallel(v, des, workers = w), time = med9)
}
options(old)
if (want("gates")) {
  cat(sprintf("fork round trip, %d trivial mclapply jobs: %.1f ms\n", w,
              1000 * best(function() parallel::mclapply(seq_len(w), function(i) i, mc.cores = w))))
  old <- options(combat.min.norm.cells = 0)
  for (G in c(2000L, 4000L, 10000L)) {
    d <- DGEList(sim(G, 50L, 2L))
    run("TMM, gate open", G, 50L, function() normLibSizes(d), function() calcNormFactors_parallel(d, workers = w))
  }
  options(old); old <- options(combat.min.order.cells = 0)
  for (N in c(200L, 500L)) {
    d <- DGEList(sim(20000L, N, 2L))
    run("RLE, gate open", 20000L, N, function() normLibSizes(d, method = "RLE"),
        function() calcNormFactors_parallel(d, method = "RLE", workers = w))
  }
  options(old)
  for (G in c(500L, 1000L)) {
    des <- model.matrix(~ factor(rep(1:2, 12L)))
    v <- voom(DGEList(sim(G, 24L, 5L)), des)
    run("lmFit voom, default gates", G, 24L, function() lmFit(v, des), function() lmFit_parallel(v, des, workers = w))
  }
  y <- cpm(sim(20000L, 50L, 4L), log = TRUE)
  des <- model.matrix(~ factor(rep(1:2, 25L)))
  run("lmFit no weights, default gates", 20000L, 50L, function() lmFit(y, des), function() lmFit_parallel(y, des, workers = w))
}
if (want("memo")) {
  for (s in list(c(200L, 12L), c(300L, 100L))) {
    y <- cpm(sim(s[1], s[2], 1L), log = TRUE)
    blk <- rep(seq_len(s[2] / 2L), each = 2L)
    des <- model.matrix(~ factor(rep(1:2, length.out = s[2])))
    f <- tempfile()
    Rprof(f, interval = 0.001)
    for (i in 1:30) duplicateCorrelation(y, des, block = blk)
    Rprof(NULL)
    p <- summaryRprof(f)$by.total
    cat(sprintf("duplicateCorrelation %d x %d, share of the original's time: model.matrix %.0f%%, La.svd %.0f%%\n", s[1], s[2],
                100 * p["\"model.matrix\"", "total.time"] / p["\"duplicateCorrelation\"", "total.time"],
                100 * p["\"La.svd\"", "total.time"] / p["\"duplicateCorrelation\"", "total.time"]))
  }
  y <- cpm(sim(3000L, 100L, 1L), log = TRUE)
  blk <- rep(seq_len(50L), each = 2L)
  des <- model.matrix(~ factor(rep(1:2, length.out = 100L)))
  for (k in c(1L, 4L)) run(sprintf("duplicateCorrelation, %d worker(s)", k), 3000L, 100L,
                          function() duplicateCorrelation(y, des, block = blk),
                          function() duplicateCorrelation_parallel(y, des, block = blk, workers = k), wk = k)
}
if (length(res)) print(do.call(rbind, res), row.names = FALSE)
cat("workers:", w, " machine:", Sys.info()[["machine"]], " cores:", parallel::detectCores(),
    " R:", R.version.string, "\n")
