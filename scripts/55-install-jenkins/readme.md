<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Script 55 — Install Jenkins" width="128" height="128"/>

# Script 55 — Install Jenkins

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Script](https://img.shields.io/badge/Script-55-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.80.0-f97316)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v6-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6)

*Mandatory spec header — see [spec/00-spec-writing-guide](../00-spec-writing-guide/readme.md).*

</div>

---

## Overview

Implementation folder for **Script 55 — Install Jenkins**. Installs Jenkins LTS via Chocolatey, verifies the Java prerequisite (17+), starts the Jenkins Windows service, and prints the initial admin password and login URL.

## Quick start

```powershell
# From repo root
.\run.ps1 -I 55 install
```

## Subcommands

| Command | What it does |
|---------|--------------|
| `all` (default) | Java check → install → service check → PATH → initial password |
| `install` | Install/upgrade Jenkins only |
| `status` | Show service status + initial admin password |
| `uninstall` | Stop service, uninstall package, purge tracking |

## Layout

| File | Purpose |
|------|---------|
| `run.ps1` | Entry point dispatched by the root `run.ps1`. |
| `config.json` | External config (service name, port, Java min version). |
| `log-messages.json` | All user-facing messages. |
| `helpers/jenkins.ps1` | Internal PowerShell helpers. |

## See also

- [Script 40 — Install Java](../40-install-java/readme.md) (prerequisite)
- [Script 45 — Install Docker](../45-install-docker/readme.md) (sister CI/CD installer)
- [Changelog](../../changelog.md)

---

<!-- spec-footer:v1 -->

## License

This project is licensed under the **MIT License** — see the [LICENSE](../../LICENSE) file for the full text.

```
Copyright (c) 2026 Alim Ul Karim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)