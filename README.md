<div align="center">

# RNA-Parallel

Parallel companions for five slow functions in sva, edgeR and limma. Each one runs the original unmodified and returns output `identical()` to it, bit for bit.

Same arguments, same defaults, same result, faster at cohort scale. An R package for macOS, Linux and Windows.

[![version](https://img.shields.io/badge/version-0.5.1-blue)](NEWS.md)
[![R](https://img.shields.io/badge/R-%E2%89%A5%204.1-blue)](DESCRIPTION)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE.md)

[Install](#install) | [Use](#use) | [Speedup](#speedup) | [Reports](#rendering-the-reports) | [Report a problem](https://github.com/NamStacks/RNA-Parallel/issues)

</div>

## What it does

- **Five companions.** `ComBat_seq_parallel()`, `calcNormFactors_parallel()`, `lmFit_parallel()`, `duplicateCorrelation_parallel()` and `removeBatchEffect_parallel()` take their original's arguments and defaults, plus `workers`, `chunks`, `parallel_backend`, `backend` and `label`.
- **The original still runs.** Only its slow internal steps are swapped for parallel versions, in a child of its own environment. Output is checked with `identical()`, not a tolerance. The two exceptions are in [License](#license).
- **Chosen to pay off.** Each step is slow at cohort scale, has no worker argument of its own, and splits without changing the answer. Every function considered is in [REFERENCE.md](REFERENCE.md#why-these-five-and-not-the-rest).
- **A memory guard.** Before forking, it lowers the worker count so a large matrix does not exhaust RAM and get the process killed without an R error.
- **Live progress.** On macOS and Linux every parallel dispatch draws a `|====------|` bar with chunks done and an ETA.

## Install

The package needs `edgeR` and nothing else. Every other package is optional, and only for the companion you call.

```r
if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager")
BiocManager::install("edgeR")

if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes")
remotes::install_github("NamStacks/RNA-Parallel",
                        dependencies = c("Depends", "Imports"),
                        upgrade = "never")
```

Keep `upgrade = "never"`. Without it the installer offers to rebuild every outdated package in your library.

That is four packages on a clean library: `edgeR`, plus `limma`, `locfit` and `statmod`, which `edgeR` and `limma` require. `ComBat_seq_parallel()` also needs `sva`.

Backends work the same way. `"mclapply"` and `"serial"` need nothing, `"future"` needs `future` and `future.apply`, `"BiocParallel"` needs `BiocParallel`, and `"foreach"` needs `foreach` and `doParallel`. On macOS and Windows, install `ps` so the memory guard can read memory. Linux reads `/proc`.

## Use

All five in one pass:

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

Differences from the originals:

- `duplicateCorrelation_parallel()` requires `block`, where the original defaults it to `NULL`.
- `lmFit_parallel()` and `removeBatchEffect_parallel()` refuse `method = "robust"` and `ndups >= 2`. Call limma directly for those.
- `removeBatchEffect_parallel()` declares `design = NULL`, current limma's default. Left unset, it is not forwarded.
- `calcNormFactors_parallel()` accepts a matrix, a `DGEList` or a `SummarizedExperiment`, and refuses any other class edgeR has its own method for. Pass its count matrix instead.
- `voom(counts, design, block = b)` with `correlation` unset runs a serial `duplicateCorrelation()`. Run `duplicateCorrelation_parallel()` first and pass its `consensus.correlation` to `voom()` and `lmFit_parallel()`. Given `block` and `correlation = NULL`, `lmFit_parallel()` resolves it itself.

### Settings

| knob | default | change it when |
|---|---|---|
| `workers` | `min(8, detectCores() - 2)`; inside a Slurm, SGE, PBS or LSF job or under a cgroup CPU quota, `min(8, allocation)`; capped at performance cores on Windows | rarely, because going past your performance-core count can be slower |
| `chunks` | `workers` | you need to cut peak memory per worker |
| `parallel_backend` | `getOption("combat.backend")`, else `"mclapply"`; on Windows `"future"` when a multi-worker future plan is active | you cannot fork, or a cluster is already running |

- `options(combat.progress = FALSE)` silences the bar and the "N dispatched" count that stands in for it on Windows, in a log, or on a serial call.
- `options(combat.timing = TRUE)` reports the engine each call used, such as `mclapply x6`. `label = "..."` names a call in both outputs.
- `options(combat.progress.dir = "some/path")` plus `rnaparallel_progress("some/path", watch = TRUE)` in a second session follows a logged run, or one on RStudio Server or Windows.
- `options(combat.mem.guard = FALSE)` turns the memory guard off. `rnaparallel_set_mem_limit()` sets R's own allocation ceiling to half the RAM, rounded down to a whole tier, so one process's overshoot becomes a catchable error. The limit is per process, so it does not bound the total across forked workers.

Backends, nesting, size gates and memory detail are in [REFERENCE.md](REFERENCE.md#tuning-internals).

## Speedup

TCGA, 18,270 genes by 1,500 tumors, every arm `identical()` to the original. macOS: Mac mini M6, 6 fast + 6 efficiency cores. Linux: 2x Xeon, 16 cores. Windows: Ultra 9 185H, 6P+10E.

| companion | runs | macOS | Linux | Windows |
|---|---|---:|---:|---:|
| `ComBat_seq_parallel()` | `sva::ComBat_seq` | 5.33x @ 8w | **9.34x @ 16w** | 3.57x @ 6w |
| `calcNormFactors_parallel()` | `edgeR::normLibSizes` | **6.54x @ 8w** | 4.12x @ 8w | 1.74x @ 2w |
| `lmFit_parallel()` | `limma::lmFit` | 1.84x @ 8w | **3.37x @ 16w** | 1.10x @ 4w |
| `duplicateCorrelation_parallel()` | `limma::duplicateCorrelation` | 3.90x @ 6w | **7.22x @ 16w** | 2.07x @ 4w |
| `removeBatchEffect_parallel()` | `limma::removeBatchEffect` | **2.94x @ 8w** | 1.39x @ 8w | 0.90x @ 2w |

Bold marks the fastest platform per row. Windows has no `fork()`, so each worker is a full copied process, and only 6 of its 16 cores are performance cores. That caps its scaling, and `lmFit` and `removeBatchEffect` there are parity, not speedups. Every wall-clock number is in [REFERENCE.md](REFERENCE.md#cross-platform).

The same checks run as rendered reports on all three platforms: [macOS](https://namstacks.github.io/RNA-Parallel/), [Linux](https://namstacks.github.io/RNA-Parallel/linux.html) and [Windows](https://namstacks.github.io/RNA-Parallel/windows.html). The macOS report was rendered with rnaparallel 0.5.1, and Linux and Windows with 0.5.0 until they are re-rendered. [REFERENCE.md](REFERENCE.md#full-self-check) has the full comparison against all five originals, and [tests/](tests/testthat) covers every argument path, chunk layout, backend and dispatch count with 400+ assertions.

## Rendering the reports

The reports in [inst/examples/](inst/examples/) are `RNA_Parallel.Rmd` (macOS), `RNA_Parallel_linux.Rmd` and `RNA_Parallel_windows.Rmd`. Each runs the full cohort-scale check on the machine that renders it, and a render takes several hours.

- **Software.** R 4.1 or newer is the package minimum. The published reports used R 4.6.1 on macOS and Windows 11, and R 4.4.2 on Ubuntu 20.04.6. `rmarkdown` needs pandoc, which RStudio Desktop supplies.
- **Network.** The first render downloads about 6.8 GiB from the GDC (1,729 STAR count files for TCGA-HNSC, TCGA-LUAD and TCGA-LUSC) and queries the clinical table. Later renders reuse the files.
- **Disk.** Keep 15 GB free in `tools::R_user_dir("rnaparallel", "cache")`, or in the folder named by the `RNAPARALLEL_TCGA_DIR` environment variable. Knitr also writes a `*_cache` folder next to the notebook. Never copy that folder between machines, because it holds the timings of the machine that made it.
- **Power.** Timings are wall-clock. Plug in, close heavy programs and keep the machine awake until the render ends.
- **Check the install.** After installing the package and restarting R, `BiocManager::valid()` must report `TRUE` and `packageVersion("rnaparallel")` must equal `Version` in `DESCRIPTION`. If `valid()` lists out-of-date packages, run `BiocManager::install(ask = FALSE)` and check again. Repeat both checks after every `git pull`, because a pull updates the source and not the installed package, and the report stops when the versions differ.
- **Reinstalling is safe.** `.Rinstignore` keeps the caches, rendered HTML and GDC staging folders out of the installed library.

<details>
<summary>macOS</summary>

1. Install R 4.4 or newer from [CRAN](https://cran.r-project.org/bin/macosx/) and [RStudio Desktop](https://posit.co/download/rstudio-desktop/). Install the Xcode command line tools (`xcode-select --install`) only if R offers to build a package from source. Without RStudio, run `brew install pandoc`.
2. Clone the repo, or `git pull` in an existing clone.
3. Open `inst/examples/RNA_Parallel.Rmd` in RStudio and run its `install` chunk once. Then run `R CMD INSTALL .` from the repo root, restart R and run the install checks above.
4. Render with the script, or click Knit. For Knit, run `caffeinate -i` in a terminal first.

   ```sh
   inst/examples/render_macos.sh
   ```

5. Send back `inst/examples/RNA_Parallel.html` alone, not `GDCdata`, `*_cache` or any `.rds`.

</details>

<details>
<summary>Linux (Ubuntu 20.04 tested)</summary>

**One command.** Use a machine with 16 CPUs and nothing else running, because the report sweeps 2, 4, 8 and 16 workers. Connect with VS Code Remote-SSH, open a terminal and run:

```sh
git clone https://github.com/NamStacks/RNA-Parallel && cd RNA-Parallel
bash inst/examples/setup_linux.sh
```

The script installs what is missing (it asks for your sudo password only for apt), checks the install and starts the render in the background, so closing VS Code does not stop it. Follow it with `tail -f inst/examples/render_linux.log`. When the render ends, the script commits `docs/linux.html` to the branch `linux-render` and pushes it. It stops first if the machine has fewer than 16 CPUs, little free memory or other load. `--yes` overrides that, and `--no-render` stops after the checks.

By hand:

1. Install the system libraries before R packages, or `xml2`, `XML`, `openssl`, `curl`, `png` and `fs` fail to build:

   ```sh
   sudo apt-get update
   sudo apt-get install -y build-essential gfortran pkg-config curl \
     libcurl4-openssl-dev libssl-dev libxml2-dev libuv1-dev libpng-dev zlib1g-dev
   ```

   Ubuntu's `r-base` is 3.6.3 on 20.04, which is too old. The `focal-cran40` repository is still served and carries R 4.5.2. Add its signing key as the [CRAN page](https://cloud.r-project.org/bin/linux/ubuntu/) describes, then:

   ```sh
   sudo add-apt-repository "deb https://cloud.r-project.org/bin/linux/ubuntu focal-cran40/"
   sudo apt-get update
   sudo apt-get install -y r-base r-base-dev
   ```

   RStudio is optional. The script needs R and pandoc 2.8 or newer, and 20.04's own `pandoc` is older. Take a `.deb` from [github.com/jgm/pandoc/releases](https://github.com/jgm/pandoc/releases), or the last RStudio builds that support 20.04: Desktop 2024.12.1-563 or Server 2025.05.1-513.
2. Open `inst/examples/RNA_Parallel_linux.Rmd`, run its `install` chunk once, then run `R CMD INSTALL .` from the repo root, restart R and run the install checks above.
3. Render with the script, not Knit, because it pins OpenBLAS to one thread before R starts. Use `bash`, not `sh`. It blocks sleep through `systemd-inhibit` when that is installed.

   ```sh
   bash inst/examples/render_linux.sh
   ```

4. Send back `inst/examples/RNA_Parallel_linux.html` alone.

</details>

<details>
<summary>Windows 11</summary>

**One command.** Clone into a short folder outside OneDrive, open a plain PowerShell window in it and run the script. It checks the machine, installs R and pandoc when missing, installs the packages, starts the render in a hidden window that survives closing yours, and pushes `docs/windows.html` to the branch `windows-render` when it ends. Plug in the charger and set Power mode to Best performance first.

```powershell
git clone https://github.com/NamStacks/RNA-Parallel C:\src\RNA-Parallel
cd C:\src\RNA-Parallel
powershell.exe -NoProfile -ExecutionPolicy Bypass -File inst\examples\setup_windows.ps1
```

Add `-NoRender` to set up and check only. Follow the render with `Get-Content inst\examples\render_windows.log -Wait`. The log ends in PUBLISHED, PUSH FAILED, NOT PUBLISHED, REVIEW NEEDED or RENDER FAILED.

By hand:

1. Install R 4.6 or newer (64-bit) from [CRAN](https://cran.r-project.org/bin/windows/base/) and [RStudio Desktop](https://posit.co/download/rstudio-desktop/). Rtools is not required, because the package has no compiled code and the dependencies ship Windows binaries.
2. Clone into `C:\src\RNA-Parallel` with [Git for Windows](https://git-scm.com/download/win), or unzip the GitHub ZIP there. Run `setx RNAPARALLEL_TCGA_DIR C:\tcga` once, because the default download folder sits within a few characters of Windows's 260-character path limit. Reopen RStudio and PowerShell so both see it.
3. Open `inst/examples/RNA_Parallel_windows.Rmd` in RStudio and run its `install` chunk once. Then install the package from the repo, restart R and run the install checks above.

   ```r
   install.packages("C:/src/RNA-Parallel", repos = NULL, type = "source")
   ```

4. Set Settings > System > Power & battery > Power mode to Best performance and render. A stock Windows 11 refuses `.ps1` files, so the command sets the execution policy for this one process. If Windows Defender Firewall asks about R or Rscript when the first parallel run starts, allow Private networks.

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\src\RNA-Parallel\inst\examples\render_windows.ps1
   ```

   Knit also works, but skips the BLAS pin, the keep-awake call and the battery warning.
5. Send back `inst\examples\RNA_Parallel_windows.html` alone.

</details>

## If something goes wrong

| What you see | What to do |
|---|---|
| R exits with no error while workers run | The forked workers used more RAM than the machine has. Leave the memory guard on, lower `workers` or `chunks`, and call `rnaparallel_set_mem_limit()`. |
| A warning says the worker count was lowered | The memory guard cut it to fit RAM. Free memory or lower `chunks`, or set `options(combat.mem.guard = FALSE)` if you accept the risk. |
| No progress bar on RStudio Server or in a log | Set `options(combat.progress.dir = "some/path")` and run `rnaparallel_progress("some/path", watch = TRUE)` from a second session. |
| Windows speedups are small | Windows cannot fork, so each worker is a full process fed over a socket. Use the `"future"` backend and keep `workers` at or below the performance-core count. |
| A render stops with a message about the version | The installed `rnaparallel` is older than `DESCRIPTION`. Run `R CMD INSTALL .`, restart R and render again. |
| A render stops because `duplicateCorrelation` ran under 1.5x at the widest arm | Power, throttling or background load kept the workers from running wide. Plug in, close other work, delete the `*_cache` folder and render again. |
| You need `method = "robust"` or `ndups >= 2` | The companions refuse both. Call `limma::lmFit()` or `limma::removeBatchEffect()` directly. |

## License

MIT for this companion, copyright NamStacks 2026, in [LICENSE](LICENSE). The original packages are called at run time from your own installation and none of them is redistributed here. sva is Artistic-2.0, and limma and edgeR are GPL (>= 2).

Two pieces are transcribed and marked in `R/helper_seq_parallel.R`, and each is used only while the installed original still matches it. One is a row-vectorized transcription of `sva::match_quantiles`, derived from Artistic-2.0 code by Zhang, Parmigiani and Johnson. The other is `.tagwise_defaults_pinned`, three one-line default formulas (`offset`, `span`, `AveLogCPM`) from edgeR 4.4.2's `estimateGLMTagwiseDisp.default`, which the tagwise row split computes once for the whole matrix. On any upstream change the companion detects the difference and calls the original instead.

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
