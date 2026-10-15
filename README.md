# Foundry Hosted Storage Probe

Hosted Python agent that verifies managed-identity access to Azure Blob Storage.
It reads one input blob and writes a deterministic JSON result to another blob.

Downloaded content is treated only as data. The agent does not download or
execute scripts, import downloaded modules, or run commands from blob content.

## How it works

For each invocation, the agent:

1. Authenticates to Blob Storage with its managed identity.
2. Downloads the complete input blob.
3. Creates a JSON result containing the number of bytes read.
4. Uploads that result to the output blob.

The uploaded result has this shape:

```json
{
  "downloaded_code_execution_enabled": false,
  "input_bytes_read": 123,
  "message": "Storage read/write simulation completed.",
  "status": "completed"
}
```

The input and output URLs must be different.

## Prerequisites

- PowerShell 7.2 or later.
- Azure CLI (`az`) for post-run Log Analytics collection and automatic Bastion
  startup when private connectivity is configured.
- Azure Developer CLI (`azd`).
- The `microsoft.foundry` azd extension.
- An existing Microsoft Foundry project.
- An Azure identity that can deploy to and invoke that project.
- For a private Foundry endpoint, an organization-provided SOCKS5 tunnel bound
  only to local loopback.
- For automatic private-tunnel startup on Windows: the existing isolated Azure
  CLI profile, installed Bastion extension, OpenSSH client, SSH identity, and
  pinned `known_hosts` entry for the approved private VM.

## Configure

Create the local configuration file:

```powershell
Copy-Item .env.example .env
```

Edit `.env`:

| Setting | Required | Purpose |
| --- | --- | --- |
| `FOUNDRY_PROJECT_ID` | Yes | Full ARM resource ID shown in **Foundry > Operate > Admin**. |
| `FOUNDRY_AGENT_NAME` | No | Hosted-agent name. |
| `AZD_ENVIRONMENT_NAME` | No | Local azd environment name. |
| `FOUNDRY_AGENT_RUNTIME` | No | Hosted Python runtime (`python_3_13` or `python_3_14`). |
| `FOUNDRY_AZURE_TENANT_ID` | No | User-auth tenant override; otherwise resolved from the azd environment or target subscription. |
| `FOUNDRY_AZURE_SUBSCRIPTION_ID` | No | User-auth subscription override; otherwise resolved from the azd environment or project ID. |
| `FOUNDRY_INPUT_BLOB_PATH` | Yes for invocation | HTTPS URL of the blob to read. |
| `FOUNDRY_OUTPUT_BLOB_PATH` | Yes for invocation | HTTPS destination for the JSON result. |
| `LOG_ANALYTICS_WORKSPACE_ID` | Yes for post-run collection | Log Analytics workspace customer ID GUID. |
| `STORAGE_LOG_ACCOUNT_NAME` | No | Storage account to query; defaults to the account in `FOUNDRY_INPUT_BLOB_PATH`. An explicit mismatch is honored but reported as a collector warning. |
| `STORAGE_LOG_OPERATION_NAME` | No | Storage operation to query. Default: `GetBlob`. |
| `FOUNDRY_AZD_HTTPS_PROXY` | Only for private connectivity | Loopback SOCKS5 URI, such as `socks5://127.0.0.1:1080`. |

If the Foundry endpoint is directly reachable, leave
`FOUNDRY_AZD_HTTPS_PROXY` empty or comment it out.

When a proxy is configured, `deploy-hosted-agent.ps1` reuses an existing
loopback listener. If the listener is absent and all of the following settings
are present, it starts Azure Bastion and strict SSH SOCKS5 forwarding in a
separate deploy-owned host. The host remains running for the subsequent invoke
and collection commands until `stop-foundry-proxy.ps1` requests an orderly
shutdown:

