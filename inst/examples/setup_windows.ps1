# One command to set up a Windows 11 machine and render the Windows report.
#
# From a clone of the repository, in a plain PowerShell window (no administrator rights needed):
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File inst\examples\setup_windows.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File inst\examples\setup_windows.ps1 -NoRender
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File inst\examples\setup_windows.ps1 -Yes
#
# -NoRender sets up and checks only. -Yes does not stop on the hardware warnings. What it does,
# in order; each step is skipped when the machine already has what it needs.
#   1. Prints the hardware and stops on battery power or low free memory.
#   2. Finds R 4.1 or newer, and installs the current R with winget when none is found.
#   3. Finds pandoc, and unpacks pandoc 3.1.11.1 into %LOCALAPPDATA%\Pandoc when none is found.
#   4. Installs the R packages into your user library, then this checkout.
#   5. Checks that the installed version matches DESCRIPTION, and that 15 GB is free for the
#      GDC download, which goes to C:\tcga unless RNAPARALLEL_TCGA_DIR names another short folder.
#   6. Starts render_windows.ps1 in a hidden window that survives closing this one. The log is
#      inst\examples\render_windows.log.
#   7. When the render ends, copies the HTML to docs\windows.html, commits it on the branch
#      windows-render as NamStacks and pushes that branch. It commits nothing if the report
#      shows this account's profile path, user name or computer name. Without git, or when the
#      push fails, the log says where the HTML is.
#
# Watch it with:  Get-Content inst\examples\render_windows.log -Wait

param(
  [switch]$NoRender,
  [switch]$Yes
)

$ErrorActionPreference = "Stop"
$exDir = $PSScriptRoot
$repo  = (Resolve-Path (Join-Path $exDir "..\..")).Path
$log   = Join-Path $exDir "render_windows.log"
function Say([string]$m) { Write-Host ""; Write-Host "== $m" }
function Die([string]$m) { throw $m }

if (-not (Test-Path (Join-Path $repo "DESCRIPTION"))) { Die "run this from a clone of NamStacks/RNA-Parallel" }

Say "1. Hardware"
$cpu    = Get-CimInstance Win32_Processor | Select-Object -First 1
$os     = Get-CimInstance Win32_OperatingSystem
$memGb  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 0)
$freeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 0)
$threads = ($cpu.NumberOfLogicalProcessors | Measure-Object -Sum).Sum
Write-Host "$($os.Caption), $($cpu.Name.Trim()), $threads logical CPUs, $memGb GB RAM ($freeGb GB free)"
$warn = $false
$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($bat -and ($bat | Where-Object { $_.BatteryStatus -eq 1 })) {
  Write-Warning "Running on battery. Plug in the charger and choose Best performance under Settings > System > Power & battery."
  $warn = $true
}
if ($freeGb -lt 8) {
  Write-Warning "Only $freeGb GB of RAM is free; the memory guard may cap the sweep. Close other programs."
  $warn = $true
}
if ($warn -and -not $Yes -and -not $NoRender) {
  Die "the timings would not be a fair Windows report here. Fix the warnings above, or run again with -Yes to render anyway."
}

