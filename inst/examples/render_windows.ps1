# Render the Windows verification report for rnaparallel.
#
# A multi-threaded BLAS reads its thread count when the library loads, so these have to be in
# the environment BEFORE R starts. Sys.setenv() inside the session is too late, which is the
# same reason render_linux.sh exports rather than sets. Stock Windows R ships the single-threaded
# reference BLAS and none of this matters there. It matters on a user-installed OpenBLAS or MKL
# build, where every PSOCK worker would otherwise open its own thread pool on top of the cluster
# and oversubscribe the machine.
#
# Run it from the repository root (or from inst\examples) in a plain PowerShell or cmd window:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File inst\examples\render_windows.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File inst\examples\render_windows.ps1 RNA_Parallel_windows.Rmd out.html
#
# A stock Windows 11 PowerShell has execution policy Restricted and refuses a bare
# .\render_windows.ps1. -ExecutionPolicy Bypass applies to this one process only and changes no
# machine setting, so no administrator rights are needed. A Group Policy that sets the policy
# for the machine or user still wins over -ExecutionPolicy Bypass, and then an administrator
# must allow the script. A relative In or Out is resolved
# against the folder you ran the command from. By default the HTML lands next to the Rmd.
#
# Before the first render: R 4.6.x and RStudio Desktop installed, the install chunk in section A
# of the notebook run once (rmarkdown, knitr and rnaparallel come from it), and no other heavy
# program open. Rtools is not needed, because the package has no compiled code. Get the repository
# with git clone, or with Code > Download ZIP on GitHub and extract it, into a short folder
# outside OneDrive. Windows Defender Firewall may ask once whether R may use the network for
# the local worker cluster: allow it on private networks. Set RNAPARALLEL_TCGA_DIR to a short folder such
# as C:\tcga, because GDC file paths come close to the 260-character Windows limit. The first render
# downloads several GB through the GDC API, so it needs internet and free disk. The render takes
# hours: plug in the charger, choose Best performance under Settings > System > Power & battery,
# and keep the lid open. This script keeps Windows awake while it runs, but it cannot stop a lid
# close or the power button from sleeping the laptop.

param(
  [string]$In  = "",
  [string]$Out = ""
)

$ErrorActionPreference = "Stop"
$callerDir = (Get-Location).Path
$scriptDir = $PSScriptRoot

# Relative paths mean relative to where the user stood, resolved before the cd below. A bare
# notebook name that is not there falls back to the notebook beside this script.
if (-not $In) { $In = Join-Path $scriptDir "RNA_Parallel_windows.Rmd" }
if (-not [System.IO.Path]::IsPathRooted($In)) {
  $fromCaller = Join-Path $callerDir $In
  $fromScript = Join-Path $scriptDir $In
  $In = if (Test-Path $fromCaller) { $fromCaller } else { $fromScript }
}
if (-not (Test-Path $In)) { throw "input not found: $In" }
$In = (Resolve-Path $In).Path
if (-not $Out) {
  $Out = [System.IO.Path]::ChangeExtension($In, "html")
} elseif (-not [System.IO.Path]::IsPathRooted($Out)) {
  $Out = Join-Path $callerDir $Out
}
Set-Location -Path $scriptDir

$env:OPENBLAS_NUM_THREADS = "1"
$env:OMP_NUM_THREADS      = "1"
$env:MKL_NUM_THREADS      = "1"

