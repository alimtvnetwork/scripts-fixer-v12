41-install-python-libs
======================
let's start now 2026-04-26 (Asia/Kuala_Lumpur)

Title:    Python 3 + AI/data base libraries (numpy, pandas, scikit-learn, jupyterlab, fastapi)
Method:   apt for python3/venv/pip + dedicated venv at ~/.venvs/ai-base for pip libs
Why venv: PEP 668 (externally-managed-environment) blocks system-wide pip on modern Ubuntu.
Verify:   python3 --version && ~/.venvs/ai-base/bin/python -c 'import numpy,pandas,sklearn'