Say "2. R"
function Find-Rscript {
  $r = (Get-Command Rscript.exe -ErrorAction SilentlyContinue).Source
  if ($r) { return $r }
  foreach ($hive in "HKCU:", "HKLM:") {
    foreach ($sub in "R", "R64") {
      $key = Get-ItemProperty "$hive\SOFTWARE\R-core\$sub" -ErrorAction SilentlyContinue
      if ($key -and $key.InstallPath) {
        $cand = Join-Path $key.InstallPath "bin\x64\Rscript.exe"
        if (Test-Path $cand) { return $cand }
      }
    }
  }
  $homes = @("$env:ProgramFiles\R", "$env:LOCALAPPDATA\Programs\R") | Where-Object { Test-Path $_ }
  $found = foreach ($h in $homes) { Get-ChildItem $h -Filter Rscript.exe -Recurse -ErrorAction SilentlyContinue }
  $cand = $found |
          Where-Object { $_.FullName -notmatch "\\i386\\" } |
          Sort-Object { if ($_.FullName -match "R-(\d+(\.\d+){1,3})") { [version]$Matches[1] } else { [version]"0.0" } } -Descending |
          Select-Object -First 1
  if ($cand) { return $cand.FullName }
  return $null
}
$rscript = Find-Rscript
if (-not $rscript) {
  if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Die "R is not installed and winget is not available. Install R from https://cran.r-project.org/bin/windows/base/ and run this again."
  }
  Write-Host "Installing R with winget."
  winget install --id RProject.R -e --scope user --accept-package-agreements --accept-source-agreements
  $rscript = Find-Rscript
  if (-not $rscript) { Die "R was installed but Rscript.exe was not found. Open a new PowerShell window and run this again." }
}
$prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$rver = (& $rscript -e "cat(as.character(getRversion()))" 2>$null)
$ErrorActionPreference = $prev
Write-Host "Rscript = $rscript (R $rver)"
if ([version]$rver -lt [version]"4.1") { Die "R $rver is too old; install R 4.6 or newer from CRAN." }
if ([version]$rver -lt [version]"4.6") { Write-Warning "The published Windows report used R 4.6.1; this is R $rver." }

Say "3. pandoc"
function Test-Pandoc([string]$dir) {
  if (-not $dir) { return $false }
  $exe = Join-Path $dir "pandoc.exe"
  if (-not (Test-Path $exe)) { return $false }
  try { $null = & $exe --version 2>&1; return ($LASTEXITCODE -eq 0) } catch { return $false }
}
$arch  = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64" } else { "x86_64" }
$roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs") | Where-Object { $_ }
$tails = @("RStudio\resources\app\quarto\bin\tools\$arch", "RStudio\resources\app\quarto\bin\tools",
           "RStudio\resources\app\bin\quarto\bin\tools\$arch", "RStudio\resources\app\bin\quarto\bin\tools",
           "RStudio\resources\app\bin\pandoc", "RStudio\bin\quarto\bin\tools\$arch",
           "RStudio\bin\quarto\bin\tools", "RStudio\bin\pandoc")
$candidates = @($env:RSTUDIO_PANDOC)
foreach ($r in $roots) { foreach ($t in $tails) { $candidates += (Join-Path $r $t) } }
$onPath = (Get-Command pandoc.exe -ErrorAction SilentlyContinue).Source
if ($onPath) { $candidates += (Split-Path $onPath) }
$candidates += "$env:LOCALAPPDATA\Pandoc", "$env:ProgramFiles\Pandoc"
$pandocDir = $null
foreach ($d in $candidates) { if (Test-Pandoc $d) { $pandocDir = $d; break } }
if (-not $pandocDir) {
  if ($arch -ne "x86_64") { Die "no pandoc build for $arch here; install pandoc or RStudio Desktop and run this again." }
  $pv  = "3.1.11.1"
  $zip = Join-Path $env:TEMP "pandoc-$pv.zip"
  $tmp = Join-Path $env:TEMP "pandoc-$pv-unzip"
  Invoke-WebRequest -UseBasicParsing "https://github.com/jgm/pandoc/releases/download/$pv/pandoc-$pv-windows-x86_64.zip" -OutFile $zip
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  Expand-Archive $zip -DestinationPath $tmp -Force
  New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\Pandoc" | Out-Null
  Copy-Item (Join-Path $tmp "pandoc-$pv\pandoc.exe") "$env:LOCALAPPDATA\Pandoc\pandoc.exe" -Force
  Remove-Item $zip, $tmp -Recurse -Force
  $pandocDir = "$env:LOCALAPPDATA\Pandoc"
  if (-not (Test-Pandoc $pandocDir)) { Die "pandoc was unpacked but does not run; install RStudio Desktop or pandoc and run this again." }
}
$env:RSTUDIO_PANDOC = $pandocDir
Write-Host "pandoc = $pandocDir"

