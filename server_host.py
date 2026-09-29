print("STARTUP", flush=True)

import json
import itertools
import os
import sys
import time
import uuid
import tempfile
import subprocess
from datetime import datetime, timezone
from typing import Any, Dict, Optional
from urllib.parse import urlsplit, urlunsplit

from azure.ai.agentserver.invocations import InvocationAgentServerHost
from azure.core.pipeline.policies import SansIOHTTPPolicy
from azure.storage.blob import BlobClient, ContentSettings
from azure.identity import ManagedIdentityCredential
from starlette.requests import Request
from starlette.responses import JSONResponse


app = InvocationAgentServerHost()


class RequestResponseProfilerPolicy(SansIOHTTPPolicy):
    """Log timestamps and elapsed time for each Azure SDK HTTP call."""

    _call_ids = itertools.count(1)
    _context_key = "request_response_profiler"

    @staticmethod
    def _safe_url(url: str) -> str:
        parsed = urlsplit(url)
        return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))

    @staticmethod
    def _utc_timestamp() -> str:
        return datetime.now(timezone.utc).isoformat(timespec="milliseconds")

    def on_request(self, request) -> None:
        http_request = request.http_request
        call_id = next(self._call_ids)
        profile = {
            "call_id": call_id,
            "method": http_request.method,
            "url": self._safe_url(http_request.url),
            "started_at": self._utc_timestamp(),
            "started_perf": time.perf_counter(),
        }
        request.context[self._context_key] = profile

        print(
            "HTTP_PROFILE request "
            f"id={call_id} timestamp={profile['started_at']} "
            f"method={profile['method']} url={profile['url']}",
            flush=True,
        )

    def on_response(self, request, response) -> None:
        profile = request.context.get(self._context_key, {})
        duration_ms = self._duration_ms(profile)
        print(
            "HTTP_PROFILE response "
            f"id={profile.get('call_id', '?')} timestamp={self._utc_timestamp()} "
            f"status={response.http_response.status_code} duration_ms={duration_ms:.2f} "
            f"method={profile.get('method', '?')} url={profile.get('url', '<unknown>')}",
            flush=True,
        )

    def on_exception(self, request) -> None:
        profile = request.context.get(self._context_key, {})
        duration_ms = self._duration_ms(profile)
        print(
            "HTTP_PROFILE exception "
            f"id={profile.get('call_id', '?')} timestamp={self._utc_timestamp()} "
            f"duration_ms={duration_ms:.2f} method={profile.get('method', '?')} "
            f"url={profile.get('url', '<unknown>')}",
            flush=True,
        )

    @staticmethod
    def _duration_ms(profile: Dict[str, Any]) -> float:
        started_perf = profile.get("started_perf")
        if not isinstance(started_perf, (int, float)):
            return 0.0
        return (time.perf_counter() - started_perf) * 1000


# Expected request payload:
#
# {
#   "input_blob_path": "https://<account>.blob.core.windows.net/<container>/<input-file>",
#   "script_blob_path": "https://<account>.blob.core.windows.net/<container>/<script-file>.py",
#   "output_blob_path": "https://<account>.blob.core.windows.net/<container>/<output-file>",
#   "timeout_seconds": 120
# }
#
# Optional:
# {
#   "managed_identity_client_id": "<client-id-if-user-assigned-identity-is-required>"
# }


def get_credential(payload: Dict[str, Any]) -> ManagedIdentityCredential:
    managed_identity_client_id = payload.get("managed_identity_client_id")
    profiler_policy = RequestResponseProfilerPolicy()
    client_options = {
        "_per_retry_policies": [profiler_policy],
        "per_retry_policies": [profiler_policy],
    }

    if managed_identity_client_id:
        return ManagedIdentityCredential(
            client_id=managed_identity_client_id,
            **client_options,
        )

    credential = ManagedIdentityCredential(**client_options)
    credential.get_token("https://storage.azure.com/.default")


    return credential


def get_required_string(payload: Dict[str, Any], name: str) -> str:
    value = payload.get(name)

    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Missing or invalid required field: {name}")

    return value.strip()


def download_blob_to_file(blob_url: str, local_path: str, credential: ManagedIdentityCredential) -> int:
    blob_client = BlobClient.from_blob_url(
        blob_url=blob_url,
        credential=credential,
        _additional_pipeline_policies=[RequestResponseProfilerPolicy()],
    )

    stream = blob_client.download_blob()
    content = stream.readall()

    with open(local_path, "wb") as file:
        file.write(content)

    return len(content)


def upload_file_to_blob(
    local_path: str,
    blob_url: str,
    credential: ManagedIdentityCredential,
    content_type: Optional[str] = None
) -> int:
    blob_client = BlobClient.from_blob_url(
        blob_url=blob_url,
        credential=credential,
        _additional_pipeline_policies=[RequestResponseProfilerPolicy()],
    )

    with open(local_path, "rb") as file:
        data = file.read()

    kwargs = {
        "data": data,
        "overwrite": True
    }

    if content_type:
        kwargs["content_settings"] = ContentSettings(content_type=content_type)

    blob_client.upload_blob(**kwargs)

    return len(data)


def write_text_to_file(local_path: str, text: str) -> int:
    data = text.encode("utf-8")

    with open(local_path, "wb") as file:
        file.write(data)

    return len(data)


