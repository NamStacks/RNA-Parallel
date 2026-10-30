## Review fixes in R/verbose.R: progress tailing, label sanitizing, directory safety and the peak figure.

write_rows <- function(path, rows) {
  cat(paste0(rows, "\n"), file = path, sep = "", append = TRUE)
}

test_that("a line appended after the size was measured is read once, not twice", {
  d <- withr::local_tempdir()
  path <- file.path(d, "rnaparallel-1.tsv")
  write_rows(path, c("1\ta\t1\tstart", "2\ta\t1\tdone"))
  cache <- new.env(parent = emptyenv())
  expect_identical(nrow(rnaparallel:::rp_progress_read(d, cache = cache)), 2L)

  write_rows(path, "3\ta\t2\tstart")
  real_size <- base::file.size
  fired <- FALSE
  local_mocked_bindings(file.size = function(...) {
    sz <- real_size(...)
    if (!fired) {
      fired <<- TRUE
      write_rows(path, "4\ta\t2\tdone")
    }
    sz
  }, .package = "base")
  rnaparallel:::rp_progress_read(d, cache = cache)
  expect_true(fired)
  local_mocked_bindings(file.size = real_size, .package = "base")
  r <- rnaparallel:::rp_progress_read(d, cache = cache)
  expect_identical(nrow(r), 4L)
  expect_identical(r$event, c("start", "done", "start", "done"))
})

test_that("a half-written last line is held back until its newline arrives", {
  d <- withr::local_tempdir()
  path <- file.path(d, "rnaparallel-1.tsv")
  cat("1\ta\t1\tstart\n2\ta\t1\tdo", file = path)
  cache <- new.env(parent = emptyenv())
  r1 <- rnaparallel:::rp_progress_read(d, cache = cache)
  expect_identical(nrow(r1), 1L)
  expect_identical(r1$event, "start")
  cat("ne\n", file = path, append = TRUE)
  r2 <- rnaparallel:::rp_progress_read(d, cache = cache)
  expect_identical(r2$event, c("start", "done"))
  expect_identical(nrow(rnaparallel:::rp_progress_read(d)), 2L)
})

test_that("a stress of appends read in a loop returns every line exactly once", {
  skip_on_os("windows")
  d <- withr::local_tempdir()
  path <- file.path(d, "rnaparallel-1.tsv")
  n <- 3000L
  writer <- parallel::mcparallel({
    for (i in seq_len(n)) rnaparallel:::rp_progress_file_write(d, "s", i, "start")
  })
  cache <- new.env(parent = emptyenv())
  running <- TRUE
  while (running) {
    rnaparallel:::rp_progress_read(d, cache = cache)
    running <- is.null(parallel::mccollect(writer, wait = FALSE))
  }
  r <- rnaparallel:::rp_progress_read(d, cache = cache)
  expect_identical(nrow(r), n)
  expect_identical(r$chunk, seq_len(n))
})

test_that("an unfinished chunk is not hidden by the same chunk number finishing in an earlier dispatch", {
  d <- withr::local_tempdir()
  write_rows(file.path(d, "rnaparallel-1.tsv"),
             c("100\tcall\t1\tstart", "102\tcall\t1\tdone",
               "102\tcall\t2\tstart", "104\tcall\t2\tdone",
               "200\tcall\t1\tstart", "202\tcall\t1\tdone"))
  write_rows(file.path(d, "rnaparallel-2.tsv"),
             c("200\tcall\t2\tstart"))
  s <- rnaparallel:::rp_progress_summarise(rnaparallel:::rp_progress_read(d))
  expect_identical(c(s$done, s$started, s$stalled), c(3L, 4L, 1L))
  v <- suppressMessages(rnaparallel_progress(d))
  expect_identical(v$stalled, 1L)
})

