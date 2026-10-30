# RNA-Parallel

[![version](https://img.shields.io/badge/version-0.5.1-blue)](NEWS.md)
[![R](https://img.shields.io/badge/R-%E2%89%A5%204.1-blue)](DESCRIPTION)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE.md)

Parallel companions for five functions in sva, edgeR and limma. Each one calls the original
function unmodified and returns output `identical()` to it, bit for bit. Same arguments, same
defaults (exceptions under [Use](#use)), same result, faster at cohort scale.

Rendered analysis: [macOS](https://namstacks.github.io/RNA-Parallel/) ·
[Linux](https://namstacks.github.io/RNA-Parallel/linux.html) ·
[Windows](https://namstacks.github.io/RNA-Parallel/windows.html)
(macOS rendered with rnaparallel 0.5.1; Linux and Windows with 0.5.0, re-render pending)

## Speedup

TCGA, 18,270 genes by 1,500 tumors. Every arm `identical()` to the original on all three
platforms. macOS: Mac mini M6, 6 fast + 6 efficiency cores. Linux: 2x Xeon, 16 cores. Windows: Ultra 9 185H, 6P+10E.

| companion | runs | macOS | Linux | Windows |
|---|---|---:|---:|---:|
| `ComBat_seq_parallel()` | `sva::ComBat_seq` | 5.31x @ 8w | **9.34x @ 16w** | 3.57x @ 6w |
| `calcNormFactors_parallel()` | `edgeR::normLibSizes` | **5.78x @ 8w** | 4.12x @ 8w | 1.74x @ 2w |
| `lmFit_parallel()` | `limma::lmFit` | 1.58x @ 8w | **3.37x @ 16w** | 1.10x @ 4w |
| `duplicateCorrelation_parallel()` | `limma::duplicateCorrelation` | 4.53x @ 6w | **7.22x @ 16w** | 2.07x @ 4w |
| `removeBatchEffect_parallel()` | `limma::removeBatchEffect` | **3.11x @ 8w** | 1.39x @ 8w | 0.90x @ 2w |

Bold = fastest platform per row. Windows has no `fork()` (a worker is a full copied process, and
only 6 of 16 cores are performance cores), which caps its scaling; `lmFit`/`removeBatchEffect`
there are parity, not speedups. Full breakdown and every wall-clock number in
[REFERENCE.md](REFERENCE.md#cross-platform).

Nothing here is reimplemented, apart from one helper transcribed from sva and three default
statements transcribed from edgeR (see [License](#license)). The original function runs, with
only its slow internal steps swapped for parallel versions in a child of its own
environment. `identical()` is checked directly, not a tolerance.

## Why these five

RNA-Parallel is a companion, not a replacement. It plugs into five steps of a limma, edgeR or
sva ComBat-seq pipeline, each chosen because all three hold:

1. **It is slow at cohort scale.** Most steps finish in seconds; a few take minutes.
2. **It has no parallel option of its own.** No exported limma or edgeR function takes a
   `BPPARAM`, `parallel` or worker argument, and neither does `sva::ComBat_seq`. DESeq2's
   `DESeq()`, `results()` and `lfcShrink()` and sva's `ComBat()` already take `BPPARAM`.
3. **It splits without changing the answer.** Steps that pool every gene into one estimate
   (eBayes priors, dispersion trends, voom's lowess curve, quantile normalization) do not.

Serial time, simulated 20,000 genes by 300 samples, Apple M3 (`tools/profile_pipelines.R`):

| step | serial | companion | why |
|---|---:|---|---|
| `limma::voomWithQualityWeights` | 906.5 s | no | each gene's update feeds the sample weights the next gene starts from, so the loop is sequential and no split reproduces it |
| `limma::duplicateCorrelation` | 348.9 s | yes | one REML fit per gene |
| `limma::lmFit`, block + correlation | 60.0 s | yes | one Cholesky per gene under voom weights |
| `sva::ComBat_seq` | 32.7 s | yes | quantile matching splits by gene rows; common and tagwise dispersion split by batch; `glmFit` splits by rows only when `group` or `covar_mod` is given |
| `DESeq2::DESeq` | 32.0 s | no | already parallel through `BPPARAM` |
| `edgeR::estimateDisp`, `edgeR::glmQLFit` | 15.2 s, 4.1 s | no | built and removed: output was not `identical()` |
| `edgeR::normLibSizes` (TMM) | 2.2 s | yes | one factor per sample, each against one reference column chosen once from all samples |
| `limma::lmFit` (voom weights), `limma::removeBatchEffect` | 0.9 s, 0.1 s | yes | one weighted fit per gene; one `lmFit` with the batch columns added |
| `DESeq2::vst`, `edgeR::glmQLFTest` | 0.9 s, 0.2 s | no | not timed at cohort scale |
| `limma::voom` | 0.5 s | no | its `lowess` trend's span is a fraction of the gene count, so only the arithmetic after it splits; a companion measured 0.99x |
| `eBayes`, `topTable`, `filterByExpr` and other quick steps | under 0.1 s | no | nothing to gain |

TMM, `lmFit` and `removeBatchEffect` are cheap here and grow with the cohort: on the Speedup
matrix (18,270 genes by 1,500 tumors) they take 10.3 s, 4.4 s and 4.5 s serial on the M3
([REFERENCE.md](REFERENCE.md#cross-platform)). `vst` and `glmQLFTest` were not timed at that
scale, so nothing yet shows a fork would pay for them. Each companion takes its original's
arguments and returns its original's object, so `voom`, `eBayes`, `topTable`, `glmQLFit` and
DESeq2 read the output unchanged. `voom(counts, design, block = b)` with `correlation` unset
runs a serial `duplicateCorrelation` inside `voom`, so run `duplicateCorrelation_parallel()`
first and pass its `consensus.correlation` to `voom` and to `lmFit_parallel()`;
`lmFit_parallel()` given `block` and `correlation = NULL` resolves it through
`duplicateCorrelation_parallel()` itself. Every function considered:
[REFERENCE.md](REFERENCE.md#why-these-five-and-not-the-rest).

## Install

The package needs `edgeR` and nothing else. Every other package below is optional, and
only for the companion you actually call.

```r
if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager")
BiocManager::install("edgeR")

if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes")
remotes::install_github("NamStacks/RNA-Parallel",
                        dependencies = c("Depends", "Imports"),
                        upgrade = "never")
```

Keep `upgrade = "never"`. Without it the installer offers to rebuild every outdated
package in your library, most of which have nothing to do with this one.

That is four packages on a clean library: `edgeR`, plus `limma`, `locfit` and `statmod`,
which `edgeR` and `limma` require themselves. `lattice` and the rest ship with R.

Only one companion asks for anything beyond that:

| Companion | Also install |
|---|---|
| `ComBat_seq_parallel()` | `sva` |
| the other four | nothing |

Backends work the same way. `"mclapply"` and `"serial"` need nothing; `"future"` needs `future`
and `future.apply`, `"BiocParallel"` needs `BiocParallel`, and `"foreach"` needs `foreach` and
`doParallel`. On macOS and Windows, install `ps` so the memory guard can read memory; Linux reads
`/proc` and needs nothing. Without a reading the guard leaves the worker count as it is. Where base
R has no `Sys.getppid()`, a forked worker reads its parent's process id from `/proc` on Linux and
through `ps` elsewhere, and exits once its master has died; off Linux without `ps`, orphaned
workers keep running.

## Use

Each companion takes its original's arguments in the same order with the same defaults, and adds
`workers`, `chunks`, `parallel_backend`, `backend` and `label`. All five in one pass:

```r
library(rnaparallel); library(edgeR); library(limma)

# raw counts, batch corrected
adjusted <- ComBat_seq_parallel(counts, batch = batch, group = NULL, workers = 8L)

# limma-voom differential expression
dge <- calcNormFactors_parallel(DGEList(adjusted), workers = 8L)
v   <- voom(dge, design)
fit <- lmFit_parallel(v, design, workers = 8L)
tt  <- topTable(eBayes(fit), coef = 2, number = Inf)

# blocked design, repeated measures on one subject
cor <- duplicateCorrelation_parallel(v, design, block = subject, workers = 8L)
fit <- lmFit_parallel(v, design, block = subject,
                      correlation = cor$consensus.correlation, workers = 8L)

# batch out of a log-expression matrix, for PCA and heatmaps
vis <- removeBatchEffect_parallel(v$E, batch = batch, design = design, workers = 8L)
```

Interface differences: `duplicateCorrelation_parallel` requires `block`, whereas the original
defaults it to `NULL`. `lmFit_parallel` and `removeBatchEffect_parallel` refuse
`method = "robust"` and `ndups >= 2`, which limma accepts; call limma directly for those.
`removeBatchEffect_parallel` declares `design = NULL`, current limma's default; left unset it is
not forwarded, so the installed limma's own default applies. `calcNormFactors_parallel` accepts a matrix, a `DGEList` or a
`SummarizedExperiment`, and refuses any other class that edgeR has its own method for; pass its
count matrix instead. See
[REFERENCE.md](REFERENCE.md#how-it-works) for why.

**Check it yourself:** [REFERENCE.md](REFERENCE.md#full-self-check) has the full comparison
against all five originals, no download required. At cohort scale, the same checks run as
[rendered reports](https://namstacks.github.io/RNA-Parallel/) on all three platforms, sourced from
[inst/examples/](inst/examples/); to rebuild one on your own machine, see
[Rendering the reports](#rendering-the-reports). [tests/](tests/testthat) covers every argument path, chunk
layout, backend, and dispatch count: 400+ assertions.

**See what's running:** on macOS and Linux every parallel dispatch draws a live `|====------|`
bar by default, with chunks done and an ETA, overwritten in place. It draws only in an interactive
session or on a terminal. A call that runs serially, every call on Windows, and every call whose
output goes to a log tick a running "N dispatched" count instead.
`options(combat.progress = FALSE)` silences both. `options(combat.timing = TRUE)` adds the real
engine per call once it finishes, `serial` vs `mclapply x6`, etc., and `label = "..."` names the
call in the progress and timing lines. The bar is drawn by a forked child, whose output may not
reach an RStudio Server console. To follow a logged run, or one on RStudio Server or Windows, set
`options(combat.progress.dir = "some/path")` and call
`rnaparallel_progress("some/path", watch = TRUE)` from a second session. See
[REFERENCE.md](REFERENCE.md#seeing-what-is-running).

**Memory:** forking a large matrix can exceed a machine's RAM even when the parent alone fits,
and on a box without swap the kernel SIGKILLs the process with no R error at all. The memory
guard degrades the worker count before that happens, using a live reading, once per companion
call, on by default; set `options(combat.mem.guard = FALSE)` to disable it. Inside a container or a
scheduler job it reads the cgroup memory limit, not the host's RAM.
`rnaparallel_set_mem_limit()` sets `R_MAX_VSIZE`, R's own allocation ceiling, to half the
machine's RAM (or of the cgroup memory limit on Linux, when lower) rounded down to a whole tier (8, 16, 32 GB and up; an exact Mb value below 8 GB), so
one process's overshoot becomes a catchable error instead of a silent kill. The limit is per
process: each forked worker inherits it, so it does not bound the total across workers. On macOS
it reads total RAM through `ps`. See [REFERENCE.md](REFERENCE.md#memory).

## Tuning

| knob | default | change it when |
|---|---|---|
| `workers` | `min(8, detectCores() - 2)`; inside a Slurm, SGE, PBS or LSF job or under a cgroup CPU quota, `min(8, allocation)`; capped at performance cores on Windows | rarely; going past your performance-core count can be slower |
| `chunks` | `workers` | only to cut peak memory per worker |
| `parallel_backend` | `getOption("combat.backend")`, else `"mclapply"`; on Windows `"future"` when a multi-worker future plan is active | you cannot fork, or a cluster is already running |

Full backend, nesting, and size-gate detail in [REFERENCE.md](REFERENCE.md#tuning-internals).

## Rendering the reports

The three reports in [inst/examples/](inst/examples/) are `RNA_Parallel.Rmd` (macOS),
`RNA_Parallel_linux.Rmd` and `RNA_Parallel_windows.Rmd`. Each one runs the full cohort-scale
check on the machine that renders it, so read this section before you start: a render takes
several hours and a missing prerequisite can stop it late.

**Every platform**

- **R and RStudio Desktop.** `R >= 4.1` is the package minimum. The published reports used R 4.4.2
  on macOS and on Ubuntu 20.04.6, and R 4.6.1 on Windows 11. RStudio also supplies pandoc, which
  `rmarkdown` needs to write the HTML.
- **Network.** The first render downloads about 6.8 GiB from the GDC (1,729 STAR count files for
  TCGA-HNSC, TCGA-LUAD and TCGA-LUSC) and queries the clinical table, so keep a live connection
  until that render ends. Later renders reuse the downloaded files. A report that saved a copy of
  the clinical table reuses it too; one that did not asks the GDC again, so check which you have
  before you render offline.
- **Disk.** Keep at least 15 GB free where the files land: your user cache folder
  (`tools::R_user_dir("rnaparallel", "cache")`), or the folder named in the `RNAPARALLEL_TCGA_DIR`
  environment variable. Knitr also writes a `*_cache` folder next to the notebook. Do not copy a
  `*_cache` folder from one machine to another: it holds the timings of the machine that made it,
  and a copy would put those numbers in your report.
- **Stay awake and plugged in.** Timings are wall-clock, so a sleep inside a timed arm lands in the
  report, and a laptop on battery can throttle. Plug in, close heavy programs and do not let the
  machine sleep until the render ends.
- **Check the install.** After the package is installed and R restarted, run these two lines in
  the R console. `BiocManager::valid()` must report `TRUE`, and the version must match `Version`
  in the repo's `DESCRIPTION` file:

  ```r
  BiocManager::valid()
  packageVersion("rnaparallel")
  ```

  If `valid()` lists out-of-date packages, run `BiocManager::install(ask = FALSE)`, restart R and
  run the two checks again.

- **Reinstalling is safe after a render.** `.Rinstignore` keeps the knitr caches, rendered HTML,
  `GDCdata`, `MANIFEST.txt`, `df.rds`, `results.rds` and GDC staging folders out of the installed
  library, so `R CMD INSTALL .` and `install.packages(<repo path>, repos = NULL, type = "source")`
  from a repo that has already rendered both stay small.

### macOS

1. Install R 4.4 or newer for your chip from [CRAN](https://cran.r-project.org/bin/macosx/) and
   [RStudio Desktop](https://posit.co/download/rstudio-desktop/). Binary packages need no
   compiler; install the Xcode command line tools (`xcode-select --install`) only if R offers to
   build a package from source. No RStudio: `brew install pandoc` instead.
2. Get the repo: `git clone https://github.com/NamStacks/RNA-Parallel`, or `git pull` inside an
   existing clone.
3. Open `inst/examples/RNA_Parallel.Rmd` in RStudio and run its `install` chunk once (it is
   `eval = FALSE`, so neither the script nor Knit runs it). Then, from the repo root in a
   terminal, run `R CMD INSTALL .` and restart R, then run the two checks above. Repeat after
   every `git pull`: a pull updates the source and not the installed package, and the report
   stops when the two versions differ.
4. Render with the script, or click Knit in RStudio:

   ```sh
   inst/examples/render_macos.sh
   ```

   The script keeps the Mac awake while it runs. For Knit, run `caffeinate -i` in a terminal
   first, or turn off automatic sleeping in System Settings.
5. The HTML lands next to the notebook: `inst/examples/RNA_Parallel.html`. Send that one file
   back, not `GDCdata`, `*_cache` or any `.rds`.

### Linux (Ubuntu 20.04 tested)

**One command.** Use a machine with 16 CPUs and nothing else running, because the report sweeps
2, 4, 8 and 16 workers. Connect with VS Code Remote-SSH, open a terminal and run:

```sh
git clone https://github.com/NamStacks/RNA-Parallel && cd RNA-Parallel
bash inst/examples/setup_linux.sh
```

In an existing clone, run `git pull` first. The script installs what is missing (it asks for
your sudo password only for apt), checks the install, and starts the render in the background, so
closing VS Code does not stop it. Watch it with `tail -f inst/examples/render_linux.log`. When the
render ends, the script commits `docs/linux.html` to the branch `linux-render` and pushes it. It
stops before the render if the machine has fewer than 16 CPUs, little free memory or other load;
`--yes` overrides that, and `--no-render` stops after the checks. The steps below do the same by
hand.

1. Install the system libraries first. Without the headers, `xml2`, `XML`, `openssl`, `curl`,
   `png` and `fs` fail to build, usually in the middle of the install:

   ```sh
   sudo apt-get update
   sudo apt-get install -y build-essential gfortran pkg-config curl \
     libcurl4-openssl-dev libssl-dev libxml2-dev libuv1-dev libpng-dev zlib1g-dev
   ```

   Ubuntu's own `r-base` is too old (3.6.3 on 20.04). Install R from the CRAN apt repository
   instead. The [CRAN page](https://cloud.r-project.org/bin/linux/ubuntu/) no longer lists 20.04,
   but the `focal-cran40` repository is still served and its newest R for 20.04 is 4.5.2 (the
   package needs 4.1 or newer). Add its signing key as that page describes, then the line:

   ```sh
   sudo add-apt-repository "deb https://cloud.r-project.org/bin/linux/ubuntu focal-cran40/"
   sudo apt-get update
   sudo apt-get install -y r-base r-base-dev
   ```

   RStudio is optional: the script needs only R and pandoc 2.8 or newer, and the `pandoc` in
   Ubuntu 20.04's archive is older than that. Take a pandoc `.deb` from
   [github.com/jgm/pandoc/releases](https://github.com/jgm/pandoc/releases), or the RStudio
   build that still supports 20.04: Desktop 2024.12.1-563
   (`download1.rstudio.org/electron/focal/amd64/rstudio-2024.12.1-563-amd64.deb`) or Server
   2025.05.1-513 (`download2.rstudio.org/server/focal/amd64/rstudio-server-2025.05.1-513-amd64.deb`).
   Newer RStudio builds are for Ubuntu 22.04 and later and will not install on 20.04.
2. Get the repo: `git clone https://github.com/NamStacks/RNA-Parallel`, or `git pull`.
3. Open `inst/examples/RNA_Parallel_linux.Rmd` and run its `install` chunk once. Then, from the
   repo root, run `R CMD INSTALL .`, restart R and run the two checks above. Repeat after every
   `git pull`.
4. Render with the script. Prefer it to Knit on Linux: it pins OpenBLAS to one thread before R
   starts. Knit also works when RhpcBLASctl (installed by the install chunk) can pin the BLAS;
   otherwise the report stops and prints the export command. Use `bash`, not `sh`.

   ```sh
   bash inst/examples/render_linux.sh
   ```

   The script blocks sleep through `systemd-inhibit` when that is installed; on a laptop, also
   turn off suspend in the power settings.
5. The HTML lands next to the notebook: `inst/examples/RNA_Parallel_linux.html`. Send that one
   file back.

### Windows 11

1. Install R 4.6 or newer (64-bit) from [CRAN](https://cran.r-project.org/bin/windows/base/) and
   [RStudio Desktop](https://posit.co/download/rstudio-desktop/). Rtools is not required: the
   package has no compiled code and the dependencies ship Windows binaries. Install Rtools45
   (CRAN lists it for R 4.5 and later) only if R offers to build a package from source and you
   cannot answer No.
2. Get the repo into a short folder outside OneDrive: install
   [Git for Windows](https://git-scm.com/download/win) and run
   `git clone https://github.com/NamStacks/RNA-Parallel C:\src\RNA-Parallel`, or download the ZIP
   from GitHub, unzip it and rename the folder that holds `DESCRIPTION` to `C:\src\RNA-Parallel`.
   Then, once, point the GDC download at a short path, because the default folder sits within a
   few characters of Windows's 260-character path limit: `setx RNAPARALLEL_TCGA_DIR C:\tcga`.
   Close and reopen RStudio, and open a new PowerShell window before you run the script, so both
   see the variable.
3. Open `inst/examples/RNA_Parallel_windows.Rmd` in RStudio and run its `install` chunk once.
   Then, in the R console, install the package from the repo, restart R and run the two checks
   above. Repeat after every `git pull`.

   ```r
   install.packages("C:/src/RNA-Parallel", repos = NULL, type = "source")
   ```

4. Plug in, set Settings > System > Power & battery > Power mode to Best performance, and
   render with the script. A stock Windows 11 has the execution policy `Restricted`, which
   refuses to run any `.ps1` file, so the command below sets the policy for this one process
   only. The script keeps the machine awake while it runs; for Knit, set sleep to Never first.
   If Windows Defender Firewall asks whether R or Rscript may talk on the network when the first
   parallel run starts, allow it on Private networks.

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\src\RNA-Parallel\inst\examples\render_windows.ps1
   ```

   Or open the notebook in RStudio and click Knit. Knit skips the BLAS thread pin, the keep-awake
   call and the battery warning; the BLAS pin matters only on OpenBLAS and MKL builds of R.
5. The HTML lands next to the notebook: `inst\examples\RNA_Parallel_windows.html`. Send that one
   file back.

## License

MIT for this companion, copyright NamStacks 2026, in [LICENSE](LICENSE). The original packages are
called at run time from your own installation and none of them is redistributed here: sva is
Artistic-2.0, limma and edgeR are GPL (>= 2). Two exceptions, both marked in source in
`R/helper_seq_parallel.R`, and both used only while the installed original still matches them:
a row-vectorized transcription of `sva::match_quantiles` (derived from Artistic-2.0 code by
Zhang, Parmigiani, Johnson), and `.tagwise_defaults_pinned`, three one-line default formulas
(`offset`, `span`, `AveLogCPM`) taken from edgeR 4.4.2's `estimateGLMTagwiseDisp.default`,
which the tagwise row split computes once for the whole matrix. On any upstream change the
companion detects the difference and calls the original instead.

## Citation

Cite the method you used and this companion. `citation("rnaparallel")` prints every entry below.

**ComBat-seq.** Zhang Y, Parmigiani G, Johnson WE (2020). ComBat-seq: batch effect adjustment for
RNA-seq count data. *NAR Genomics and Bioinformatics* 2(3), lqaa078.
doi:[10.1093/nargab/lqaa078](https://doi.org/10.1093/nargab/lqaa078).
Package: <https://bioconductor.org/packages/release/bioc/html/sva.html>.

**limma.** Ritchie ME, Phipson B, Wu D, Hu Y, Law CW, Shi W, Smyth GK (2015). limma powers
differential expression analyses for RNA-sequencing and microarray studies. *Nucleic Acids
Research* 43(7), e47. doi:[10.1093/nar/gkv007](https://doi.org/10.1093/nar/gkv007).
Package: <https://bioconductor.org/packages/release/bioc/html/limma.html>.

**edgeR.** Robinson MD, McCarthy DJ, Smyth GK (2010). edgeR: a Bioconductor package for
differential expression analysis of digital gene expression data. *Bioinformatics* 26(1),
139-140. doi:[10.1093/bioinformatics/btp616](https://doi.org/10.1093/bioinformatics/btp616).
Chen Y, Chen L, Lun ATL, Baldoni PL, Smyth GK (2025). edgeR v4: powerful differential analysis
of sequencing data with expanded functionality and improved support for small counts and larger
datasets. *Nucleic Acids Research* 53(2), gkaf018.
doi:[10.1093/nar/gkaf018](https://doi.org/10.1093/nar/gkaf018).
Package: <https://bioconductor.org/packages/release/bioc/html/edgeR.html>.

**This companion.** NamStacks (2026). *rnaparallel: Exact Parallel Companions for sva ComBat-Seq, edgeR and limma.*
<https://github.com/NamStacks/RNA-Parallel>.
