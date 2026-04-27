param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Argv=@())
$dry = ($Argv -contains "--dry-run")
$counter = "$env:HOME/.stub-65-counter"
if (-not (Test-Path $counter)) { "0" | Set-Content $counter }
$n = [int](Get-Content $counter)
$n++
"$n" | Set-Content $counter
if ($dry) {
  if ($n -le 1) {
    # First dry-run = PLAN stage: 3 categories with rows.
    Write-Host "[ WOULD  ] chrome  (count=12 bytes=3,408,221)"
    Write-Host "[ WOULD  ] edge    (count=4  bytes=1,024,000)"
    Write-Host "[ WOULD  ] recycle (count=7  bytes=999,999)"
  } else {
    # Subsequent dry-run = VERIFY: 2 of 3 fully cleaned, edge has residue 1.
    Write-Host "[ WOULD  ] edge    (count=1  bytes=1,024)"
  }
  exit 0
}
Write-Host "[ DELETE ] chrome  (count=12 bytes=3,408,221)"
Write-Host "[ DELETE ] edge    (count=3  bytes=900,000)"
Write-Host "[ DELETE ] recycle (count=7  bytes=999,999)"
exit 0
