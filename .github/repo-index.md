# Repository Index

## Functional areas

- Hosted agent API and Blob Storage read/write probe: `server_host.py`
- Existing-project source ZIP deployment and persistent private-path bootstrap: `deploy-hosted-agent.ps1`, `BastionOwnedProcess.cs`, `foundry-proxy-control.ps1`, `stop-foundry-proxy.ps1`, `.env.example`, `requirements.txt`, `.agentignore`
- Tenant-aware Azure CLI context validation, device-code refresh, and process-local extension token bridging: `azure-cli-auth.ps1`, `tools/azd-token-bridge/azd.cmd`
- Remote hosted-agent invocation: `invoke-hosted-agent.ps1`
- Post-run Storage and Foundry evidence collection: `collect-run-logs.ps1`
- Hosted invocation contract and retention tests: `tests/test_server_host.py`
- Profiling approach and Microsoft references: `README.md`

## Technical layers

- Entry point: `server_host.py` creates `InvocationAgentServerHost`, publishes its OpenAPI contract, registers create/get handlers, and retains the 100 most recent synchronous results in process memory.
- Azure clients: managed identity authentication and Blob Storage download/upload helpers.
- Storage probe: input content is downloaded as data, a deterministic JSON summary is generated, and the summary is uploaded; downloaded content is never executed.
- Deployment: PowerShell validates the expected user-auth tenant/subscription, initializes an `azure.ai.agent` code service, validates the non-container configuration, reuses or creates an approved Bastion -> strict SSH loopback SOCKS proxy, scopes `azd` to that proxy, and runs `azd deploy`; Foundry resolves pinned Python dependencies with `remote_build`.
- Tunnel ownership: `BastionOwnedProcess.cs` launches the Azure Bastion and OpenSSH process trees in Windows Job objects. A separate deployment-started PowerShell host retains the Job handles after deploy exits, writes non-secret atomic ownership state under ignored `run-logs/proxy/`, and accepts only its session-bound stop signal. `stop-foundry-proxy.ps1` verifies the recorded host start time and listener owners before signaling that host to dispose both Jobs.
- Azure CLI user auth: shared PowerShell resolves the project tenant/subscription, reuses or selects cached matching context, uses tenant-scoped device-code login only when needed or forced, validates required token scopes, and restores the caller's original subscription without persisting credentials. On Windows it pre-acquires only required ARM/Foundry scopes and temporarily routes matching nested `azd auth token` calls through `tools/azd-token-bridge/azd.cmd`, avoiding the Azure Identity 10-second child timeout; token values remain process-local and are restored or removed in `finally`.
- Invocation: PowerShell validates Blob URLs and the optional loopback SOCKS proxy, validates delegated Azure CLI auth, writes a short-lived JSON request, calls `azd ai agent invoke` with the `invocations` protocol, and persists the UTC invocation window plus non-secret auth context to ignored last-run metadata.
- Evidence collection: PowerShell resolves Storage filters from `.env`, warns when an explicit account differs from the input Blob account, pads the invocation window for cross-system clock skew, pins bounded `StorageBlobLogs` detail and statistics queries to the resolved subscription, exports JSON/CSV/KQL, and retrieves the latest or explicitly selected Foundry invocation plus console and system logs through `azd` using the validated loopback proxy when configured; a credential failure on the read-only invocation lookup first revalidates cached tokens and refreshes the Windows token bridge (or re-primes `azd` elsewhere), starts device-code login only when token validation fails, and retries once. HTTP 404 or no-saved-invocation results are warnings that do not block console/system log retrieval.

## Navigation

- Change request handling, Azure API calls, execution, or responses: `server_host.py`
- Deploy or preview the agent against an existing Foundry project: `deploy-hosted-agent.ps1`
- Stop a deploy-owned persistent Bastion/SSH proxy: `stop-foundry-proxy.ps1`
- Change persistent proxy state, host verification, or atomic control files: `foundry-proxy-control.ps1`
- Change automatic Bastion/SSH process containment: `deploy-hosted-agent.ps1`, `BastionOwnedProcess.cs`
- Change Azure CLI tenant selection, device-code refresh, scoped token bridging, or context restoration: `azure-cli-auth.ps1`, `tools/azd-token-bridge/azd.cmd`
- Invoke the deployed agent with input and output Blob URLs: `invoke-hosted-agent.ps1`
- Collect post-run Storage diagnostics, Foundry logs, and a local manifest: `collect-run-logs.ps1`
- Change or validate hosted invocation create/get behavior: `server_host.py`, `tests/test_server_host.py`
- Configure local deployment values safely: `.env.example`
- Change hosted runtime dependencies or ZIP contents: `requirements.txt`, `.agentignore`
- Understand Azure SDK API profiling: `README.md`
- Understand deployment prerequisites and usage: `README.md`
- Generated-file and local-environment exclusions: `.gitignore`

## Conventions

- Python bytecode, virtual environments, tool caches, coverage/build output, local `.env` files, and editor metadata are ignored; `.env.example` is the public template.
- Local azd state under `.azure/` and generated project-specific `azure.yaml` are ignored.
- Generated evidence bundles under `run-logs/` are ignored.
- Private Foundry deployment connectivity uses process-local `HTTPS_PROXY` plus direct identity/ARM bypasses. The deploy script reuses an existing loopback listener or validates the isolated Azure profile, Bastion, VM, SSH identity, and pinned host trust before creating owned tunnel processes; it restores proxy variables while its independent owner host keeps the tunnel available for invoke and collect.
- Automatic tunnel startup never logs into or changes the isolated Bastion profile, installs the Bastion extension, or accepts host keys. A deploy-created tunnel persists until `stop-foundry-proxy.ps1` verifies ownership and signals the host; external listeners are never claimed or stopped.
- Foundry-facing scripts may device-code-refresh the default Azure CLI profile, but record no credentials and restore the original subscription after the operation.
- The Windows token bridge answers only pre-acquired `https://ai.azure.com/.default` and `https://management.azure.com/.default` child requests, forwards all other `azd` commands, and never writes token values to disk or metadata.
- Invocation payloads use a uniquely named system temporary file that is removed on exit.
- Invocation timing metadata contains no request body or Blob URL and is atomically replaced under ignored `run-logs/`.
- Completed invocation results are retained only in bounded process memory and disappear when the hosted session restarts.
- Foundry invocation and collection commands scope the optional loopback proxy to their `azd` calls and restore the caller's proxy environment afterward.
- Downloaded Blob content is data-only and must never be imported or executed.
- Source deployment must retain `codeConfiguration`, `remote_build`, and the `invocations` protocol and must not add image, Docker, or ACR configuration.

## Validation

- Create a Python 3.14 virtual environment, install `requirements.txt`, and run `pip check`, `python -m unittest discover -s tests -v`, plus source compile/import smoke checks.
- Parse the PowerShell scripts, compile `BastionOwnedProcess.cs`, validate generated `azure.yaml` before deployment, and use fake `az`/`azd` commands to verify invocation metadata and the no-argument post-run collection flow.
- Exercise `deploy-hosted-agent.ps1 -VerifyOnly` with an unused SOCKS port to verify real Bastion/SSH startup, Foundry access, cross-command listener reuse, and explicit listener removal through `stop-foundry-proxy.ps1` without creating an agent version.

## Freshness

- Refreshed 2026-10-15 after adding a persistent deploy-owned proxy host, session-bound explicit stop control, process-local Foundry extension token bridging, bounded invocation result retrieval, OpenAPI metadata, and Storage collector correlation warnings.
