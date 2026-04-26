55-install-jenkins
==================
let's start now 2026-04-26 (Asia/Kuala_Lumpur)

Title: Jenkins LTS
Method: third-party apt repo
GPG key: https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
Keyring: /usr/share/keyrings/jenkins-keyring.gpg
Repo file: /etc/apt/sources.list.d/55-install-jenkins.list
Apt pkg:   jenkins
Verify:    command -v jenkins || systemctl status jenkins --no-pager 2>/dev/null | head -1