| Setting | Purpose |
| --- | --- |
| `FOUNDRY_BASTION_AZURE_CONFIG_DIR` | Existing isolated Azure CLI profile directory. |
| `FOUNDRY_BASTION_SUBSCRIPTION_ID` | Subscription containing the Bastion host and target VM. |
| `FOUNDRY_BASTION_TENANT_ID` | Expected tenant for the isolated profile. |
| `FOUNDRY_BASTION_RESOURCE_GROUP` | Resource group containing the Bastion host. |
| `FOUNDRY_BASTION_NAME` | Existing Standard or Premium Bastion with native tunneling enabled. |
| `FOUNDRY_BASTION_VM_RESOURCE_ID` | ARM resource ID of the approved private Linux jump VM. |
| `FOUNDRY_BASTION_VM_USER` | Existing VM SSH user. Default: `azureuser`. |
| `FOUNDRY_BASTION_IDENTITY_FILE` | Existing SSH private-key path; key bytes are never read or copied by the script. |
| `FOUNDRY_BASTION_KNOWN_HOSTS_FILE` | Existing OpenSSH trust file. Default: `%USERPROFILE%\.ssh\known_hosts`. |
| `FOUNDRY_BASTION_HOST_KEY_ALIAS` | Existing trusted host alias for the VM. |
| `FOUNDRY_BASTION_TUNNEL_PORT` | Preferred local Bastion-to-SSH port. Default: `2222`; a free high port is selected if busy. |

Automatic startup never logs in, installs the Bastion extension, accepts a host
key, or changes the default Azure account. It validates the explicit
subscription and tenant, current Bastion/VM state, and loopback listener
ownership before exposing the proxy to `azd`. Non-secret ownership state is
written atomically under ignored `run-logs\proxy\`. The host retains the
Windows Job handles that authorize cleanup, so closing the host also closes
both process trees.

`invoke-hosted-agent.ps1` and `collect-run-logs.ps1` validate but do not create
the proxy. They reuse the listener left by deployment when private connectivity
is required.

The Foundry-facing scripts resolve their expected user-auth tenant and
subscription on every run. When `azd` delegates authentication to Azure CLI,
they select a cached matching subscription or, when the context or required
tokens are unavailable, run:

```powershell
az login --use-device-code `
  --tenant '<tenant-id>' `
  --skip-subscription-discovery `
  --subscription '<subscription-id>' `
  --output none
```

The original Azure CLI subscription is restored afterward. Use
`-RefreshAzureLogin` to force a fresh device-code login, for example after an
MFA or tenant change. Scripts and generated metadata retain only tenant and
subscription IDs plus refresh/context status; they never persist access tokens,
device codes, passwords, or other credentials. When authentication is
delegated to Azure CLI, the scripts validate the tenant-scoped ARM and Foundry
tokens while discarding token output.

On Windows, Azure CLI token acquisition can exceed the Foundry extension's
fixed 10-second child-process timeout. Before a Foundry command, the scripts
therefore acquire only the required ARM and/or Foundry scope from Azure CLI and
hold the resulting token JSON in process-local environment variables. The
bundled `tools/azd-token-bridge/azd.cmd` answers only matching nested
`azd auth token` requests and forwards every other command to the resolved
`azd.exe`. The bridge state, token values, and temporary `PATH` change are
restored or removed in `finally`; tokens are never written to metadata or disk.

Do not store Azure credentials, access tokens, SAS tokens, or private keys in
`.env`.

## Deploy

1. Ensure the target tenant and subscription are available through the selected
   azd environment or the `FOUNDRY_AZURE_*` settings. The script validates the
   Azure CLI context and starts device-code login when needed. Pass
   `-RefreshAzureLogin` to force a fresh login.

2. Validate the configuration without uploading a package:

   ```powershell
   .\deploy-hosted-agent.ps1 -Preview
   ```

3. Deploy the hosted agent:

   ```powershell
   .\deploy-hosted-agent.ps1
   ```

   When the configured SOCKS listener is absent, this command automatically
   creates the configured Bastion and SSH forwarding layers and leaves them
   available for invocation and log collection. The tunnel also remains
   available if deployment fails, so a retry uses the same listener.

4. Verify an existing deployment without creating a new version:

   ```powershell
   .\deploy-hosted-agent.ps1 -VerifyOnly
   ```

5. After invocation and collection are complete, explicitly stop only the
   deploy-owned tunnel:

   ```powershell
   .\stop-foundry-proxy.ps1
   ```

   The stop command validates the host process start time and both recorded
   listener owners, writes a session-bound stop signal, and waits for the host
   to dispose its Job objects. It does not terminate a raw PID, does not stop
   an externally managed listener, and reports an error rather than claiming
   success when ownership cannot be proved.

The deployment sends `server_host.py` and `requirements.txt` as a source ZIP.
Foundry resolves the pinned dependencies remotely. Docker and Azure Container
Registry are not used.

## Prepare Blob Storage

1. Choose the input Blob URL. If the blob does not exist, the agent creates it
   as a zero-byte blob before reading it.
2. Choose a different output Blob URL. The agent creates or overwrites this
   blob when it writes the result.
3. Put both HTTPS URLs in `.env`.
4. Grant the hosted runtime's managed identity read and create access to the
   input blob's container and write access to the output blob's container.

For one container holding both blobs, the built-in **Storage Blob Data
Contributor** role at container scope provides the required data actions. The
role must be assigned to the identity used by the hosted runtime, not merely to
the deploying user or another project identity.

The URLs do not need SAS tokens when managed-identity permissions are correct.

## Invoke

After deployment has left the configured proxy tunnel running, invoke the
agent:

```powershell
.\invoke-hosted-agent.ps1
```

The Blob URL parameters remain available as optional, per-run overrides:

```powershell
.\invoke-hosted-agent.ps1 `
  -InputBlobPath 'https://<account>.blob.core.windows.net/<container>/other-input.json' `
  -OutputBlobPath 'https://<account>.blob.core.windows.net/<container>/other-output.json'
