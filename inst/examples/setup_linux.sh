#!/usr/bin/env bash
# One command to set up an Ubuntu machine and render the Linux report.
#
# From the repo root, over SSH or in a local terminal:
#
#   bash inst/examples/setup_linux.sh            # set up, check, start the render, publish
#   bash inst/examples/setup_linux.sh --no-render  # set up and check only
#   bash inst/examples/setup_linux.sh --yes      # do not stop on the hardware warnings
#
# What it does, in order. Each step is skipped when the machine already has what it needs.
#   1. Prints the hardware and stops if it does not match the report (16 CPUs, idle machine).
#   2. apt: system libraries, and R from the CRAN apt repository when R is missing or older
#      than 4.1. This is the only step that uses sudo.
#   3. pandoc 2.8 or newer into ~/opt/pandoc when none is found. No sudo.
#   4. R packages into your user library, then this checkout with R CMD INSTALL.
#   5. Checks that the installed version matches DESCRIPTION, and warns when BiocManager::valid() is not TRUE.
#   6. Starts render_linux.sh in the background with setsid and nohup, so closing VS Code or losing the
#      SSH link does not stop it. The log is inst/examples/render_linux.log.
#   7. When the render ends, copies the HTML to docs/linux.html, commits it on the branch
#      linux-render as NamStacks and pushes that branch. It commits nothing if the report shows
#      this account's home path or the host name. If the push fails, the commit stays local and
#      the log says so; that is expected when VS Code was closed, because its git login went too.
#
# Watch it with:  tail -f inst/examples/render_linux.log

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

RENDER=1
YES=0
for a in "$@"; do
  case "$a" in
    --no-render) RENDER=0 ;;
    --yes) YES=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

EX_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$EX_DIR/../.." && pwd)"
LOG="$EX_DIR/render_linux.log"
WANT_CORES=16
say() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ -f "$REPO/DESCRIPTION" ] || die "run this from a clone of NamStacks/RNA-Parallel"
command -v apt-get >/dev/null 2>&1 || die "this script is for Ubuntu or Debian (apt-get not found)"

say "1. Hardware"
CORES="$(nproc)"
MEM_GB="$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)"
AVAIL_GB="$(awk '/MemAvailable/ {printf "%d", $2/1048576}' /proc/meminfo)"
LOAD="$(cut -d' ' -f1 /proc/loadavg)"
. /etc/os-release
echo "$PRETTY_NAME, $CORES CPUs, ${MEM_GB} GB RAM (${AVAIL_GB} GB free), load ${LOAD}"
warn=0
if [ "$CORES" -lt "$WANT_CORES" ]; then
  echo "warning: the report sweeps 2, 4, 8 and 16 workers; this machine has $CORES CPUs." >&2; warn=1
fi
if [ "$AVAIL_GB" -lt 12 ]; then
  echo "warning: only ${AVAIL_GB} GB RAM is free; the memory guard may cap the sweep." >&2; warn=1
fi
if awk -v l="$LOAD" 'BEGIN { exit !(l > 1.5) }'; then
  echo "warning: load is ${LOAD}. Other jobs running now add noise to every timing." >&2; warn=1
fi
if [ "$warn" -eq 1 ] && [ "$YES" -eq 0 ] && [ "$RENDER" -eq 1 ]; then
  die "the timings would not be a fair Linux report here. Fix the warnings above, or run again with --yes to render anyway."
fi

say "2. System libraries and R"
PKGS="build-essential gfortran pkg-config curl ca-certificates git libcurl4-openssl-dev libssl-dev libxml2-dev libuv1-dev libpng-dev zlib1g-dev libfontconfig1-dev libfreetype6-dev libharfbuzz-dev libfribidi-dev"
missing=""
for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
r_ok=0
if command -v Rscript >/dev/null 2>&1 \
   && Rscript -e 'quit(status = as.integer(getRversion() < "4.1"))' >/dev/null 2>&1; then
  r_ok=1
