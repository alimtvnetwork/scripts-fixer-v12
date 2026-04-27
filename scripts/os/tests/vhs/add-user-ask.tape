# vhs tape — Windows add-user with --ask
# render: vhs scripts/os/tests/vhs/add-user-ask.tape
# requires pwsh in PATH

Output add-user-ask.gif

Set Shell "pwsh"
Set FontSize 14
Set Width 1100
Set Height 540
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Type "pwsh scripts/os/run.ps1 add-user --ask --dry-run"
Enter
Sleep 600ms
Type "demo-user"
Enter
Sleep 400ms
Type "demo passphrase"
Enter
Sleep 400ms
Type "Demo Account (vhs)"
Enter
Sleep 400ms
Type "y"
Enter
Sleep 2s