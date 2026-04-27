param([Parameter(ValueFromRemainingArguments=\$true)][string[]]\$Argv=@())
# Stub delegate: emit a deterministic plan in dry-run, and an empty plan in apply.
\$dry = (\$Argv -contains "--dry-run")
if (\$dry) {
  Write-Host "[ WOULD  ] chrome  (count=12 bytes=3,408,221)"
  Write-Host "[ WOULD  ] edge    (count=4  bytes=1,024,000)"
  Write-Host "[ WOULD  ] recycle (count=7  bytes=999,999)"
  exit 0
}
# Apply: just print three [ DELETE ] lines and exit 0.
Write-Host "[ DELETE ] chrome  (count=12 bytes=3,408,221)"
Write-Host "[ DELETE ] edge    (count=4  bytes=1,024,000)"
Write-Host "[ DELETE ] recycle (count=7  bytes=999,999)"
exit 0
