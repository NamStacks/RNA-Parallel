## Review fixes in the shared helper: data.frame fallback note, chunks validation, foreach interrupt teardown, ppid and cgroup readers, scheduler-aware core count, held-condition stack, prologue refusals.

rh_counts <- function(seed = 11, G = 120, n = 8) {
  set.seed(seed)
  y <- matrix(rnbinom(G * n, mu = 60, size = 5), G, n,
              dimnames = list(paste0("g", seq_len(G)), paste0("s", seq_len(n))))
  list(y = y, batch = rep(1:2, each = n / 2), group = rep(c("a", "b"), n / 2))
}

rh_tree <- function(files) {
  root <- withr::local_tempdir(.local_envir = parent.frame())
  for (f in names(files)) {
    dir.create(dirname(file.path(root, f)), recursive = TRUE, showWarnings = FALSE)
    writeLines(files[[f]], file.path(root, f))
  }
  root
}

rh_proc <- function(...) {
  p <- withr::local_tempfile(.local_envir = parent.frame())
  writeLines(c(...), p)
  p
}


# ---- data.frame counts ---------------------------------------------------------------

test_that("data.frame counts say the quantile match stood down and still match the original", {
  skip_if_not_installed("sva")
  d <- rh_counts()
  df <- as.data.frame(d$y)
  withr::local_options(list(combat.timing = TRUE, combat.quiet = TRUE, combat.timing.min = 0))
  msgs <- testthat::capture_messages(
    got <- ComBat_seq_parallel(df, batch = d$batch, group = d$group, workers = 2L))
  expect_match(paste(msgs, collapse = ""),
               "match_quantiles on non-matrix or degenerate input stood down", fixed = TRUE)
  ref <- suppressMessages(sva::ComBat_seq(df, batch = d$batch, group = d$group))
  expect_identical(got, ref)
})

test_that("a matrix input does not carry the non-matrix note", {
  skip_if_not_installed("sva")
  d <- rh_counts()
  withr::local_options(list(combat.timing = TRUE, combat.quiet = TRUE, combat.timing.min = 0))
  msgs <- testthat::capture_messages(
    ComBat_seq_parallel(d$y, batch = d$batch, group = d$group, workers = 2L))
  expect_false(grepl("non-matrix", paste(msgs, collapse = ""), fixed = TRUE))
})


# ---- chunks --------------------------------------------------------------------------

test_that("a chunks vector stops with a message that names chunks, before any handle opens", {
  skip_if_not_installed("sva")
  d <- rh_counts()
  expect_error(ComBat_seq_parallel(d$y, d$batch, group = d$group, workers = 2L, chunks = c(2, 3)),
               "`chunks` must be NULL or a single number", fixed = TRUE)
  expect_error(ComBat_seq_parallel(d$y, d$batch, group = d$group, workers = 2L,
                                   chunks = integer(0)),
               "`chunks` must be NULL or a single number", fixed = TRUE)
})

test_that("combat_row_chunks refuses a chunks vector for every dispatcher", {
  expect_error(rnaparallel:::combat_row_chunks(20L, workers = 2L, chunks = c(2, 3)),
               "must be NULL or a single number")
  expect_error(rnaparallel:::combat_row_chunks(20L, workers = 2L, chunks = integer(0)),
               "must be NULL or a single number")
})

test_that("an unusable scalar chunks still clamps and gives the original's result", {
  skip_if_not_installed("sva")
  d <- rh_counts()
  ref <- suppressMessages(sva::ComBat_seq(d$y, d$batch, group = d$group))
  for (ch in list(0, -3, NA, Inf, 2.7, "3", "abc", TRUE)) {
    got <- suppressMessages(ComBat_seq_parallel(d$y, d$batch, group = d$group, workers = 2L,
                                                chunks = ch))
    expect_identical(got, ref, info = deparse(ch))
  }
})


# ---- foreach interrupt ---------------------------------------------------------------

rh_rscript <- function(lines, timeout = 120) {
  script <- tempfile(fileext = ".R")
  writeLines(c(rp_load_line(), lines), script)
  libs <- paste0("R_LIBS=", shQuote(paste(.libPaths(), collapse = .Platform$path.sep)))
  suppressWarnings(system2(file.path(R.home("bin"), "Rscript"), c("--vanilla", shQuote(script)),
                           stdout = TRUE, stderr = TRUE, env = c("NOT_CRAN=true", libs),
                           timeout = timeout))
}

