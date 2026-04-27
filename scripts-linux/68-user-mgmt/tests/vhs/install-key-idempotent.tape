# vhs tape — install-key idempotency demo
# render: vhs scripts-linux/68-user-mgmt/tests/vhs/install-key-idempotent.tape

Output install-key-idempotent.gif

Set FontSize 14
Set Width 1100
Set Height 600
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms

Type "# first run — appends the key"
Enter
Type "bash scripts-linux/68-user-mgmt/run.sh install-key --user demo --key-file /tmp/demo.pub --dry-run"
Enter
Sleep 1500ms
Type "# second run — body match, skipped"
Enter
Type "bash scripts-linux/68-user-mgmt/run.sh install-key --user demo --key-file /tmp/demo.pub --dry-run"
Enter
Sleep 2s