```

Optional parameters:

| Parameter | Purpose |
| --- | --- |
| `-InputBlobPath`, `-OutputBlobPath` | Override the corresponding `.env` Blob URL. |
| `-ManagedIdentityClientId <guid>` | Select a user-assigned managed identity. |
| `-RequestTimeoutSeconds <seconds>` | Limit the complete remote invocation. Default: `1800`. |
| `-Raw` | Print the raw HTTP response, including headers. |
| `-AgentName`, `-EnvironmentName`, `-AzdHttpsProxy` | Override the corresponding `.env` value for this invocation. |
| `-AzureTenantId`, `-AzureSubscriptionId` | Override the expected Azure CLI auth context. |
| `-RefreshAzureLogin` | Force `az login --use-device-code` for the expected tenant and subscription before invocation. |
| `-RunMetadataPath` | Override the destination for the last invocation's UTC time window. |

The invocation script creates a temporary JSON request file, calls
`azd ai agent invoke` with the `invocations` protocol, removes the temporary
file, and restores the previous proxy environment. It prints `StartTimeUtc`,
`EndTimeUtc`, and `RunMetadataPath`, then atomically saves the time window and
invocation status to `run-logs\last-invocation.json`. The hosted process keeps
the 100 most recent results in memory so `azd ai agent invocations show` can
retrieve a completed result while that hosted session remains active.

## Collect post-run logs

Storage diagnostics are written to the configured Log Analytics workspace.
The agent's `stdout` and `stderr` are emitted by the remote hosted runtime in
Foundry, not by the local PowerShell process. After an invocation, collect both
sources into one local evidence directory:

```powershell
.\invoke-hosted-agent.ps1
.\collect-run-logs.ps1
```

The collector gets the workspace ID, storage account, and operation name from
`.env`. When time parameters are omitted, it reads `StartTimeUtc` and
`EndTimeUtc` from `run-logs\last-invocation.json`. Every value can still be
overridden per run:

```powershell
.\collect-run-logs.ps1 `
  -WorkspaceId '<workspace-customer-id-guid>' `
  -AccountName 'rsgchanneln20testaisa' `
  -OperationName 'GetBlob' `
  -StartTimeUtc '2026-10-13T00:00:55Z' `
  -EndTimeUtc '2026-10-13T15:49:15Z'
```

Storage queries include 30 seconds before and after the invocation window by
default to tolerate clock skew between the caller, hosted container, and
Storage service. Use `-StorageTimePaddingSeconds 0` for exact bounds, or any
value through 300 seconds when a wider correlation window is required.

The current Azure CLI identity needs query access to the workspace, and the
Storage account must send resource logs to the `StorageBlobLogs` table. To find
the workspace customer ID, first sign in with `az login`, then run:

```powershell
az monitor log-analytics workspace show `
  --resource-group '<resource-group>' `
  --workspace-name '<workspace-name>' `
  --query customerId `
  --output tsv
```

Each timestamped directory under `run-logs/` contains:

- The detailed Storage request results and aggregate latency statistics in both
  JSON and CSV.
- The exact KQL used for both queries and separate Azure CLI error logs.
- The latest retained Foundry invocation result.
- Foundry console logs (`stdout`/`stderr`) and hosted-session system events,
  retrieved with `azd ai agent monitor`.
- `collector.log` for the collection run itself and `manifest.json` describing
  its inputs, outputs, command durations, row counts, and final status.