test_that("an interrupted foreach dispatch stops its workers and the next dispatch does not wait", {
  skip_on_cran()
  skip_on_os("windows")
  skip_if_not_installed("doParallel")
  skip_if(rnaparallel:::rp_host_cores() < 2L, "the dispatch needs 2 allowed cores to fork")
  work <- withr::local_tempdir()
  withr::defer(for (p in as.integer(sub("^pid-", "", list.files(work, "^pid-")))) {
    try(tools::pskill(p, tools::SIGKILL), silent = TRUE)
  })
  out <- rh_rscript(c(
    "options(combat.progress = FALSE)",
    sprintf("work <- %s", deparse(work)),
    "f <- function(ii) { writeLines('', file.path(work, paste0('pid-', Sys.getpid()))); Sys.sleep(8); ii }",
    "environment(f) <- list2env(list(work = work), parent = baseenv())",
    "master <- Sys.getpid()",
    "killer <- parallel::mcparallel({",
    "  t <- Sys.time()",
    "  while (length(list.files(work, '^pid-')) < 2L && Sys.time() - t < 60) Sys.sleep(0.05)",
    "  Sys.sleep(0.5)",
    "  tools::pskill(master, tools::SIGINT)",
    "}, detached = TRUE)",
    paste0("r <- tryCatch(rnaparallel:::combat_parallel_lapply(list(1:2, 3:4), f, 2L, 'foreach', ",
           "cells = Inf, min_cells = 0), interrupt = function(i) 'INTERRUPTED')"),
    "pids <- as.integer(sub('^pid-', '', list.files(work, '^pid-')))",
    "t0 <- Sys.time()",
    "while (any(vapply(pids, function(p) isTRUE(tools::pskill(p, 0L)), NA)) && Sys.time() - t0 < 3) Sys.sleep(0.05)",
    "alive <- sum(vapply(pids, function(p) isTRUE(tools::pskill(p, 0L)), NA))",
    "cat('\\nRESULT', if (is.character(r)) r else 'value', alive, '\\n')",
    "g <- function(ii) ii * 10L",
    "environment(g) <- baseenv()",
    "t1 <- Sys.time()",
    paste0("r2 <- rnaparallel:::combat_parallel_lapply(list(1:2, 3:4, 5:6), g, 2L, 'foreach', ",
           "cells = Inf, min_cells = 0)"),
    "cat('\\nSECOND', identical(r2, list(1:2 * 10L, 3:4 * 10L, 5:6 * 10L)),",
    "    format(as.numeric(difftime(Sys.time(), t1, units = 'secs')), digits = 3), '\\n')",
    "rnaparallel::combat_cluster_stop()"))
  info <- paste(tail(out, 8), collapse = "\n")
  res <- strsplit(grep("^RESULT ", out, value = TRUE), " ", fixed = TRUE)
  sec <- strsplit(grep("^SECOND ", out, value = TRUE), " ", fixed = TRUE)
  expect_length(res, 1L)
  expect_length(sec, 1L)
  if (length(res) == 1L && length(sec) == 1L) {
    expect_identical(res[[1L]][2L], "INTERRUPTED", info = info)
    expect_identical(res[[1L]][3L], "0", info = info)
    expect_identical(sec[[1L]][2L], "TRUE", info = info)
    expect_lt(as.numeric(sec[[1L]][3L]), 3)
  }
})


test_that("combat_kill_handles stops a busy socket worker through its ps handle", {
  skip_on_cran()
  skip_if_not_installed("ps")
  cl <- parallel::makeCluster(1L, type = "PSOCK")
  withr::defer(try(suppressWarnings(parallel::stopCluster(cl)), silent = TRUE))
  pid <- parallel::clusterCall(cl, Sys.getpid)[[1L]]
  h <- ps::ps_handle(pid)
  utils::getFromNamespace("sendCall", "parallel")(cl[[1L]], function() Sys.sleep(60), list())
  expect_true(isTRUE(tools::pskill(pid, 0L)))
  expect_true(rnaparallel:::combat_kill_handles(list(NULL, h)))
  t0 <- Sys.time()
  while (isTRUE(tools::pskill(pid, 0L)) && Sys.time() - t0 < 5) Sys.sleep(0.05)
  expect_false(isTRUE(tools::pskill(pid, 0L)))
  expect_no_error(rnaparallel:::combat_kill_handles(list(h)))
  expect_false(rnaparallel:::combat_kill_handles(NULL))
})