def extract_payload(request_json: Dict[str, Any]) -> Dict[str, Any]:
    """
    Supports a direct payload and a few common wrapper shapes.

    Direct:
      {
        "input_blob_path": "...",
        "script_blob_path": "...",
        "output_blob_path": "..."
      }

    Wrapped:
      {
        "input": {
          "input_blob_path": "...",
          "script_blob_path": "...",
          "output_blob_path": "..."
        }
      }

    Content string:
      {
        "input": "{\"input_blob_path\":\"...\"}"
      }
    """

    if all(key in request_json for key in ["input_blob_path", "script_blob_path", "output_blob_path"]):
        return request_json

    input_value = request_json.get("input")

    if isinstance(input_value, dict):
        return input_value

    if isinstance(input_value, str):
        try:
            parsed = json.loads(input_value)
            if isinstance(parsed, dict):
                return parsed
        except json.JSONDecodeError:
            pass

    raise ValueError(
        "Request must include input_blob_path, script_blob_path, and output_blob_path "
        "either at the top level or inside an input object."
    )


def run_downloaded_python_script(
    script_path: str,
    input_path: str,
    output_path: str,
    working_dir: str,
    timeout_seconds: int
) -> subprocess.CompletedProcess:
    """
    Contract for the downloaded script:

    The downloaded script is executed as:

      python downloaded_script.py <input_file_path> <output_file_path>

    Preferred behavior:
      The downloaded script reads sys.argv[1] and writes its file result to sys.argv[2].

    Fallback behavior:
      If the script does not write sys.argv[2], this host uploads stdout instead.
    """

    return subprocess.run(
        [sys.executable, script_path, input_path, output_path],
        cwd=working_dir,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
        check=False
    )


def build_response(
    status: str,
    content: str,
    response_id: Optional[str] = None,
    extra: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    body = {
        "id": response_id or f"resp_{uuid.uuid4().hex}",
        "object": "response",
        "output": [
            {
                "type": "message",
                "role": "assistant",
                "content": content
            }
        ],
        "status": status
    }

    if extra:
        body["metadata"] = extra

    return body


@app.invoke_handler
async def invoke(request: Request):
    print("***** INVOKE HANDLER EXECUTED *****", flush=True)

    raw_body = await request.body()
    print(f"REQUEST BODY: {raw_body}", flush=True)

    try:
        request_json = json.loads(raw_body.decode("utf-8")) if raw_body else {}
        payload = extract_payload(request_json)

        input_blob_path = get_required_string(payload, "input_blob_path")
        script_blob_path = get_required_string(payload, "script_blob_path")
        output_blob_path = get_required_string(payload, "output_blob_path")

        timeout_seconds = int(payload.get("timeout_seconds", 120))
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be greater than zero")

        credential = get_credential(payload)

        with tempfile.TemporaryDirectory(prefix="foundry_script_exec_") as work_dir:
            input_file_path = os.path.join(work_dir, "input_file")
            script_file_path = os.path.join(work_dir, "script_to_run.py")
            output_file_path = os.path.join(work_dir, "output_file")

            input_bytes = download_blob_to_file(
                blob_url=input_blob_path,
                local_path=input_file_path,
                credential=credential
            )

            script_bytes = download_blob_to_file(
                blob_url=script_blob_path,
                local_path=script_file_path,
                credential=credential
            )

            result = run_downloaded_python_script(
                script_path=script_file_path,
                input_path=input_file_path,
                output_path=output_file_path,
                working_dir=work_dir,
                timeout_seconds=timeout_seconds
            )

            if result.returncode != 0:
                error_text = (
                    "Downloaded script failed.\n\n"
                    f"Return code: {result.returncode}\n\n"
                    f"STDOUT:\n{result.stdout}\n\n"
                    f"STDERR:\n{result.stderr}"
                )

                response = build_response(
                    status="failed",
                    content=error_text,
                    response_id="resp_script_failed",
                    extra={
                        "input_bytes_downloaded": input_bytes,
                        "script_bytes_downloaded": script_bytes
                    }
                )

                print(f"RESPONSE: {response}", flush=True)
                return JSONResponse(response)

            if os.path.exists(output_file_path) and os.path.getsize(output_file_path) > 0:
                uploaded_bytes = upload_file_to_blob(
                    local_path=output_file_path,
                    blob_url=output_blob_path,
                    credential=credential,
                    content_type="application/octet-stream"
                )

                output_source = "script output file"
            else:
                uploaded_bytes = write_text_to_file(output_file_path, result.stdout)

                upload_file_to_blob(
                    local_path=output_file_path,
                    blob_url=output_blob_path,
                    credential=credential,
                    content_type="text/plain; charset=utf-8"
                )

                output_source = "script stdout"

            response = build_response(
                status="completed",
                content=(
                    "Script execution completed successfully. "
                    f"Uploaded {uploaded_bytes} bytes to the output blob."
                ),
                response_id="resp_script_completed",
                extra={
                    "input_bytes_downloaded": input_bytes,
                    "script_bytes_downloaded": script_bytes,
                    "uploaded_bytes": uploaded_bytes,
                    "output_source": output_source
                }
            )

    except Exception as ex:
        response = build_response(
            status="failed",
            content=f"Error executing script from blob storage: {str(ex)}",
            response_id="resp_error"
        )

    print(f"RESPONSE: {response}", flush=True)
    return JSONResponse(response)


if __name__ == "__main__":
    app.run()