fi
if [ -n "$missing" ] || [ "$r_ok" -eq 0 ]; then
  echo "sudo is needed for:${missing}$([ "$r_ok" -eq 0 ] && echo ' r-base r-base-dev')"
  sudo apt-get update
  [ -z "$missing" ] || sudo apt-get install -y $missing
  if [ "$r_ok" -eq 0 ]; then
    # Ubuntu's own r-base is too old on 20.04, so take R from CRAN's apt repository for this release.
    sudo install -d /etc/apt/keyrings
    curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
      | sudo tee /etc/apt/keyrings/cran_ubuntu_key.asc >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/cran_ubuntu_key.asc] https://cloud.r-project.org/bin/linux/ubuntu ${VERSION_CODENAME}-cran40/" \
      | sudo tee /etc/apt/sources.list.d/cran-r.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y r-base r-base-dev
  fi
fi
Rscript -e 'cat(R.version.string, "\n")'

say "3. pandoc"
have_pandoc() {
  local p="$1"
  [ -x "$p" ] && "$p" --version >/dev/null 2>&1 \
    && "$p" --version | sed -n 1p | awk '{print $2}' | awk -F. '{ exit !($1 > 2 || ($1 == 2 && $2 >= 8)) }'
}
PANDOC=""
for p in "$(command -v pandoc || true)" "$HOME/opt/pandoc/pandoc" /usr/lib/rstudio-server/bin/quarto/bin/tools/pandoc \
         /usr/lib/rstudio-server/bin/pandoc/pandoc /usr/lib/rstudio/resources/app/bin/quarto/bin/tools/pandoc; do
  if [ -n "$p" ] && have_pandoc "$p"; then PANDOC="$p"; break; fi
done
if [ -z "$PANDOC" ]; then
  PV=3.1.11.1
  case "$(uname -m)" in x86_64) PA=amd64 ;; aarch64|arm64) PA=arm64 ;; *) die "no pandoc build for $(uname -m)" ;; esac
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/jgm/pandoc/releases/download/${PV}/pandoc-${PV}-linux-${PA}.tar.gz" | tar -xz -C "$tmp"
  mkdir -p "$HOME/opt/pandoc"
  mv "$tmp/pandoc-${PV}/bin/pandoc" "$HOME/opt/pandoc/pandoc"
  rm -rf "$tmp"
  PANDOC="$HOME/opt/pandoc/pandoc"
fi
export RSTUDIO_PANDOC="$(dirname "$PANDOC")"
"$PANDOC" --version | sed -n 1p

say "4. R packages"
# R adds the user library to .libPaths() only when the folder exists at startup, so make it first.
Rscript -e 'dir.create(Sys.getenv("R_LIBS_USER"), recursive = TRUE, showWarnings = FALSE)'
# Posit Package Manager serves prebuilt Ubuntu binaries, which turns hours of compiling into minutes.
cat > "$EX_DIR/.setup_linux_install.R" <<EOF
codename <- "${VERSION_CODENAME}"
ppm <- sprintf("https://packagemanager.posit.co/cran/__linux__/%s/latest", codename)
options(repos = c(CRAN = if (codename %in% c("focal", "jammy", "noble")) ppm else "https://cloud.r-project.org"),
        HTTPUserAgent = sprintf("R/%s R (%s)", getRversion(),
                                paste(getRversion(), R.version\$platform, R.version\$arch, R.version\$os)),
        Ncpus = max(1L, parallel::detectCores() - 1L))
lib <- Sys.getenv("R_LIBS_USER")
if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager", lib = lib)
bioc <- c("sva", "edgeR", "limma", "statmod", "SummarizedExperiment", "TCGAbiolinks", "ComplexHeatmap")
cran <- c("rmarkdown", "knitr", "ggplot2", "ggrepel", "patchwork", "callr", "gtsummary", "broom",
          "circlize", "RColorBrewer", "RhpcBLASctl", "future", "future.apply", "ps")
need <- c(bioc, cran)[!vapply(c(bioc, cran), requireNamespace, logical(1), quietly = TRUE)]
if (length(need)) BiocManager::install(need, ask = FALSE, update = FALSE, lib = lib)
desc <- read.dcf("${REPO}/DESCRIPTION")
deps <- unlist(strsplit(paste(desc[, intersect(c("Depends", "Imports"), colnames(desc))], collapse = ","), ","))
deps <- setdiff(trimws(sub("\\\\(.*", "", deps)), c("", "R", rownames(installed.packages(priority = "base"))))
need <- deps[!vapply(deps, requireNamespace, logical(1), quietly = TRUE)]
if (length(need)) BiocManager::install(need, ask = FALSE, update = FALSE, lib = lib)
EOF
Rscript "$EX_DIR/.setup_linux_install.R"
rm -f "$EX_DIR/.setup_linux_install.R"
R CMD INSTALL "$REPO"