test_that("a start with a later start of the same chunk in its own file is unfinished", {
  d <- withr::local_tempdir()
  write_rows(file.path(d, "rnaparallel-1.tsv"),
             c("100\tcall\t1\tstart", "300\tcall\t1\tstart", "302\tcall\t1\tdone"))
  s <- rnaparallel:::rp_progress_summarise(rnaparallel:::rp_progress_read(d))
  expect_identical(s$stalled, 1L)
})

test_that("seconds per chunk pairs each start with its own done across dispatches", {
  d <- withr::local_tempdir()
  rows <- unlist(lapply(0:4, function(k) {
    t0 <- 1000 + 100 * k
    c(sprintf("%d\tcall\t%d\tstart", t0, 1:4), sprintf("%d\tcall\t%d\tdone", t0 + 2, 1:4))
  }))
  write_rows(file.path(d, "rnaparallel-1.tsv"), rows)
  s <- rnaparallel:::rp_progress_summarise(rnaparallel:::rp_progress_read(d))
  expect_equal(s$secs_per_chunk, 2)
  expect_identical(s$stalled, 0L)
})

test_that("tailed and full reads keep the file column and agree on a multi-file directory", {
  d <- withr::local_tempdir()
  write_rows(file.path(d, "rnaparallel-1.tsv"), c("1\ta\t1\tstart", "2\ta\t1\tdone"))
  write_rows(file.path(d, "rnaparallel-2.tsv"), c("1\ta\t2\tstart"))
  full <- rnaparallel:::rp_progress_read(d)
  tail <- rnaparallel:::rp_progress_read(d, cache = new.env(parent = emptyenv()))
  expect_identical(full, tail)
  expect_identical(basename(unique(full$file)), c("rnaparallel-1.tsv", "rnaparallel-2.tsv"))
})

test_that("a label with a tab, newline or quote still gives a readable progress file", {
  d <- withr::local_tempdir()
  for (lab in c("tab\there", "new\nline", "5\" gel", "Breast \"luminal\" cohort")) {
    rnaparallel:::rp_progress_file_write(d, lab, 1L, "start")
    rnaparallel:::rp_progress_file_write(d, lab, 1L, "done")
  }
  r <- rnaparallel:::rp_progress_read(d)
  expect_identical(nrow(r), 8L)
  expect_identical(unique(r$stage),
                   c("tab here", "new line", "5  gel", "Breast  luminal  cohort"))
})

test_that("a real dispatch with a hostile label writes rows that read back", {
  skip_on_os("windows")
  d <- withr::local_tempdir()
  withr::local_options(combat.progress.dir = d)
  cts <- matrix(rpois(40 * 8, 20), 40, 8)
  invisible(utils::capture.output(suppressMessages(
    got <- calcNormFactors_parallel(cts, workers = 2L, parallel_backend = "mclapply",
                                    label = "ER\tpos \"A\""))))
  expect_true(length(list.files(d, "^rnaparallel-.*\\.tsv$")) >= 1L)
  r <- rnaparallel:::rp_progress_read(d)
  expect_false(is.null(r))
  expect_identical(unique(r$stage), "ER pos  A ")
  expect_identical(sum(r$event == "start"), sum(r$event == "done"))
  expect_length(got, 8L)
})

test_that("a relative combat.progress.dir reaches workers as an absolute path", {
  skip_on_os("windows")
  base <- withr::local_tempdir()
  other <- file.path(base, "elsewhere")
  dir.create(other)
  withr::local_dir(base)
  withr::local_options(combat.progress.dir = "prog")
  d <- rnaparallel:::rp_progress_dir()
  expect_true(startsWith(d, "/"))
  expect_identical(d, normalizePath(file.path(base, "prog")))
  worker <- parallel::mcparallel({
    setwd(other)
    rnaparallel:::rp_progress_file_write(d, "s", 1L, "start")
  })
  parallel::mccollect(worker)
  expect_length(list.files(d, "^rnaparallel-.*\\.tsv$"), 1L)
  expect_length(list.files(other), 0L)
})