# ---- parent pid ----------------------------------------------------------------------

test_that("rp_proc_ppid reads field 4 after the last ') ' and refuses another pid namespace", {
  ok <- rh_proc("777 (R) S 4321 777 777 0 -1 4194560 1 2 3")
  expect_identical(rnaparallel:::rp_proc_ppid(ok, 777L), 4321L)
  weird <- rh_proc("777 (my (weird) name) R 99 1 2 3")
  expect_identical(rnaparallel:::rp_proc_ppid(weird, 777L), 99L)
  expect_identical(rnaparallel:::rp_proc_ppid(ok, 778L), NA_integer_)
  expect_identical(rnaparallel:::rp_proc_ppid(rh_proc("garbage"), 777L), NA_integer_)
  expect_identical(rnaparallel:::rp_proc_ppid(rh_proc(character()), 777L), NA_integer_)
  expect_identical(rnaparallel:::rp_proc_ppid(file.path(tempdir(), "no-such-stat"), 777L),
                   NA_integer_)
})

test_that("rp_getppid falls back to the /proc reader before ps", {
  skip_if(exists("Sys.getppid", envir = baseenv(), mode = "function"), "base R reads the ppid")
  testthat::local_mocked_bindings(rp_proc_ppid = function(...) 4242L, .package = "rnaparallel")
  expect_identical(rnaparallel:::rp_getppid(), 4242L)
})

test_that("rp_getppid on Linux equals the PPid the kernel reports", {
  skip_if_not(file.exists("/proc/self/stat") && file.exists("/proc/self/status"))
  skip_if(exists("Sys.getppid", envir = baseenv(), mode = "function"), "base R reads the ppid")
  st <- readLines("/proc/self/status")
  want <- as.integer(sub("^PPid:\\s*", "", grep("^PPid:", st, value = TRUE)))
  expect_identical(rnaparallel:::rp_getppid(), want)
})


# ---- cgroup memory -------------------------------------------------------------------

test_that("a v2 limit on a parent cgroup bounds the headroom, net of inactive file cache", {
  root <- rh_tree(list(
    "job_1/memory.max" = "1073741824",
    "job_1/memory.current" = "600000000",
    "job_1/memory.stat" = c("anon 1", "inactive_file 100000000", "active_file 5"),
    "job_1/step_0/memory.max" = "max",
    "job_1/step_0/memory.current" = "1000"))
  proc <- rh_proc("0::/job_1/step_0")
  cg <- rnaparallel:::rp_cgroup_mem(proc, root, host_total = 2^40)
  expect_equal(cg[["limit"]], 1073741824)
  expect_equal(cg[["headroom"]], 1073741824 - 500000000)
})

test_that("the tightest of several limits wins", {
  root <- rh_tree(list(
    "a/memory.max" = "4000000000", "a/memory.current" = "1000000000",
    "a/b/memory.max" = "2000000000", "a/b/memory.current" = "1900000000"))
  cg <- rnaparallel:::rp_cgroup_mem(rh_proc("0::/a/b"), root, host_total = 2^40)
  expect_equal(cg[["limit"]], 2e9)
  expect_equal(cg[["headroom"]], 1e8)
})

test_that("a v1 memory controller line is read from the memory hierarchy", {
  root <- rh_tree(list(
    "memory/docker/abc/memory.limit_in_bytes" = "2147483648",
    "memory/docker/abc/memory.usage_in_bytes" = "1073741824",
    "memory/docker/abc/memory.stat" = c("cache 9", "total_inactive_file 73741824")))
  proc <- rh_proc("12:cpu,cpuacct:/docker/abc", "4:memory:/docker/abc")
  cg <- rnaparallel:::rp_cgroup_mem(proc, root, host_total = 2^40)
  expect_equal(cg[["limit"]], 2147483648)
  expect_equal(cg[["headroom"]], 2147483648 - 1000000000)
})