say "5. Checks"
Rscript - "$REPO" <<'EOF'
repo <- commandArgs(TRUE)[1]
want <- read.dcf(file.path(repo, "DESCRIPTION"), fields = "Version")[1, 1]
have <- as.character(packageVersion("rnaparallel"))
if (have != want) stop("installed rnaparallel ", have, " does not match DESCRIPTION ", want)
v <- BiocManager::valid()
if (!isTRUE(v)) {
  message("BiocManager::valid() is not TRUE; updating out-of-date packages once.")
  BiocManager::install(ask = FALSE, lib = Sys.getenv("R_LIBS_USER"))
  if (!isTRUE(BiocManager::valid())) warning("BiocManager::valid() is still not TRUE; see the list above. The render can still run.", call. = FALSE)
}
need <- c("rmarkdown", "knitr", "rnaparallel", "sva", "edgeR", "limma", "SummarizedExperiment", "ggplot2",
          "callr", "gtsummary", "ggrepel", "patchwork", "circlize", "RColorBrewer", "ComplexHeatmap",
          "TCGAbiolinks", "RhpcBLASctl")
miss <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(miss)) stop("missing R packages: ", paste(miss, collapse = ", "))
cat("rnaparallel", have, "installed; Bioconductor", as.character(BiocManager::version()), "\n")
EOF

DATA_DIR="${RNAPARALLEL_TCGA_DIR:-$(Rscript -e 'cat(tools::R_user_dir("rnaparallel", "cache"))')}"
mkdir -p "$DATA_DIR"
FREE_GB="$(df -Pk "$DATA_DIR" | awk 'NR==2 {printf "%d", $4/1048576}')"
echo "GDC download folder: $DATA_DIR (${FREE_GB} GB free)"
[ "$FREE_GB" -ge 15 ] || die "keep at least 15 GB free there, or set RNAPARALLEL_TCGA_DIR to a bigger disk"

if [ "$RENDER" -eq 0 ]; then
  say "Setup done. Start the render with: bash inst/examples/setup_linux.sh"
  exit 0
fi

say "6. Render"
# A cache made by another machine or another package version would put the wrong timings in the report.
rm -rf "$EX_DIR/RNA_Parallel_linux_cache"
cat > "$EX_DIR/.render_and_publish.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
cd "$1"
# Fail the push at once when no credential is reachable, instead of waiting on a prompt nobody sees.
export GIT_TERMINAL_PROMPT=0
if bash inst/examples/render_linux.sh; then
  html=inst/examples/RNA_Parallel_linux.html
  # The branch is public, so stop if the report names this account or this machine.
  hits="$(sed -E -e 's/data:[^"'"'"')]+//g' -e 's/id="rmd-source-code">[^<]*</</g' "$html" | grep -nFw -e "$HOME" -e "/home/$(id -un)" -e "$(hostname)" | cut -c1-200 || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    echo "REVIEW NEEDED: the report shows the paths or host name above. Nothing was committed."
    exit 1
  fi
  cp "$html" docs/linux.html
  git checkout -B linux-render
  git -c user.name=NamStacks -c user.email=231164958+NamStacks@users.noreply.github.com \
    commit -m "Linux report rendered on $(nproc) CPUs" docs/linux.html
  if git push -u origin linux-render; then
    echo "PUBLISHED: docs/linux.html pushed to branch linux-render."
  else
    echo "PUSH FAILED: the commit is on the local branch linux-render. Reconnect and run: git push -u origin linux-render"
  fi
else
  echo "RENDER FAILED: read the error above. Nothing was committed."
fi
rm -f "$0"
EOF
# setsid puts the job in its own session, so shutting down the VS Code server does not kill it.
setsid nohup bash "$EX_DIR/.render_and_publish.sh" "$REPO" > "$LOG" 2>&1 < /dev/null &
echo "Render started (pid $!). It takes several hours and survives an SSH disconnect."
echo "Watch:  tail -f $LOG"
echo "Done when the log ends in PUBLISHED, PUSH FAILED or RENDER FAILED."