test_that("a world-writable progress directory without the sticky bit is refused", {
  skip_on_os("windows")
  d <- withr::local_tempdir()
  Sys.chmod(d, "0777", use_umask = FALSE)
  withr::local_options(combat.progress.dir = d)
  expect_error(rnaparallel:::rp_step_begin(NULL, "unit", matrix(1, 2, 2), "serial", 1L),
               "world-writable")
})

test_that("a progress directory another user owns is refused", {
  skip_on_os("windows")
  d <- withr::local_tempdir()
  withr::local_options(combat.progress.dir = d)
  real_info <- base::Sys.info
  local_mocked_bindings(Sys.info = function() {
    x <- real_info()
    x[["effective_user"]] <- paste0(x[["effective_user"]], "-not-me")
    x
  }, .package = "base")
  expect_error(rnaparallel:::rp_step_begin(NULL, "unit", matrix(1, 2, 2), "serial", 1L),
               "owned by another user")
})

test_that("the write probe does not follow a planted symlink at the old predictable name", {
  skip_on_os("windows")
  d <- withr::local_tempdir()
  victim <- file.path(withr::local_tempdir(), "victim.txt")
  writeLines("keep me", victim)
  file.symlink(victim, file.path(d, sprintf(".rp_write_test_%d", Sys.getpid())))
  withr::local_options(combat.progress.dir = d)
  h <- rnaparallel:::rp_step_begin(NULL, "unit", matrix(1, 2, 2), "serial", 1L)
  rnaparallel:::rp_step_end(h)
  expect_identical(readLines(victim), "keep me")
})

test_that("a progress directory the package creates is private", {
  skip_on_os("windows")
  d <- file.path(withr::local_tempdir(), "new", "progress")
  withr::local_options(combat.progress.dir = d)
  h <- rnaparallel:::rp_step_begin(NULL, "unit", matrix(1, 2, 2), "serial", 1L)
  rnaparallel:::rp_step_end(h)
  expect_identical(format(file.info(d)$mode), "700")
})

test_that("the timing line prints MB under 1 GB and one decimal of GB above", {
  withr::local_options(combat.timing = TRUE, combat.timing.min = 0, combat.progress.dir = NULL)
  line <- function(bytes) {
    local_mocked_bindings(rp_mem_peak = function() bytes, .package = "rnaparallel")
    h <- rnaparallel:::rp_step_begin(NULL, "unit", matrix(1, 2, 2), "serial", 1L)
    testthat::capture_messages(rnaparallel:::rp_step_end(h))
  }
  expect_match(line(0.2 * 2^30), "peak 205 MB", fixed = TRUE)
  expect_match(line(51.4 * 2^30), "peak 51.4 GB", fixed = TRUE)
  expect_match(line(1.5 * 2^30), "peak 1.5 GB", fixed = TRUE)
})

test_that("a NUL byte in a progress file is skipped and the cache still advances past it", {
  d <- withr::local_tempdir()
  path <- file.path(d, "rnaparallel-1.tsv")
  write_rows(path, "1\ta\t1\tstart")
  cache <- new.env(parent = emptyenv())
  expect_identical(nrow(rnaparallel:::rp_progress_read(d, cache = cache)), 1L)

  con <- file(path, open = "ab")
  writeBin(c(as.raw(rep(0L, 4L)), charToRaw("2\ta\t1\tdone\n")), con)
  close(con)
  r <- expect_no_error(rnaparallel:::rp_progress_read(d, cache = cache))
  expect_identical(r$event, c("start", "done"))
  expect_identical(cache[[path]]$size, file.size(path))

  con <- file(path, open = "ab")
  writeBin(charToRaw("3\ta\t2\tstart\n"), con)
  close(con)
  r2 <- rnaparallel:::rp_progress_read(d, cache = cache)
  expect_identical(r2$event, c("start", "done", "start"))
  expect_identical(cache[[path]]$size, file.size(path))
})