Say "4. R packages"
$installR = Join-Path $exDir ".setup_windows_install.R"
@'
repo <- commandArgs(TRUE)[1]
lib <- Sys.getenv("R_LIBS_USER")
dir.create(lib, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(lib, .libPaths()))
options(repos = c(CRAN = "https://cloud.r-project.org"), Ncpus = max(1L, parallel::detectCores() - 1L))
if (!requireNamespace("BiocManager", quietly = TRUE)) install.packages("BiocManager", lib = lib)
bioc <- c("sva", "edgeR", "limma", "statmod", "SummarizedExperiment", "TCGAbiolinks", "ComplexHeatmap")
cran <- c("rmarkdown", "knitr", "ggplot2", "ggrepel", "patchwork", "callr", "gtsummary", "broom",
          "circlize", "RColorBrewer", "RhpcBLASctl", "future", "future.apply", "ps")
need <- c(bioc, cran)[!vapply(c(bioc, cran), requireNamespace, logical(1), quietly = TRUE)]
if (length(need)) BiocManager::install(need, ask = FALSE, update = FALSE, lib = lib)
desc <- read.dcf(file.path(repo, "DESCRIPTION"))
deps <- unlist(strsplit(paste(desc[, intersect(c("Depends", "Imports"), colnames(desc))], collapse = ","), ","))
deps <- setdiff(trimws(sub("\\(.*", "", deps)), c("", "R", rownames(installed.packages(priority = "base"))))
need <- deps[!vapply(deps, requireNamespace, logical(1), quietly = TRUE)]
if (length(need)) BiocManager::install(need, ask = FALSE, update = FALSE, lib = lib)
install.packages(repo, repos = NULL, type = "source", lib = lib)
'@ | Set-Content -Path $installR -Encoding ASCII
$prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
& $rscript $installR $repo
$code = $LASTEXITCODE
$ErrorActionPreference = $prev
Remove-Item $installR -Force -ErrorAction SilentlyContinue
if ($code -ne 0) { Die "the R package install failed (exit $code); read the output above." }

Say "5. Checks"
$checkR = Join-Path $exDir ".setup_windows_check.R"
@'
repo <- commandArgs(TRUE)[1]
want <- read.dcf(file.path(repo, "DESCRIPTION"), fields = "Version")[1, 1]
have <- as.character(packageVersion("rnaparallel"))
if (have != want) stop("installed rnaparallel ", have, " does not match DESCRIPTION ", want)
need <- c("rmarkdown", "knitr", "rnaparallel", "sva", "edgeR", "limma", "SummarizedExperiment", "ggplot2",
          "callr", "gtsummary", "ggrepel", "patchwork", "circlize", "RColorBrewer", "ComplexHeatmap",
          "TCGAbiolinks", "RhpcBLASctl")
miss <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(miss)) stop("missing R packages: ", paste(miss, collapse = ", "))
cat("rnaparallel", have, "installed; Bioconductor", as.character(BiocManager::version()), "\n")
'@ | Set-Content -Path $checkR -Encoding ASCII
$prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
& $rscript $checkR $repo
$code = $LASTEXITCODE
$ErrorActionPreference = $prev
Remove-Item $checkR -Force -ErrorAction SilentlyContinue
if ($code -ne 0) { Die "the package check failed; read the output above." }

if (-not $env:RNAPARALLEL_TCGA_DIR) {
  $env:RNAPARALLEL_TCGA_DIR = "C:\tcga"
  [Environment]::SetEnvironmentVariable("RNAPARALLEL_TCGA_DIR", "C:\tcga", "User")
}
New-Item -ItemType Directory -Force $env:RNAPARALLEL_TCGA_DIR | Out-Null
$drive = (Get-Item $env:RNAPARALLEL_TCGA_DIR).PSDrive
$diskGb = [math]::Round($drive.Free / 1GB, 0)
Write-Host "GDC download folder: $($env:RNAPARALLEL_TCGA_DIR) ($diskGb GB free)"
if ($diskGb -lt 15) { Die "keep at least 15 GB free there, or set RNAPARALLEL_TCGA_DIR to a short folder on a bigger disk" }

