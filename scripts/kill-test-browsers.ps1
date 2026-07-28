# Kill ONLY the headless browsers this repo's harnesses spawned.
#
# Never `Get-Process chrome | Stop-Process`. That matches the developer's own browser and
# takes their tabs with it — which is exactly what happened once, and is the reason this
# script exists rather than a one-liner.
#
# Every harness here passes --user-data-dir under the session scratchpad, so the command
# line is the discriminator. A process without that marker is somebody's actual browser.
param([string]$Marker = "bedlam")

Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe' OR Name = 'msedge.exe'" |
    Where-Object { $_.CommandLine -like "*--user-data-dir=*$Marker*" -or
                   $_.CommandLine -like "*--user-data-dir=*scratchpad*" } |
    ForEach-Object {
        Write-Host "stopping pid $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
