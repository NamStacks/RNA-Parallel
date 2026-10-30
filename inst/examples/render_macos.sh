#!/usr/bin/env bash
# Render the macOS verification report for rnaparallel.
#
# The published macOS report ran on R's single-threaded reference BLAS, which has no thread
# pool to pin. What this guards is the other case: Accelerate (vecLib) or a user-installed
# OpenBLAS or MKL build of R, where every forked worker would open its own
# thread pool on top of the fork and oversubscribe the machine. A BLAS reads its thread count
# when the library LOADS, so these have to be in the environment before R starts.
# Sys.setenv() inside the session is too late, which is why render_linux.sh exports rather
# than sets. All four are harmless where the library they name is absent.
#
# A render is long. The script re-runs itself under caffeinate -i so an idle Mac does not
# sleep mid-render, which would count the sleep as seconds in a timing table.
#
# The report stops with a message if the memory guard lowered any worker count. The divergence
# setting in its libs chunk is an assumption, so run memory_pressure in another terminal during
# the first 8-worker TCGA arm and stop the render yourself if the pressure level reaches critical.
#
# Relative IN and OUT paths are resolved against the directory you ran the script from. A
# relative IN that exists only next to this script is also accepted.
#
#   ./render_macos.sh
#   ./render_macos.sh RNA_Parallel.Rmd ../../docs/index.html
set -euo pipefail

# Gate: caffeinate -i holds the idle-sleep assertion only while its child runs, and
# RNAP_CAFFEINATED stops the re-exec from looping.
if [ -z "${RNAP_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null 2>&1; then
  RNAP_CAFFEINATED=1 exec caffeinate -i bash "$0" "$@"
fi

CALLER_DIR="$PWD"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export VECLIB_MAXIMUM_THREADS=1   # Accelerate
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

# pandoc ships inside RStudio.app and is not on PATH in a plain shell. Current RStudio keeps it
# in the bundled Quarto, under an architecture folder (tools/aarch64 or tools/x86_64); older
# builds keep it directly in tools. A machine with no RStudio at all is the other common case,
# so Homebrew, an active conda environment and PATH all count. Set RSTUDIO_PANDOC yourself to
# override the search.
case "$(uname -m)" in arm64) arch=aarch64 ;; *) arch=x86_64 ;; esac
pandoc_dirs=()
for app in "/Applications/RStudio.app" "$HOME/Applications/RStudio.app" \
           "/Applications/RAI-Studio.app"; do
  for t in "Contents/Resources/app/quarto/bin/tools/$arch" \
           "Contents/Resources/app/quarto/bin/tools" \
           "Contents/Resources/app/bin/quarto/bin/tools/$arch" \
           "Contents/Resources/app/bin/quarto/bin/tools" \
           "Contents/MacOS/quarto/bin/tools/$arch" \
           "Contents/MacOS/quarto/bin/tools" \
           "Contents/MacOS/pandoc"; do
    pandoc_dirs+=("$app/$t")
  done
done
pandoc_dirs+=("/Applications/quarto/bin/tools/$arch" "/opt/homebrew/bin" "/usr/local/bin"
              "$HOME/.local/bin" "${CONDA_PREFIX:-}/bin")

# A pandoc counts only if it runs: a wrong-architecture or damaged binary is skipped.
pandoc_ok() { [ -n "$1" ] && [ -x "$1/pandoc" ] && "$1/pandoc" --version >/dev/null 2>&1; }

if [ -n "${RSTUDIO_PANDOC:-}" ] && ! pandoc_ok "$RSTUDIO_PANDOC"; then
  echo "RSTUDIO_PANDOC=$RSTUDIO_PANDOC does not hold a pandoc that runs; searching instead." >&2
  unset RSTUDIO_PANDOC
fi
if [ -z "${RSTUDIO_PANDOC:-}" ]; then
  for d in "${pandoc_dirs[@]}"; do
    if pandoc_ok "$d"; then export RSTUDIO_PANDOC="$d"; break; fi
  done
fi
if [ -z "${RSTUDIO_PANDOC:-}" ]; then
  p="$(command -v pandoc || true)"
  if [ -n "$p" ] && pandoc_ok "$(dirname "$p")"; then export RSTUDIO_PANDOC="$(dirname "$p")"; fi
fi

# Fail here rather than after the render. Pandoc is the LAST step, so without this the report
# computes the whole cohort (an hour or more) and then dies with nothing written.
if [ -z "${RSTUDIO_PANDOC:-}" ]; then
  echo "pandoc not found, or none that runs. rmarkdown needs it to write the HTML, and it is the" >&2
  echo "last step of a render that takes over an hour, so this stops now rather than at the end." >&2
  echo "Install it (brew install pandoc) or point RSTUDIO_PANDOC at a directory holding it." >&2
  exit 1
fi

IN="${1:-$SCRIPT_DIR/RNA_Parallel.Rmd}"
case "$IN" in
  /*) ;;
  *) if [ -e "$CALLER_DIR/$IN" ]; then IN="$CALLER_DIR/$IN"; else IN="$SCRIPT_DIR/$IN"; fi ;;
esac
OUT="${2:-${IN%.Rmd}.html}"
case "$OUT" in /*) ;; *) OUT="$CALLER_DIR/$OUT" ;; esac

echo "RSTUDIO_PANDOC        = ${RSTUDIO_PANDOC:-<not found>}"
echo "VECLIB_MAXIMUM_THREADS= $VECLIB_MAXIMUM_THREADS"
echo "core tiers            = $(for i in $(seq 0 $(( $(sysctl -n hw.nperflevels 2>/dev/null || echo 1) - 1 ))); do printf '%s %s; ' "$(sysctl -n hw.perflevel$i.physicalcpu 2>/dev/null)" "$(sysctl -n hw.perflevel$i.name 2>/dev/null)"; done)"
echo "rendering $IN -> $OUT"

exec Rscript -e "a <- commandArgs(TRUE); rmarkdown::render(a[1], output_file = a[2], quiet = FALSE)" "${IN}" "${OUT}"