By default, Foundry commands resolve the latest invocation and its session.
Use `-InvocationId` or `-SessionId` to target explicit IDs. Pass both
`-StartTimeUtc` and `-EndTimeUtc` to override the saved invocation window. Use
`-SkipFoundryLogs` to collect only Storage diagnostics, or
`-WaitForIngestionSeconds` when running immediately after an invocation.
When `FOUNDRY_AZD_HTTPS_PROXY` is configured, the collector validates the
existing loopback listener and applies it only to the Foundry `azd` commands;
the Azure CLI Storage queries remain direct. Use `-AzdHttpsProxy` to override
the configured proxy for a collection run. The collector also pins its Azure
CLI queries to the resolved subscription. If a read-only Foundry retrieval
reports an `AzureDeveloperCLICredential` failure, it revalidates the required
Azure CLI tokens, refreshes the process-local token bridge on Windows (or
re-primes `azd` on other platforms), and retries once. It starts device-code
login only when those tokens are unavailable. Use
`-AzureTenantId`, `-AzureSubscriptionId`, or `-RefreshAzureLogin` to override
or refresh the auth context explicitly. If the locally saved invocation ID
has expired and Foundry returns HTTP 404, or the extension reports that no
current invocation is saved, the manifest is marked
`completed_with_warnings` and the collector continues retrieving console and
system logs. The manifest records whether the process-local token bridge was
used, but never records the token or device code. Storage-account mismatches,
empty Storage query results, and authentication recovery also mark the
manifest `completed_with_warnings`.

## Troubleshooting

- **`AuthorizationPermissionMismatch`:** the hosted runtime authenticated, but
  its principal lacks a Blob data action required for the attempted read or
  write. Check the runtime principal and its data-plane role assignment.
- **Automatic proxy startup is not configured:** populate every
  `FOUNDRY_BASTION_*` setting, start an approved loopback tunnel manually, or
  clear `FOUNDRY_AZD_HTTPS_PROXY` when direct connectivity is supported.
- **Device-code login remains pending or expires:** rerun the script with
  `-RefreshAzureLogin`, open the displayed device-login page, and enter the new
  code before it expires. The script does not save the code.
- **Bastion or SSH startup fails:** verify the isolated Azure CLI profile is
  already signed in to the configured subscription and tenant, the Bastion
  extension is installed, the Bastion has native tunneling enabled, and the
  configured identity and pinned host alias already exist. The script does not
  repair authentication, extensions, or host trust.
- **A prior deploy-owned proxy must be closed:** run
  `.\stop-foundry-proxy.ps1`. If ownership state is stale but both recorded
  ports are closed, the command removes only the stale state. If a recorded
  port is still active but ownership cannot be verified, it refuses to stop
  anything.
- **Deployment targets the wrong project:** check `FOUNDRY_PROJECT_ID`,
  `AZD_ENVIRONMENT_NAME`, and the generated `azure.yaml`.
- **Storage queries return no rows:** ensure `STORAGE_LOG_ACCOUNT_NAME`
  identifies the account used by the Blob URL and that diagnostic settings on
  that account's `blobServices/default` resource send read/write/delete logs
  to `LOG_ANALYTICS_WORKSPACE_ID`.
- **`ModuleNotFoundError: No module named 'agents'` during startup:** this is an
  optional OpenAI Agents instrumentation warning from the hosted telemetry
  stack. This storage probe does not use that SDK; confirm the host continues
  to `AgentServerHost started` and the invocation returns HTTP 200.
- **A `GetBlob` request reports 416 and is immediately followed by 200:** the
  Blob SDK is probing a zero-byte input with a ranged request and recovering
  with a full request. The completed 200 response is the probe outcome.

## Public repository safety

- `.env`, `.azure/`, and generated `azure.yaml` are ignored by Git.
- `.env.example` contains placeholders and is safe to commit.
- Azure CLI or azd stores authentication outside this repository; these scripts
  persist only non-secret tenant/subscription identifiers and refresh status.
- Bastion resource identifiers and SSH file paths belong only in ignored
  `.env`; private-key and Azure CLI profile contents are never copied.
- The deployment ZIP contains only `server_host.py` and `requirements.txt`.
- Request bodies are not logged.
- Logged URLs exclude query strings and fragments so SAS tokens are not printed.
- Generated post-run evidence under `run-logs/` is ignored by Git.

## Local validation

```powershell
py -3.14 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m py_compile server_host.py
```

## Profiling

The host records DNS, connection, identity, and Blob Storage request timing.
