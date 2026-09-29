# Repository Index

## Functional areas
- Hosted agent API and blob-backed script execution: `server_host.py`

## Technical layers
- Entry point: `server_host.py` creates `InvocationAgentServerHost` and registers `invoke`.
- Azure clients: managed identity authentication and Blob Storage download/upload helpers.
- Execution: downloaded Python scripts run in a temporary directory via `subprocess.run`.

## Navigation
- Change request handling, Azure API calls, execution, or responses: `server_host.py`
- Generated-file and local-environment exclusions: `.gitignore`

## Conventions
- Python bytecode, virtual environments, tool caches, coverage/build output, local `.env` files, and editor metadata are ignored.

## Validation
- Run Python syntax/compile checks against `server_host.py`.

## Freshness
- Refreshed 2026-09-29 after adding `.gitignore`.
