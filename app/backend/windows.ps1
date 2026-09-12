param(
  [ValidateSet('detect','apply','restore','safety-on','safety-off')][string]$Action = 'detect',
  [string]$Items = '',
  [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$AppHome = Join-Path $env:APPDATA 'AI Gatekeeper'
$StateFile = Join-Path $AppHome 'latest-snapshot.json'
$SnapshotDir = Join-Path $AppHome 'snapshots'
$HistoryDir = Join-Path $AppHome 'history'
$BaselineFile = Join-Path $AppHome 'baseline-snapshot.json'
$BrowserRoot = Join-Path $env:LOCALAPPDATA 'AI-Gatekeeper\Browsers'
$TargetCountry = if($env:TARGET_COUNTRY){$env:TARGET_COUNTRY.ToUpper()}else{'US'}
$ExpectedIp = "$($env:EXPECTED_IP)".Trim()
$ProxyUrl = "$($env:PROXY_URL)".Trim()
$TargetTimezone = if($env:TARGET_TIMEZONE){$env:TARGET_TIMEZONE}else{'Pacific Standard Time'}
$TargetLanguage = if($env:TARGET_LANGUAGE){$env:TARGET_LANGUAGE}else{'en-US'}
$AiTargets = @(
  @{platform='Claude';host='claude.ai'},@{platform='Claude';host='api.anthropic.com'},@{platform='Claude';host='console.anthropic.com'},
  @{platform='ChatGPT';host='chatgpt.com'},@{platform='ChatGPT';host='api.openai.com'},@{platform='ChatGPT';host='platform.openai.com'},@{platform='ChatGPT';host='auth.openai.com'},@{platform='ChatGPT';host='ios.chat.openai.com'},
  @{platform='Gemini';host='gemini.google.com'},@{platform='Gemini';host='aistudio.google.com'},@{platform='Gemini';host='generativelanguage.googleapis.com'},@{platform='Gemini';host='oauth2.googleapis.com'},
  @{platform='Grok';host='grok.com'},@{platform='Grok';host='x.ai'},@{platform='Grok';host='api.x.ai'},@{platform='Grok';host='auth.x.ai'}
)

function Latest-Snapshot {
  if(Test-Path $BaselineFile){return $BaselineFile}
  if(Test-Path $StateFile){return $StateFile}
  if(Test-Path $SnapshotDir){
    foreach($file in (Get-ChildItem $SnapshotDir -Filter '*.json' | Sort-Object Name)){
      try {$version = (Get-Content -Raw $file.FullName | ConvertFrom-Json).version} catch {$version = 1}
      if(-not $version -or $version -lt 3){return $file.FullName}
    }
  }
  return $null
}

function Is-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Active-Adapters {
  @(Get-NetAdapter | Where-Object Status -eq 'Up')
}

function Adapter-Dns($Adapter) {
  try { @((Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) }
  catch { @() }
}

function Adapter-IPv6($Adapter) {
  try { [bool](Get-NetAdapterBinding -Name $Adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop).Enabled }
  catch { $false }
}

function Browser-Paths {
  @((Join-Path $BrowserRoot 'Chrome-Claude-OpenAI\Default\Preferences'), (Join-Path $BrowserRoot 'Edge-Claude-OpenAI\Default\Preferences'))
}

function Test-BrowserPrefs([string]$Path) {
  if (-not (Test-Path $Path)) { return $false }
  try {
    $data = Get-Content -Raw $Path | ConvertFrom-Json
    return $data.webrtc.ip_handling_policy -eq 'disable_non_proxied_udp' -and $data.webrtc.nonproxied_udp_enabled -eq $false -and "$($data.intl.accept_languages)".StartsWith('en-US')
  } catch { return $false }
}

function Detect-State {
  $tz = (tzutil /g).Trim()
  $culture = (Get-Culture).Name
  $adapters = Active-Adapters
  $dns = @($adapters | ForEach-Object { Adapter-Dns $_ } | Select-Object -Unique)
  $risky = @($dns | Where-Object { $_ -match '^(114\.|223\.[56]\.|119\.29\.)' })
  $ipv6Public = ''
  try { $ipv6Public = ((& curl.exe --noproxy '*' -6 -fsS --max-time 2 https://ifconfig.co 2>$null) | Out-String).Trim() } catch {}
  $proxy = (netsh winhttp show proxy | Out-String).Trim()
  $routeJobs = @($AiTargets | ForEach-Object {
    $target = $_
    Start-Job -Name $target.host -ScriptBlock {
      param($Platform,$HostName,$Proxy)
      $map = @{}
      try {
        $curlArgs = @('-fsS','--max-time','5')
        if($Proxy){$curlArgs += @('--proxy',$Proxy)}
        $curlArgs += "https://$HostName/cdn-cgi/trace"
        $trace = & curl.exe @curlArgs 2>$null
        $trace -split "`n" | ForEach-Object { if ($_ -match '^([^=]+)=(.*)$') { $map[$matches[1]] = $matches[2].Trim() } }
      } catch {}
      $confirmed = [bool]$map.ip
      $reachable = $confirmed
      if(-not $reachable){
        try {
          $probeArgs = @('-sS','-o','NUL','--max-time','5'); if($Proxy){$probeArgs += @('--proxy',$Proxy)}; $probeArgs += "https://$HostName/"
          & curl.exe @probeArgs 2>$null; $reachable = $LASTEXITCODE -eq 0
        } catch {}
      }
      [pscustomobject]@{platform=$Platform;host=$HostName;reachable=$reachable;confirmed=$confirmed;ip="$($map.ip)";loc="$($map.loc)";colo="$($map.colo)"}
    } -ArgumentList $target.platform,$target.host,$ProxyUrl
  })
  $routeJobs | Wait-Job -Timeout 12 | Out-Null
  $routes = @($routeJobs | Where-Object State -eq 'Completed' | Receive-Job)
  $completedHosts = @($routes | ForEach-Object {$_.host})
  $routes += @($AiTargets | Where-Object {$completedHosts -notcontains $_.host} | ForEach-Object {[pscustomobject]@{platform=$_.platform;host=$_.host;reachable=$false;confirmed=$false;ip='';loc='';colo=''}})
  $routeJobs | Where-Object State -ne 'Completed' | Stop-Job -ErrorAction SilentlyContinue
  $routeJobs | Remove-Job -Force -ErrorAction SilentlyContinue
  $good = @($routes | Where-Object {$_.confirmed})
  $failures = @($routes | Where-Object {-not $_.reachable})
  $unconfirmed = @($routes | Where-Object {$_.reachable -and -not $_.confirmed})
  $ips = @($good | Select-Object -ExpandProperty ip -Unique)
  $badCountry = @($good | Where-Object {$_.loc -ne $TargetCountry})
  $badIp = @($good | Where-Object {$ExpectedIp -and $_.ip -ne $ExpectedIp})
  $routePassed = $failures.Count -eq 0 -and $good.Count -gt 0 -and $ips.Count -eq 1 -and $badCountry.Count -eq 0 -and $badIp.Count -eq 0
  $routeStatus = if($routePassed -and $unconfirmed.Count -eq 0){'pass'}elseif($routePassed){'warn'}else{'fail'}
  $routeLines = @($routes | ForEach-Object {"$($_.platform) | $($_.host) | $(if($_.confirmed){$_.ip}elseif($_.reachable){'connected, egress unconfirmed'}else{'unreachable'}) $(if($_.loc){$_.loc}else{'-'}) $(if($_.colo){$_.colo}else{'-'})"})
  if($ips.Count -gt 1){$routeLines += "Multiple egress IPs: $($ips -join ', ')"}
  if($badCountry.Count){$routeLines += "Wrong country: $((@($badCountry | ForEach-Object {$_.host})) -join ', ')"}
  if($badIp.Count){$routeLines += "Not expected IP ${ExpectedIp}: $((@($badIp | ForEach-Object {$_.host})) -join ', ')"}
  if($failures.Count){$routeLines += "Unreachable: $((@($failures | ForEach-Object {$_.host})) -join ', ')"}
  if($unconfirmed.Count){$routeLines += "Egress unconfirmed: $((@($unconfirmed | ForEach-Object {$_.host})) -join ', ')"}
  $routeDetail = $routeLines -join "`n"
  $qualityStatus = 'warn'; $qualityDetail = 'An IP quality check needs one consistent egress IP.'
  if($ips.Count -eq 1){
    try {
      $curlArgs = @('-fsS','--max-time','4'); if($ProxyUrl){$curlArgs += @('--proxy',$ProxyUrl)}; $curlArgs += "https://api.ipapi.is/?q=$($ips[0])"
      $intel = ((& curl.exe @curlArgs 2>$null) | Out-String | ConvertFrom-Json)
      $risks = @(); if($intel.is_datacenter){$risks += 'datacenter'}; if($intel.is_proxy){$risks += 'proxy'}; if($intel.is_vpn){$risks += 'VPN'}; if($intel.is_tor){$risks += 'Tor'}; if($intel.is_abuser){$risks += 'abuse'}
      $qualityStatus = if($risks.Count){'warn'}else{'pass'}
      $qualityDetail = "$($ips[0]); $($intel.location.country_code) $($intel.location.city); AS$($intel.asn.asn) $($intel.asn.org); type $($intel.asn.type)"
      if($risks.Count){$qualityDetail += "; risk flags: $($risks -join ', ')"}else{$qualityDetail += '; no obvious risk flags'}
    } catch {$qualityDetail = 'The IP intelligence source is temporarily unavailable.'}
  }
  $browserReady = @((Browser-Paths) | Where-Object { Test-BrowserPrefs $_ }).Count -eq 2
  $dockerInstalled = [bool](Get-Command docker.exe -ErrorAction SilentlyContinue)
  $items = @(
    @{id='system_locale';title='Time zone and locale';status=$(if($tz -eq $TargetTimezone -and $culture -eq $TargetLanguage){'pass'}else{'fail'});detail="Current: $tz / $culture; target: $TargetTimezone / $TargetLanguage";fixable=$true},
    @{id='dns';title='System DNS';status=$(if($risky.Count){'fail'}elseif($dns.Count){'pass'}else{'warn'});detail="DNS: $($dns -join ', ')";fixable=$true;recommendedFix=[bool]$risky.Count},
    @{id='ipv6';title='IPv6 direct access';status=$(if($ipv6Public -match ':'){'fail'}else{'pass'});detail=$(if($ipv6Public -match ':'){"Public IPv6: $ipv6Public"}else{'No direct public IPv6 detected'});fixable=$true},
    @{id='proxy';title='Windows system proxy';status='info';detail=$proxy;fixable=$false},
    @{id='route';title='AI multi-domain egress';status=$routeStatus;detail=$routeDetail;routeDetails=$routes;fixable=$false},
    @{id='safety_valve';title='Overseas traffic safety valve';status='warn';detail='A rule-capable proxy controller is not configured on Windows. Safety valve is unavailable until a compatible controller is configured.';fixable=$false;toggleable=$false;enabled=$false;active=$false},
    @{id='ip_quality';title='Egress IP quality';status=$qualityStatus;detail=$qualityDetail;fixable=$false},
    @{id='browser_profile';title='Dedicated browser leak protection';status=$(if($browserReady){'pass'}else{'fail'});detail="Chrome/Edge profiles: $BrowserRoot";fixable=$true},
    @{id='saferoom';title='Claude SafeRoom';status='warn';detail=$(if($dockerInstalled){'Docker CLI is installed; run the container gate to verify the daemon and egress'}else{'Docker is not installed; host checks still work'});fixable=$false}
  )
  $snapshotAvailable = [bool](Latest-Snapshot)
  @{platformLabel='Windows';items=$items;snapshotAvailable=$snapshotAvailable}
}

function Save-Snapshot($ModifiedItems) {
  $legacySnapshot = if(-not (Test-Path $BaselineFile)){Latest-Snapshot}else{$null}
  New-Item -ItemType Directory -Force $AppHome | Out-Null
  New-Item -ItemType Directory -Force $HistoryDir | Out-Null
  $adapters = Active-Adapters
  $network = @($adapters | ForEach-Object {
    @{name=$_.Name;index=$_.ifIndex;dns=@(Adapter-Dns $_);ipv6=(Adapter-IPv6 $_)}
  })
  $browser = @((Browser-Paths) | ForEach-Object {
    $exists = Test-Path $_
    @{path=$_;existed=$exists;content=$(if($exists){[Convert]::ToBase64String([IO.File]::ReadAllBytes($_))}else{$null})}
  })
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss.fffffffZ')
  $state = @{version=3;createdAt=$stamp;modifiedItems=@($ModifiedItems);timezone=(tzutil /g).Trim();culture=(Get-Culture).Name;systemLocale=(Get-WinSystemLocale).Name;network=$network;browser=$browser}
  $state | ConvertTo-Json -Depth 7 | Set-Content -Encoding UTF8 (Join-Path $HistoryDir "change-$stamp.json")
  if(Test-Path $BaselineFile){
    $baseline = Get-Content -Raw $BaselineFile | ConvertFrom-Json
    $baseline.modifiedItems = @($baseline.modifiedItems + $ModifiedItems | Select-Object -Unique)
    $baseline | ConvertTo-Json -Depth 7 | Set-Content -Encoding UTF8 $BaselineFile
  } elseif($legacySnapshot -and $legacySnapshot -ne $BaselineFile) {
    $baseline = Get-Content -Raw $legacySnapshot | ConvertFrom-Json
    $baseline.version = 3
    if(-not $baseline.createdAt){$baseline | Add-Member createdAt $stamp -Force}
    $baseline.modifiedItems = @($baseline.modifiedItems + $ModifiedItems | Select-Object -Unique)
    $baseline | ConvertTo-Json -Depth 7 | Set-Content -Encoding UTF8 $BaselineFile
    Move-Item $legacySnapshot (Join-Path $HistoryDir "migrated-$(Split-Path $legacySnapshot -Leaf)") -Force
  } else {
    $state | ConvertTo-Json -Depth 7 | Set-Content -Encoding UTF8 $BaselineFile
  }
}

function Write-BrowserPrefs {
  foreach ($path in Browser-Paths) {
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    $data = if(Test-Path $path){try{Get-Content -Raw $path | ConvertFrom-Json}catch{[pscustomobject]@{}}}else{[pscustomobject]@{}}
    if(-not $data.intl){$data | Add-Member intl ([pscustomobject]@{})}
    $data.intl | Add-Member accept_languages 'en-US,en' -Force
    $data | Add-Member webrtc ([pscustomobject]@{ip_handling_policy='disable_non_proxied_udp';multiple_routes_enabled=$false;nonproxied_udp_enabled=$false}) -Force
    $data | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 $path
  }
}

function Apply-Changes {
  $allowed = @('system_locale','dns','ipv6','browser_profile')
  $selected = @($Items -split ',' | Where-Object { $_ -and $allowed -contains $_ })
  if(-not $selected.Count){return @{message='No fixable items were selected.'}}
  if(-not $Elevated -and -not (Is-Admin)) {
    $safeItems = $selected -join ','
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action apply -Items `"$safeItems`" -Elevated"
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $args -Wait -PassThru
    if($proc.ExitCode -ne 0){throw "The elevated update failed with exit code $($proc.ExitCode)."}
    return @{message='The elevated update finished. Detecting the environment again.'}
  }
  Save-Snapshot $selected
  if($selected -contains 'system_locale'){tzutil /s $TargetTimezone; Set-Culture $TargetLanguage; Set-WinSystemLocale $TargetLanguage}
  if($selected -contains 'dns'){Active-Adapters | ForEach-Object {Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ('1.1.1.1','1.0.0.1')}}
  if($selected -contains 'ipv6'){Active-Adapters | ForEach-Object {Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 | Out-Null}}
  if($selected -contains 'browser_profile'){Write-BrowserPrefs}
  @{message="Completed: $($selected -join ', '). The original-state snapshot is at $StateFile"}
}

function Restore-Changes {
  $snapshot = Latest-Snapshot
  if(-not $snapshot){return @{message='No original-state snapshot is available. Nothing was changed.'}}
  if(-not $Elevated -and -not (Is-Admin)) {
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action restore -Elevated"
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $args -Wait -PassThru
    if($proc.ExitCode -ne 0){throw "The elevated restore failed with exit code $($proc.ExitCode)."}
    return @{message='The elevated restore finished. Detecting the environment again.'}
  }
  $state = Get-Content -Raw $snapshot | ConvertFrom-Json
  $modified = @($state.modifiedItems); if(-not $modified.Count){$modified=@('system_locale','dns','ipv6','browser_profile')}
  if($modified -contains 'system_locale'){tzutil /s $state.timezone; Set-Culture $state.culture; Set-WinSystemLocale $state.systemLocale}
  foreach($net in $state.network){
    if($modified -contains 'dns'){if($net.dns.Count){Set-DnsClientServerAddress -InterfaceIndex $net.index -ServerAddresses @($net.dns)}else{Set-DnsClientServerAddress -InterfaceIndex $net.index -ResetServerAddresses}}
    if($modified -contains 'ipv6'){if($net.ipv6){Enable-NetAdapterBinding -Name $net.name -ComponentID ms_tcpip6 | Out-Null}else{Disable-NetAdapterBinding -Name $net.name -ComponentID ms_tcpip6 | Out-Null}}
  }
  if($modified -contains 'browser_profile'){foreach($entry in $state.browser){
    if($entry.existed){New-Item -ItemType Directory -Force (Split-Path $entry.path) | Out-Null;[IO.File]::WriteAllBytes($entry.path,[Convert]::FromBase64String($entry.content))}elseif(Test-Path $entry.path){Remove-Item $entry.path}
  }}
  $verification = @()
  if($modified -contains 'system_locale'){
    $verification += @{item='time zone';ok=((tzutil /g).Trim() -eq $state.timezone)}
    $verification += @{item='culture';ok=((Get-Culture).Name -eq $state.culture)}
    $verification += @{item='system locale';ok=((Get-WinSystemLocale).Name -eq $state.systemLocale)}
  }
  if($snapshot -eq $BaselineFile){New-Item -ItemType Directory -Force $HistoryDir | Out-Null; Copy-Item $snapshot (Join-Path $HistoryDir "restored-$($state.createdAt).json") -Force}
  Remove-Item $snapshot -Force
  if($snapshot -ne $BaselineFile){
    New-Item -ItemType Directory -Force $HistoryDir | Out-Null
    if(Test-Path $SnapshotDir){Get-ChildItem $SnapshotDir -Filter '*.json' | ForEach-Object {Move-Item $_.FullName (Join-Path $HistoryDir "legacy-$($_.Name)") -Force}}
    if(Test-Path $StateFile){Move-Item $StateFile (Join-Path $HistoryDir 'legacy-latest-snapshot.json') -Force}
  }
  $failed = @($verification | Where-Object {-not $_.ok} | ForEach-Object {$_.item})
  @{message=$(if($failed.Count){"Restore ran, but verification failed: $($failed -join ', ')"}else{'Restored the baseline captured before the first update. Sign out and back in if Windows has not refreshed the display language.'});verification=$verification}
}

try {
  $result = if($Action -eq 'detect'){Detect-State}elseif($Action -eq 'apply'){Apply-Changes}elseif($Action -eq 'restore'){Restore-Changes}else{@{message='A compatible rule proxy controller is not configured on Windows.';enabled=$false}}
  $result | ConvertTo-Json -Depth 8 -Compress
} catch {
  @{message="Operation failed: $($_.Exception.Message)"} | ConvertTo-Json -Compress
  exit 1
}