if ($NoRender) {
  Say "Setup done. Start the render with: powershell.exe -NoProfile -ExecutionPolicy Bypass -File inst\examples\setup_windows.ps1"
  exit 0
}

Say "6. Render"
# A cache made by another machine or another package version would put the wrong timings in the report.
Remove-Item (Join-Path $exDir "RNA_Parallel_windows_cache") -Recurse -Force -ErrorAction SilentlyContinue
$job = Join-Path $exDir ".render_and_publish.ps1"
@'
param([string]$Repo)
$ErrorActionPreference = "Continue"
$env:GIT_TERMINAL_PROMPT = "0"
$ex   = Join-Path $Repo "inst\examples"
$html = Join-Path $ex "RNA_Parallel_windows.html"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ex "render_windows.ps1")
if ($LASTEXITCODE -ne 0) {
  Write-Host "RENDER FAILED: read the error above. Nothing was committed."
  Remove-Item $PSCommandPath -Force
  exit 1
}
# The branch is public, so stop if the report names this account or this machine.
$text = [IO.File]::ReadAllText($html)
$text = [regex]::Replace($text, 'data:[^"'')]+', '')
$text = [regex]::Replace($text, 'id="rmd-source-code">[^<]*<', '<')
$names = @($env:USERPROFILE, ($env:USERPROFILE -replace '\\', '/'), $env:USERNAME, $env:COMPUTERNAME) |
         Where-Object { $_ -and $_.Length -ge 3 } | Select-Object -Unique
$hits = foreach ($n in $names) {
  $m = [regex]::Matches($text, '(?<![A-Za-z0-9_])' + [regex]::Escape($n) + '(?![A-Za-z0-9_])', 'IgnoreCase')
  if ($m.Count) { "$($m.Count) x $n" }
}
if ($hits) {
  $hits
  Write-Host "REVIEW NEEDED: the report shows the names above. Nothing was committed. The HTML is $html"
  Remove-Item $PSCommandPath -Force
  exit 1
}
$git = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git -or -not (Test-Path (Join-Path $Repo ".git"))) {
  Write-Host "NOT PUBLISHED: no git checkout here. Send back $html"
  Remove-Item $PSCommandPath -Force
  exit 0
}
Copy-Item $html (Join-Path $Repo "docs\windows.html") -Force
Set-Location $Repo
git checkout -B windows-render
git -c user.name=NamStacks -c user.email=231164958+NamStacks@users.noreply.github.com commit -m "Windows report rendered on $([Environment]::ProcessorCount) logical CPUs" docs/windows.html
git push -u origin windows-render
if ($LASTEXITCODE -eq 0) {
  Write-Host "PUBLISHED: docs/windows.html pushed to branch windows-render."
} else {
  Write-Host "PUSH FAILED: the commit is on the local branch windows-render. Sign in to GitHub and run: git push -u origin windows-render. The HTML is $html"
}
Remove-Item $PSCommandPath -Force
'@ | Set-Content -Path $job -Encoding ASCII
# A hidden window of its own keeps the render alive when this window closes or the session disconnects.
Start-Process -FilePath "powershell.exe" -WindowStyle Hidden `
  -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $job, "-Repo", $repo) `
  -RedirectStandardOutput $log -RedirectStandardError (Join-Path $exDir "render_windows.err.log")
Write-Host "Render started. It takes several hours and survives closing this window."
Write-Host "Keep the charger plugged in and the lid open; sleep is held off while it runs."
Write-Host "Watch:  Get-Content $log -Wait"
Write-Host "Done when the log ends in PUBLISHED, PUSH FAILED, NOT PUBLISHED, REVIEW NEEDED or RENDER FAILED."