test_that("unlimited, host-sized and unreadable cgroups give NA, never an error", {
  na <- c(limit = NA_real_, headroom = NA_real_)
  v1 <- rh_tree(list("memory/memory.limit_in_bytes" = "9223372036854771712",
                     "memory/memory.usage_in_bytes" = "5"))
  expect_identical(rnaparallel:::rp_cgroup_mem(rh_proc("4:memory:/"), v1, 2^40), na)
  v2 <- rh_tree(list("memory.max" = "max", "memory.current" = "5"))
  expect_identical(rnaparallel:::rp_cgroup_mem(rh_proc("0::/"), v2, 2^40), na)
  big <- rh_tree(list("memory.max" = "1000000", "memory.current" = "5"))
  expect_identical(rnaparallel:::rp_cgroup_mem(rh_proc("0::/"), big, host_total = 1e6), na)
  expect_identical(rnaparallel:::rp_cgroup_mem(file.path(tempdir(), "nope"), v2, 2^40), na)
  junk <- rh_tree(list("memory.max" = "lots", "memory.current" = "x"))
  expect_identical(rnaparallel:::rp_cgroup_mem(rh_proc("0::/"), junk, 2^40), na)
})

test_that("rp_mem_available and rp_mem_total never exceed the cgroup figures on Linux", {
  skip_if_not(file.exists("/proc/meminfo"))
  testthat::local_mocked_bindings(
    rp_cgroup_mem = function(...) c(limit = 3e9, headroom = 1e9), .package = "rnaparallel")
  expect_lte(rnaparallel:::rp_mem_available(), 1e9)
  expect_lte(rnaparallel:::rp_mem_total(), 3e9)
})


# ---- scheduler-aware core count -------------------------------------------------------

rh_cores_memo <- function(detected = NULL, env = parent.frame()) {
  cc <- get(".combat_clusters", envir = asNamespace("rnaparallel"))
  old <- cc$allcores
  cc$allcores <- detected
  withr::defer({ if (is.null(old)) cc$allcores <- NULL else cc$allcores <- old }, envir = env)
  invisible(cc)
}

rh_no_alloc <- function(host = FALSE, env = parent.frame()) {
  withr::local_envvar(c(MC_CORES = NA, SLURM_CPUS_PER_TASK = NA, NSLOTS = NA, PBS_NUM_PPN = NA,
                        LSB_DJOB_NUMPROC = NA), .local_envir = env)
  withr::local_options(mc.cores = NULL, .local_envir = env)
  if (host) {
    testthat::skip_if(!is.na(rnaparallel:::rp_cpu_limit()),
                      "this host declares a cgroup CPU quota of its own")
  }
}

rh_pids <- function(workers) {
  unlist(rnaparallel:::combat_parallel_lapply(
    as.list(1:4), function(i) Sys.getpid(), workers, "mclapply", cells = Inf, min_cells = 0))
}

test_that("rp_cpu_limit reads the scheduler variables, the smallest wins, and ignores mc.cores", {
  none <- rh_tree(list("cpu.max" = "max 100000"))
  rh_no_alloc()
  expect_identical(rnaparallel:::rp_cpu_limit(rh_proc("0::/"), none), NA_integer_)
  withr::local_envvar(c(SLURM_CPUS_PER_TASK = "6", NSLOTS = "4"))
  expect_identical(rnaparallel:::rp_cpu_limit(rh_proc("0::/"), none), 4L)
  withr::local_options(mc.cores = 3)
  withr::local_envvar(c(MC_CORES = "2"))
  expect_identical(rnaparallel:::rp_cpu_limit(rh_proc("0::/"), none), 4L)
  withr::local_envvar(c(PBS_NUM_PPN = "2", LSB_DJOB_NUMPROC = "3"))
  expect_identical(rnaparallel:::rp_cpu_limit(rh_proc("0::/"), none), 2L)
})

test_that("rp_cpu_limit reads a cgroup CPU quota, rounded up, from any ancestor", {
  rh_no_alloc()
  v2 <- rh_tree(list("job/cpu.max" = "250000 100000", "job/step/cpu.max" = "max 100000"))
  expect_identical(rnaparallel:::rp_cpu_limit(rh_proc("0::/job/step"), v2), 3L)
  v1 <- rh_tree(list("cpu/cpu.cfs_quota_us" = "400000", "cpu/cpu.cfs_period_us" = "100000"))
  expect_identical(rnaparallel:::rp_cpu_limit(rh_proc("3:cpu,cpuacct:/"), v1), 4L)
  v1u <- rh_tree(list("cpu/cpu.cfs_quota_us" = "-1", "cpu/cpu.cfs_period_us" = "100000"))
  expect_identical(rnaparallel:::rp_cpu_limit(rh_proc("3:cpu,cpuacct:/"), v1u), NA_integer_)
})