# A pandoc counts only if it runs: a file that exists but cannot start (a broken unzip, the wrong
# architecture) passes Test-Path and then fails at the last step of a render of several hours.
function Test-Pandoc([string]$dir) {
  if (-not $dir) { return $false }
  $exe = Join-Path $dir "pandoc.exe"
  if (-not (Test-Path $exe)) { return $false }
  try {
    $null = & $exe --version 2>&1
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

# pandoc ships with RStudio and is not on PATH in a plain PowerShell session. Current RStudio
# keeps it under quarto\bin\tools, in a per-architecture folder in newer Quarto builds. A machine
# with no RStudio at all is the other common case here, so a standalone install and PATH count.
$arch  = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "aarch64" } else { "x86_64" }
$roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs") |
         Where-Object { $_ }
$tails = @(
  "RStudio\resources\app\quarto\bin\tools\$arch",
  "RStudio\resources\app\quarto\bin\tools",
  "RStudio\resources\app\bin\quarto\bin\tools\$arch",
  "RStudio\resources\app\bin\quarto\bin\tools",
  "RStudio\resources\app\bin\pandoc",
  "RStudio\bin\quarto\bin\tools\$arch",
  "RStudio\bin\quarto\bin\tools",
  "RStudio\bin\pandoc"
)
$candidates = @($env:RSTUDIO_PANDOC)
foreach ($r in $roots) { foreach ($t in $tails) { $candidates += (Join-Path $r $t) } }
$onPath = (Get-Command pandoc.exe -ErrorAction SilentlyContinue).Source
if ($onPath) { $candidates += (Split-Path $onPath) }
$candidates += "$env:LOCALAPPDATA\Pandoc", "$env:ProgramFiles\Pandoc"

$env:RSTUDIO_PANDOC = ""
foreach ($d in $candidates) {
  if (Test-Pandoc $d) { $env:RSTUDIO_PANDOC = $d; break }
}

# Rscript is not on PATH by default on Windows, unlike every other platform this package
# renders on. The registry knows where R is even when the shell does not, under HKCU for a
# per-user install (the default without administrator rights) and under HKLM for an all-users one.
$rscript = (Get-Command Rscript.exe -ErrorAction SilentlyContinue).Source
if (-not $rscript) {
  foreach ($hive in "HKCU:", "HKLM:") {
    foreach ($sub in "R", "R64") {
      $key = Get-ItemProperty "$hive\SOFTWARE\R-core\$sub" -ErrorAction SilentlyContinue
      if ($key -and $key.InstallPath) {
        $cand = Join-Path $key.InstallPath "bin\x64\Rscript.exe"
        if (Test-Path $cand) { $rscript = $cand; break }
      }
    }
    if ($rscript) { break }
  }
}
if (-not $rscript) {
  $homes = @("$env:ProgramFiles\R", "$env:LOCALAPPDATA\Programs\R") | Where-Object { Test-Path $_ }
  $found = foreach ($h in $homes) { Get-ChildItem $h -Filter Rscript.exe -Recurse -ErrorAction SilentlyContinue }
  $cand = $found |
          Where-Object { $_.FullName -notmatch "\\i386\\" } |
          Sort-Object { if ($_.FullName -match "R-(\d+(\.\d+){1,3})") { [version]$Matches[1] } else { [version]"0.0" } } -Descending |
          Select-Object -First 1
  if ($cand) { $rscript = $cand.FullName }
}
if (-not $rscript) {
  throw ("Rscript.exe not found in PATH, the registry (HKCU and HKLM), Program Files\R or " +
         "%LOCALAPPDATA%\Programs\R. Install R, or add R's bin\x64 directory to PATH.")
}

Write-Host "Rscript        = $rscript"
Write-Host "RSTUDIO_PANDOC = $(if ($env:RSTUDIO_PANDOC) { $env:RSTUDIO_PANDOC } else { '<not found>' })"

# Fail here rather than after the render. Pandoc is the LAST step, so without this the report
# computes the whole cohort (over an hour) and then dies with nothing written.
if (-not $env:RSTUDIO_PANDOC) {
  throw ("pandoc not found or not runnable. rmarkdown needs it to write the HTML, and it is the " +
         "last step of a render that takes hours, so this stops now rather than at the end. " +
         "Install RStudio Desktop or pandoc, or set RSTUDIO_PANDOC to a directory holding a " +
         "pandoc.exe that runs.")
}

# The same early stop for the R packages the first minutes of the render need. Running the
# install chunk of the notebook once installs all of them.
$prevPref = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$missing = & $rscript -e "m <- c('rmarkdown', 'knitr', 'rnaparallel')[!vapply(c('rmarkdown', 'knitr', 'rnaparallel'), requireNamespace, logical(1), quietly = TRUE)]; cat(m); quit(status = as.integer(length(m) > 0))" 2>$null
$pkgStatus = $LASTEXITCODE
$ErrorActionPreference = $prevPref
if ($pkgStatus -ne 0) {
  throw "R packages missing: $missing. Run the install chunk in section A of RNA_Parallel_windows.Rmd once, then render again."
}

# A render of hours does not count as activity to Windows, so the idle timer would sleep the
# laptop and kill the PSOCK sockets mid-sweep. ES_CONTINUOUS | ES_SYSTEM_REQUIRED holds the
# system awake until this process exits or releases it below.
$ES_CONTINUOUS      = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1
$awake = $false
try {
  if (-not ("RP.Pwr" -as [type])) {
    Add-Type -Namespace RP -Name Pwr -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
  }
  [void][RP.Pwr]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)
  $awake = $true
} catch {
  Write-Warning "Could not keep Windows awake ($($_.Exception.Message)). Set Screen and sleep to Never under Settings > System > Power & battery before a render of hours."
}

$bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
if ($bat -and ($bat | Where-Object { $_.BatteryStatus -eq 1 })) {
  Write-Warning "Running on battery. Plug in the charger and choose Best performance under Settings > System > Power & battery, or the timings are not comparable and efficiency cores take the work. On battery Windows can also suspend the render about 5 minutes after the sleep timeout even while this script holds the system awake."
}

Write-Host "BLAS threads   = $env:OPENBLAS_NUM_THREADS"
Write-Host "rendering $In -> $Out"

# 'Stop' turns every stderr line of a native command into a terminating error under Windows
# PowerShell 5.1 when the run is logged or piped, and Rscript writes progress to stderr from its
# first second. The preamble above keeps 'Stop'; the render itself must not, and its exit code
# is what reports failure.
$ErrorActionPreference = "Continue"
try {
  & $rscript -e "a <- commandArgs(TRUE); rmarkdown::render(a[1], output_file = a[2], quiet = FALSE)" $In $Out
  $code = $LASTEXITCODE
} finally {
  if ($awake) { [void][RP.Pwr]::SetThreadExecutionState($ES_CONTINUOUS) }
}
exit $code
