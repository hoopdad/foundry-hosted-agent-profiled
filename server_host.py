print("STARTUP", flush=True)

from collections import OrderedDict
import json
import itertools
import os
import time
import uuid
import tempfile
from datetime import datetime, timezone
from typing import Any, Dict, Optional
from urllib.parse import urlsplit, urlunsplit

from azure.ai.agentserver.invocations import InvocationAgentServerHost
from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.core.pipeline.policies import SansIOHTTPPolicy
from azure.storage.blob import BlobClient, ContentSettings
from azure.identity import ManagedIdentityCredential
from starlette.requests import Request
from starlette.responses import JSONResponse

import socket
import urllib3.util.connection as urllib3_connection

_original_getaddrinfo = socket.getaddrinfo
_original_create_connection = urllib3_connection.create_connection


def _profiled_getaddrinfo(host, *args, **kwargs):
    started = time.perf_counter()
    timestamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")

    try:
        result = _original_getaddrinfo(host, *args, **kwargs)
        duration_ms = (time.perf_counter() - started) * 1000

        addresses = sorted({
            item[4][0]
            for item in result
            if item and len(item) > 4 and item[4]
        })

        print(
            f"DNS_PROFILE timestamp={timestamp} "
            f"host={host} duration_ms={duration_ms:.2f} "
            f"addresses={addresses}",
            flush=True,
        )

        return result

    except Exception as ex:
        duration_ms = (time.perf_counter() - started) * 1000

        print(
            f"DNS_PROFILE exception timestamp={timestamp} "
            f"host={host} duration_ms={duration_ms:.2f} "
            f"error={type(ex).__name__}",
            flush=True,
        )

        raise


def _profiled_create_connection(address, *args, **kwargs):
    started = time.perf_counter()
    host, port = address

    try:
        result = _original_create_connection(address, *args, **kwargs)
        duration_ms = (time.perf_counter() - started) * 1000

        print(
            f"CONNECT_PROFILE "
            f"timestamp={datetime.now(timezone.utc).isoformat(timespec='milliseconds')} "
            f"host={host} port={port} duration_ms={duration_ms:.2f}",
            flush=True,
        )

        return result

    except Exception as ex:
        duration_ms = (time.perf_counter() - started) * 1000

        print(
            f"CONNECT_PROFILE exception "
            f"timestamp={datetime.now(timezone.utc).isoformat(timespec='milliseconds')} "
            f"host={host} port={port} duration_ms={duration_ms:.2f} "
            f"error={type(ex).__name__}",
            flush=True,
        )

        raise


socket.getaddrinfo = _profiled_getaddrinfo
urllib3_connection.create_connection = _profiled_create_connection


MAX_RETAINED_INVOCATION_RESULTS = 100
INVOCATIONS_OPENAPI_SPEC = {
    "openapi": "3.1.0",
    "info": {
        "title": "Foundry Hosted Storage Probe",
        "version": "1.0.0",
    },
    "paths": {
        "/invocations": {
            "post": {
                "operationId": "invokeStorageProbe",
                "requestBody": {
                    "required": True,
                    "content": {
                        "application/json": {
                            "schema": {
                                "type": "object",
                                "required": [
                                    "input_blob_path",
                                    "output_blob_path",
                                ],
                                "properties": {
                                    "input_blob_path": {
                                        "type": "string",
                                        "format": "uri",
                                    },
                                    "output_blob_path": {
                                        "type": "string",
                                        "format": "uri",
                                    },
                                    "managed_identity_client_id": {
                                        "type": "string",
                                        "format": "uuid",
                                    },
                                },
                            }
                        }
                    },
                },
                "responses": {
                    "200": {
                        "description": "Storage probe result.",
                        "content": {
                            "application/json": {
                                "schema": {"type": "object"}
                            }
                        },
                    }
                },
            }
        },
        "/invocations/{invocation_id}": {
            "get": {
                "operationId": "getStorageProbeResult",
                "parameters": [
                    {
                        "name": "invocation_id",
                        "in": "path",
                        "required": True,
                        "schema": {"type": "string"},
                    }
                ],
                "responses": {
                    "200": {
                        "description": "Retained storage probe result.",
                        "content": {
                            "application/json": {
                                "schema": {"type": "object"}
                            }
                        },
                    },
                    "404": {
                        "description": "Invocation result is not retained."
                    },
                },
            }
        },
    },
}
_invocation_results: OrderedDict[str, Dict[str, Any]] = OrderedDict()