test_that("the default worker count is min(8, cores - 2) without an allocation", {
  skip_on_os("windows")
  rh_no_alloc(host = TRUE)
  for (n in list(c(12L, 8L), c(6L, 4L), c(4L, 2L), c(3L, 1L), c(2L, 1L), c(64L, 8L))) {
    rh_cores_memo(n[1L])
    expect_identical(rnaparallel:::combat_default_workers(NULL), n[2L], info = as.character(n[1L]))
  }
  rh_cores_memo(12L)
  expect_identical(rnaparallel:::combat_default_workers(5L), 5L)
})

test_that("a declared allocation is the worker count itself, capped at 8, with no reserve", {
  skip_on_os("windows")
  rh_no_alloc(host = TRUE)
  rh_cores_memo(12L)
  for (n in list(c("4", 4L), c("2", 2L), c("1", 1L), c("64", 8L), c("9", 8L))) {
    withr::local_envvar(c(SLURM_CPUS_PER_TASK = n[1L]))
    expect_identical(rnaparallel:::combat_default_workers(NULL), as.integer(n[2L]), info = as.character(n[1L]))
  }
  expect_identical(rnaparallel:::rp_host_cores(), 9L)
  withr::local_envvar(c(SLURM_CPUS_PER_TASK = "64"))
  expect_identical(rnaparallel:::rp_host_cores(), 12L)
})

test_that("options(mc.cores) neither shrinks the default workers nor caps explicit ones", {
  skip_on_os("windows")
  rh_no_alloc(host = TRUE)
  detected <- max(1L, parallel::detectCores(), na.rm = TRUE)
  for (mc in c(1L, 2L, 4L)) {
    rh_cores_memo()
    withr::local_options(mc.cores = mc)
    expect_identical(rnaparallel:::rp_host_cores(), detected, info = as.character(mc))
    expect_identical(rnaparallel:::combat_default_workers(NULL),
                     max(1L, min(8L, detected - 2L)), info = as.character(mc))
  }
})

test_that("a scheduler variable set or unset after the first call takes effect on the next", {
  skip_on_os("windows")
  rh_no_alloc(host = TRUE)
  rh_cores_memo(12L)
  before <- rnaparallel:::rp_host_cores()
  withr::with_envvar(c(SLURM_CPUS_PER_TASK = "2"), {
    expect_identical(rnaparallel:::rp_host_cores(), 2L)
    expect_identical(rnaparallel:::combat_default_workers(NULL), 2L)
  })
  expect_identical(rnaparallel:::rp_host_cores(), before)
  withr::with_envvar(c(SLURM_CPUS_PER_TASK = "5"), {
    expect_identical(rnaparallel:::rp_host_cores(), 5L)
  })
  expect_identical(rnaparallel:::rp_host_cores(), before)
})

test_that("the default worker count and the dispatch cap follow a declared allocation", {
  skip_on_os("windows")
  rh_no_alloc()
  withr::local_envvar(c(SLURM_CPUS_PER_TASK = "1"))
  rh_cores_memo()
  expect_identical(rnaparallel:::rp_host_cores(), 1L)
  expect_identical(rnaparallel:::combat_default_workers(NULL), 1L)

# With one allowed core the chunks run in the master; without the cap they would fork.
  expect_true(all(rh_pids(4L) == Sys.getpid()))
})

test_that("options(mc.cores) does not cut an explicit workers, and a lifted allocation forks again", {
  skip_on_os("windows")
  rh_no_alloc(host = TRUE)
  rh_cores_memo()
  skip_if(rnaparallel:::rp_host_cores() < 2L, "forking needs 2 cores")
  withr::local_options(mc.cores = 1)
  expect_true(all(rh_pids(4L) != Sys.getpid()))
  withr::with_envvar(c(SLURM_CPUS_PER_TASK = "1"), {
    expect_true(all(rh_pids(4L) == Sys.getpid()))
  })
  expect_true(all(rh_pids(4L) != Sys.getpid()))
})


# ---- held conditions keep the stack ----------------------------------------------------

