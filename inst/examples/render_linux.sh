#!/usr/bin/env bash
# Render the Linux verification report for rnaparallel.
#
# OpenBLAS reads its thread count when the library is loaded, so OPENBLAS_NUM_THREADS
# has to be in the environment BEFORE R starts. Calling Sys.setenv() inside the R
# session does not reach a pool that is already open (measured on this machine: 0.97x,
# i.e. none). Without this, every forked worker opens its own BLAS thread pool and the box
# is oversubscribed. The notebook itself can pin through RhpcBLASctl when that package is
# installed, and stops with the export command when it cannot.
#
#   ./render_linux.sh
#   ./render_linux.sh RNA_Parallel_linux.Rmd ../../docs/linux.html
#
# Relative IN and OUT arguments are taken from the directory you run this in.
#
# Needs R 4.1 or newer and pandoc 2.8 or newer. On Ubuntu 20.04 the apt pandoc is 2.5, so use
# the copy bundled with RStudio or a .deb from https://github.com/jgm/pandoc/releases. The last
# RStudio builds that install on 20.04 are:
#   Desktop: https://download1.rstudio.org/electron/focal/amd64/rstudio-2024.12.1-563-amd64.deb
#   Server:  https://download2.rstudio.org/server/focal/amd64/rstudio-server-2025.05.1-513-amd64.deb
# Newer builds are for newer Ubuntu releases and fail to install on 20.04. RStudio is optional:
# any pandoc on PATH works.

# sh and dash have no pipefail, so hand the script to bash instead of failing at set -o pipefail.
if [ -z "${BASH_VERSION:-}" ]; then
  command -v bash >/dev/null 2>&1 || { echo "render_linux.sh needs bash and bash was not found." >&2; exit 1; }
  exec bash "$0" "$@"
fi
set -euo pipefail

CALLER="$PWD"

# Keep the machine awake, because an idle suspend would add a sleep gap to whichever timed arm it lands in.
if [ -z "${RNAPARALLEL_AWAKE:-}" ]; then
  if command -v systemd-inhibit >/dev/null 2>&1 \
     && systemd-inhibit --what=idle:sleep --who=rnaparallel --why=probe true >/dev/null 2>&1; then
    export RNAPARALLEL_AWAKE=1
    exec systemd-inhibit --what=idle:sleep --who=rnaparallel --why="rnaparallel render" bash "$0" "$@"
  fi
  echo "systemd-inhibit is not usable here. Turn off suspend and screen lock by hand before a long render." >&2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$CALLER/$1" ;; esac; }
cd "$SCRIPT_DIR"

if [ -n "${1:-}" ]; then IN="$(abs "$1")"; else IN="$SCRIPT_DIR/RNA_Parallel_linux.Rmd"; fi
if [ -n "${2:-}" ]; then OUT="$(abs "$2")"; else OUT="${IN%.Rmd}.html"; fi

export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1          # harmless if MKL is absent
export VECLIB_MAXIMUM_THREADS=1   # harmless on Linux; keeps the script portable

# Pandoc runs and fails at the START of render(), before any computation, so this guard is
# about a clear message, not about saving the long run. RStudio Desktop (Electron) keeps pandoc
# under resources/app, older Desktop and Server builds under bin; Quarto 1.4 and newer add an
# architecture subfolder.
ARCH="$(uname -m)"
if [ -z "${RSTUDIO_PANDOC:-}" ]; then
  for b in /usr/lib/rstudio/resources/app/quarto/bin/tools \
           /usr/lib/rstudio/resources/app/bin/quarto/bin/tools \
           /usr/lib/rstudio/resources/app/bin/pandoc \
           /usr/lib/rstudio/bin/quarto/bin/tools \
           /usr/lib/rstudio/bin/pandoc \
           /usr/lib/rstudio-server/bin/quarto/bin/tools \
           /usr/lib/rstudio-server/bin/pandoc \
           /opt/quarto/bin/tools \
           "$HOME/opt/pandoc"; do
    for d in "$b/$ARCH" "$b"; do
      if [ -x "$d/pandoc" ] && "$d/pandoc" --version >/dev/null 2>&1; then
        export RSTUDIO_PANDOC="$d"
        break 2
      fi
    done
  done
fi
# A machine with no RStudio at all is the other common case, and there pandoc is usually
# just on PATH. Without this the guard below would refuse a machine that can in fact render.
if [ -z "${RSTUDIO_PANDOC:-}" ]; then
  p="$(command -v pandoc || true)"
  if [ -n "$p" ] && "$p" --version >/dev/null 2>&1; then export RSTUDIO_PANDOC="$(dirname "$p")"; fi
fi
echo "RSTUDIO_PANDOC=${RSTUDIO_PANDOC:-<not found>}"
echo "OPENBLAS_NUM_THREADS=$OPENBLAS_NUM_THREADS"

if [ -z "${RSTUDIO_PANDOC:-}" ] || [ ! -x "${RSTUDIO_PANDOC}/pandoc" ] \
   || ! "${RSTUDIO_PANDOC}/pandoc" --version >/dev/null 2>&1; then
  echo "pandoc not found, or it does not run. rmarkdown needs it to write the HTML." >&2
  echo "Install pandoc 2.8 or newer (https://github.com/jgm/pandoc/releases), or point" >&2
  echo "RSTUDIO_PANDOC at a directory holding a working copy." >&2
  exit 1
fi

# rmarkdown 2.32 and newer refuse pandoc below 2.8; older rmarkdown accepts it. Warn and let
# rmarkdown decide, so a working older pair is not rejected here.
pv="$("${RSTUDIO_PANDOC}/pandoc" --version | sed -n 1p | awk '{print $2}')"
echo "pandoc ${pv}"
if ! printf '%s' "$pv" | awk -F. '{ exit !($1 > 2 || ($1 == 2 && $2 >= 8)) }'; then
  echo "warning: pandoc ${pv} is older than 2.8, which rmarkdown 2.32 and newer refuse at the" >&2
  echo "start of the render. The apt pandoc on Ubuntu 20.04 is 2.5." >&2
fi

command -v Rscript >/dev/null 2>&1 || { echo "Rscript not found on PATH." >&2; exit 1; }

# Check the packages in a separate process, so a missing one stops here and not in the
# middle of the render, and the benchmark session itself stays clean.
Rscript -e 'need <- c("rmarkdown", "knitr", "rnaparallel", "sva", "edgeR", "limma", "SummarizedExperiment", "ggplot2", "callr", "gtsummary", "ggrepel", "patchwork", "circlize", "RColorBrewer", "ComplexHeatmap", "TCGAbiolinks"); miss <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]; if (length(miss)) { message("missing or unloadable R packages: ", paste(miss, collapse = ", "), ". Run the install chunk in section A of RNA_Parallel_linux.Rmd, after the apt libraries listed above it."); quit(status = 1) }'

exec Rscript -e "a <- commandArgs(TRUE); rmarkdown::render(a[1], output_file = a[2], quiet = FALSE)" "${IN}" "${OUT}"