def _retain_invocation_result(
    invocation_id: str,
    response: Dict[str, Any],
) -> None:
    _invocation_results[invocation_id] = response
    _invocation_results.move_to_end(invocation_id)

    while len(_invocation_results) > MAX_RETAINED_INVOCATION_RESULTS:
        _invocation_results.popitem(last=False)


app = InvocationAgentServerHost(openapi_spec=INVOCATIONS_OPENAPI_SPEC)


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
#   "output_blob_path": "https://<account>.blob.core.windows.net/<container>/<output-file>"
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

    try:
        content = blob_client.download_blob().readall()
    except ResourceNotFoundError:
        try:
            blob_client.upload_blob(data=b"", overwrite=False)
            print(
                "STORAGE_PROBE created_missing_input_blob "
                f"url={RequestResponseProfilerPolicy._safe_url(blob_url)}",
                flush=True,
            )
        except ResourceExistsError:
            pass

        content = blob_client.download_blob().readall()

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
        "output_blob_path": "..."
      }

    Wrapped:
      {
        "input": {
          "input_blob_path": "...",
          "output_blob_path": "..."
        }
      }

    Content string:
      {
        "input": "{\"input_blob_path\":\"...\"}"
      }
    """

    if all(key in request_json for key in ["input_blob_path", "output_blob_path"]):
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
        "Request must include input_blob_path and output_blob_path "
        "either at the top level or inside an input object."
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


@app.get_invocation_handler
async def get_invocation(request: Request):
    invocation_id = request.path_params["invocation_id"]
    response = _invocation_results.get(invocation_id)

    if response is None:
        return JSONResponse(
            {
                "error": {
                    "code": "not_found",
                    "message": "Invocation result is not retained.",
                }
            },
            status_code=404,
        )

    _invocation_results.move_to_end(invocation_id)
    return JSONResponse(response)


@app.invoke_handler
async def invoke(request: Request):
    print("***** INVOKE HANDLER EXECUTED *****", flush=True)

    raw_body = await request.body()
    print(f"REQUEST BODY BYTES: {len(raw_body)}", flush=True)
    invocation_id = request.state.invocation_id

    try:
        request_json = json.loads(raw_body.decode("utf-8")) if raw_body else {}
        payload = extract_payload(request_json)

        input_blob_path = get_required_string(payload, "input_blob_path")
        output_blob_path = get_required_string(payload, "output_blob_path")

        if input_blob_path == output_blob_path:
            raise ValueError(
                "input_blob_path and output_blob_path must be different"
            )

        credential = get_credential(payload)

        with tempfile.TemporaryDirectory(prefix="foundry_storage_probe_") as work_dir:
            input_file_path = os.path.join(work_dir, "input_file")
            output_file_path = os.path.join(work_dir, "storage_probe_result.json")

            input_bytes = download_blob_to_file(
                blob_url=input_blob_path,
                local_path=input_file_path,
                credential=credential
            )

            result_document = {
                "status": "completed",
                "message": "Storage read/write simulation completed.",
                "input_bytes_read": input_bytes,
                "downloaded_code_execution_enabled": False,
            }
            write_text_to_file(
                output_file_path,
                json.dumps(result_document, indent=2, sort_keys=True)
            )

            uploaded_bytes = upload_file_to_blob(
                local_path=output_file_path,
                blob_url=output_blob_path,
                credential=credential,
                content_type="application/json"
            )

            response = build_response(
                status="completed",
                content=(
                    "Storage read/write simulation completed successfully. "
                    "Downloaded code execution is disabled."
                ),
                response_id=invocation_id,
                extra={
                    "input_bytes_downloaded": input_bytes,
                    "uploaded_bytes": uploaded_bytes,
                    "downloaded_code_execution_enabled": False,
                }
            )

    except Exception as ex:
        response = build_response(
            status="failed",
            content=f"Error during storage read/write simulation: {str(ex)}",
            response_id=invocation_id,
        )

    _retain_invocation_result(invocation_id, response)
    print(f"RESPONSE: {response}", flush=True)
    return JSONResponse(response)


if __name__ == "__main__":
    app.run()