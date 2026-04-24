<!-- spec-header:v1 -->
<div align="center">

<img src="../../assets/icon-v1-rocket-stack.svg" alt="Script 54 — Vscode Menu Installer" width="128" height="128"/>

# Script 54 — Vscode Menu Installer

**Part of the Dev Tools Setup Scripts toolkit**

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6#requirements)
[![Script](https://img.shields.io/badge/Script-54-8b5cf6)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/registry.json)
[![License](https://img.shields.io/badge/License-MIT-eab308)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/LICENSE)
[![Version](https://img.shields.io/badge/Version-v0.70.0-f97316)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/scripts/version.json)
[![Changelog](https://img.shields.io/badge/Changelog-Latest-ec4899)](https://github.com/alimtvnetwork/gitmap-v6/blob/main/changelog.md)
[![Repo](https://img.shields.io/badge/Repo-gitmap--v6-22c55e?logo=github&logoColor=white)](https://github.com/alimtvnetwork/gitmap-v6)

*Mandatory spec header — see [spec/00-spec-writing-guide](../00-spec-writing-guide/readme.md).*

</div>

---

## Overview

Implementation folder for **Script 54 — Vscode Menu Installer**. The full design contract lives in the spec.

## Quick start

```powershell
# From repo root
.\run.ps1 -I 54 install
```

## Layout

| File | Purpose |
|------|---------|
| `run.ps1` | Entry point dispatched by the root `run.ps1`. |
| `config.json` | External config (paths, toggles, edition list). |
| `log-messages.json` | All user-facing messages (kept out of code). |
| `helpers/` | Internal PowerShell helper modules. |
| `.audit/` | Auto-created at runtime. One JSONL file per install/uninstall run, recording every registry key added or removed (timestamped, gitignored). |

## Audit log

Every install and uninstall run writes a timestamped audit file to
`scripts/54-vscode-menu-installer/.audit/`:

```
.audit/audit-install-20260424-101523.jsonl
.audit/audit-uninstall-20260424-101742.jsonl
```

Each line is one JSON record. Operations recorded:

| `operation` | When |
|---|---|
| `session-start` | First line of every file -- captures host / user / pid. |
| `add` | A registry key + values were just written. Includes `(Default)`, `Icon`, and `command`. |
| `remove` | A key that existed was deleted. |
| `skip-absent` | Uninstall asked to remove a key that was already gone. |
| `fail` | Write or delete attempt failed; `reason` field has the error. |

Useful queries:

```powershell
# What did the last install touch?
Get-Content (Get-ChildItem .audit\audit-install-*.jsonl | Sort LastWriteTime | Select -Last 1) |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object operation -eq 'add' |
    Select-Object ts, edition, target, regPath

# Diff two runs
code --diff .audit\audit-install-<old>.jsonl .audit\audit-install-<new>.jsonl
```

## See also

- [Full spec](../../spec/54-vscode-menu-installer/readme.md)
- [Spec writing guide](../../spec/00-spec-writing-guide/readme.md)
- [Changelog](../../changelog.md)


---

<!-- spec-footer:v1 -->

## Author

<div align="center">

### [Md. Alim Ul Karim](https://www.google.com/search?q=alim+ul+karim)

**[Creator & Lead Architect](https://alimkarim.com)** | [Chief Software Engineer](https://www.google.com/search?q=alim+ul+karim), [Riseup Asia LLC](https://riseup-asia.com)

</div>

A system architect with **20+ years** of professional software engineering experience across enterprise, fintech, and distributed systems. His technology stack spans **.NET/C# (18+ years)**, **JavaScript (10+ years)**, **TypeScript (6+ years)**, and **Golang (4+ years)**.

Recognized as a **top 1% talent at Crossover** and one of the top software architects globally. He is also the **Chief Software Engineer of [Riseup Asia LLC](https://riseup-asia.com/)** and maintains an active presence on **[Stack Overflow](https://stackoverflow.com/users/513511/md-alim-ul-karim)** (2,452+ reputation, 961K+ reached, member since 2010) and **LinkedIn** (12,500+ followers).

| | |
|---|---|
| **Website** | [alimkarim.com](https://alimkarim.com/) · [my.alimkarim.com](https://my.alimkarim.com/) |
| **LinkedIn** | [linkedin.com/in/alimkarim](https://linkedin.com/in/alimkarim) |
| **Stack Overflow** | [stackoverflow.com/users/513511/md-alim-ul-karim](https://stackoverflow.com/users/513511/md-alim-ul-karim) |
| **Google** | [Alim Ul Karim](https://www.google.com/search?q=Alim+Ul+Karim) |
| **Role** | Chief Software Engineer, [Riseup Asia LLC](https://riseup-asia.com) |

### Riseup Asia LLC — Top Software Company in Wyoming, USA

[Riseup Asia LLC](https://riseup-asia.com) is a **top-leading software company headquartered in Wyoming, USA**, specializing in building **enterprise-grade frameworks**, **research-based AI models**, and **distributed systems architecture**. The company follows a **"think before doing"** engineering philosophy — every solution is researched, validated, and architected before implementation begins.

**Core expertise includes:**

- 🏗️ **Framework Development** — Designing and shipping production-grade frameworks used across enterprise and fintech platforms
- 🧠 **Research-Based AI** — Inventing and deploying AI models grounded in rigorous research methodologies
- 🔬 **Think Before Doing** — A disciplined engineering culture where architecture, planning, and validation precede every line of code
- 🌐 **Distributed Systems** — Building scalable, resilient systems for global-scale applications

| | |
|---|---|
| **Website** | [riseup-asia.com](https://riseup-asia.com) |
| **Facebook** | [riseupasia.talent](https://www.facebook.com/riseupasia.talent/) |
| **LinkedIn** | [Riseup Asia](https://www.linkedin.com/company/105304484/) |
| **YouTube** | [@riseup-asia](https://www.youtube.com/@riseup-asia) |

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](../../LICENSE) file for the full text.

```
Copyright (c) 2026 Alim Ul Karim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](../../LICENSE)

---

<div align="center">

*Part of the Dev Tools Setup Scripts toolkit — see the [spec writing guide](../../spec/00-spec-writing-guide/readme.md) for the full readme contract.*

</div>