test_that("rp_hold lets an outer calling handler see the failing frames, with the held conditions", {
  deep_failure <- function() stop("deep")
  seen <- NULL
  carried <- NULL
  res <- try(withCallingHandlers(
    rnaparallel:::rp_hold({ message("held note"); deep_failure() }),
    error = function(e) {
      seen <<- vapply(sys.calls(), function(cl) deparse(cl[[1L]])[1L], "")
      carried <<- e$rp_held
    }), silent = TRUE)
  expect_s3_class(res, "try-error")
  expect_true("deep_failure" %in% seen)
  expect_length(carried, 1L)
  expect_identical(conditionMessage(carried[[1L]]), "held note\n")
})

test_that("rp_hold without held conditions lets the original error through untouched", {
  e <- tryCatch(rnaparallel:::rp_hold(stop("plain")), error = function(e) e)
  expect_identical(conditionMessage(e), "plain")
  expect_null(e$rp_held)
})

test_that("a nested rp_hold keeps the inner conditions after the outer ones, once each", {
  inner <- function() rnaparallel:::rp_hold({ message("inner note"); stop("boom") })
  e <- tryCatch(rnaparallel:::rp_hold({ warning("outer warn"); inner() }), error = function(e) e)
  held <- vapply(e$rp_held, conditionMessage, "")
  expect_identical(held, c("outer warn", "inner note\n"))
})


# ---- prologue refusals ---------------------------------------------------------------

test_that("rp_prologue refuses unusable workers with the matching message", {
  pro <- rnaparallel:::rp_prologue
  for (w in list(0L, -1, Inf)) expect_error(pro(w), "positive integer", info = deparse(w))
  expect_error(pro(2.5), "whole number")
  expect_error(pro(c(2, 3)), "single integer")
  expect_error(pro(NA_integer_), "positive integer")
})

test_that("rp_prologue refuses a garbage combat.min.* value for every gate", {
  gates <- c("combat.min.cells", "combat.min.disp.cells", "combat.min.ls.cells",
             "combat.min.norm.cells", "combat.min.order.cells", "combat.min.glm.cells",
             "combat.min.dupcor.cells", "combat.min.batch.cells", "combat.min.wt.genes")
  for (g in gates) {
    for (bad in list("lots", -1, NA, c(1, 2))) {
      withr::with_options(stats::setNames(list(bad), g), {
        expect_error(rnaparallel:::rp_prologue(1L), "must be a single non-negative number",
                     info = paste(g, deparse(bad)))
      })
    }
  }
})

test_that("every entry point reaches rp_prologue's workers refusal", {
  skip_if_not_installed("limma")
  skip_if_not_installed("sva")
  d <- rh_counts()
  y <- log2(d$y + 1)
  design <- cbind(Intercept = 1, g = as.numeric(d$group == "b"))
  expect_error(ComBat_seq_parallel(d$y, d$batch, workers = 2.5), "whole number")
  expect_error(ComBat_seq_parallel(d$y, d$batch, workers = c(2, 3)), "single integer")
  expect_error(lmFit_parallel(y, design, workers = 2.5), "whole number")
  expect_error(lmFit_parallel(y, design, workers = c(2, 3)), "single integer")
  expect_error(duplicateCorrelation_parallel(y, design, block = rep(1:4, 2), workers = 2.5),
               "whole number")
  expect_error(removeBatchEffect_parallel(y, batch = d$batch, workers = 2.5), "whole number")
})

test_that("rp_darwin_fast_cores counts every performance tier above the efficiency one", {
  fake <- function(vals) function(k) if (is.null(vals[[k]])) character() else vals[[k]]
  m6 <- list(hw.nperflevels = "3", hw.perflevel0.physicalcpu = "2",
             hw.perflevel1.physicalcpu = "4", hw.perflevel2.physicalcpu = "6")
  expect_identical(rnaparallel:::rp_darwin_fast_cores(fake(m6)), 6L)
  m3 <- list(hw.nperflevels = "2", hw.perflevel0.physicalcpu = "4",
             hw.perflevel1.physicalcpu = "4")
  expect_identical(rnaparallel:::rp_darwin_fast_cores(fake(m3)), 4L)
  one <- list(hw.nperflevels = "1", hw.perflevel0.physicalcpu = "8")
  expect_identical(rnaparallel:::rp_darwin_fast_cores(fake(one)), 8L)
  expect_identical(rnaparallel:::rp_darwin_fast_cores(fake(list())), NA_integer_)
  gap <- list(hw.nperflevels = "3", hw.perflevel0.physicalcpu = "2")
  expect_identical(rnaparallel:::rp_darwin_fast_cores(fake(gap)), NA_integer_)
})
