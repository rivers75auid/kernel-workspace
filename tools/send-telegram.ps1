param(
  [string]$BotToken = $env:TELEGRAM_BOT_TOKEN,
  [string]$ChatId = $env:TELEGRAM_CHAT_ID,
  [string[]]$Files = @(
    "output\Kairos-RAM-Management-v2.3.zip",
    "output\fgetpriority_v0.0.5-4.19-fog.zip"
  ),
  [string]$Message = "📦 *Kairos Local Module Release* (Redmi 10C / fog)"
)

$envFile = Join-Path $PSScriptRoot "..\.telegram.env"
if ((!$BotToken -or !$ChatId) -and (Test-Path $envFile)) {
  Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+)$' -and !$BotToken) { $BotToken = $Matches[1].Trim(' "''') }
    if ($_ -match '^\s*TELEGRAM_CHAT_ID\s*=\s*(.+)$' -and !$ChatId) { $ChatId = $Matches[1].Trim(' "''') }
  }
}

if (!$BotToken -or !$ChatId) {
  Write-Error "Set TELEGRAM_BOT_TOKEN & TELEGRAM_CHAT_ID env vars, pass -BotToken / -ChatId, or put them in .telegram.env"
  exit 1
}

$msgUrl = "https://api.telegram.org/bot$BotToken/sendMessage"
$docUrl = "https://api.telegram.org/bot$BotToken/sendDocument"

& curl.exe -sS -X POST $msgUrl -d "chat_id=$ChatId" -d "text=$Message" -d "parse_mode=Markdown" | Out-Null

foreach ($relPath in $Files) {
  $full = Resolve-Path $relPath -ErrorAction SilentlyContinue
  if (!$full) {
    Write-Warning "Skipping missing file: $relPath"
    continue
  }
  $name = Split-Path $full -Leaf
  Write-Host "Uploading $name ..."
  $resp = & curl.exe -sS -F "chat_id=$ChatId" -F "document=@$($full.Path)" -F "caption=📦 $name (local build)" $docUrl
  Write-Host $resp
}
