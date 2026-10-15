import asyncio
import json
import os
import unittest
from unittest.mock import patch

from starlette.requests import Request

os.environ.pop("APPLICATIONINSIGHTS_CONNECTION_STRING", None)
os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
os.environ["FOUNDRY_AGENT365_TRACING_ENABLED"] = "false"

import server_host


def build_request(
    method,
    path,
    body=b"",
    path_params=None,
):
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": method,
        "scheme": "https",
        "path": path,
        "raw_path": path.encode("ascii"),
        "query_string": b"",
        "root_path": "",
        "headers": [(b"content-type", b"application/json")],
        "client": ("test", 1234),
        "server": ("test", 443),
        "path_params": path_params or {},
    }

    async def receive():
        return {
            "type": "http.request",
            "body": body,
            "more_body": False,
        }

    return Request(scope, receive)


class ServerHostTests(unittest.TestCase):
    def setUp(self):
        server_host._invocation_results.clear()

    def test_openapi_document_is_available(self):
        request = build_request(
            "GET",
            "/invocations/docs/openapi.json",
        )
        response = asyncio.run(
            server_host.app._get_openapi_spec_endpoint(request)
        )
        document = json.loads(response.body)

        self.assertEqual(200, response.status_code)
        self.assertIn("/invocations", document["paths"])

    @patch.object(server_host, "upload_file_to_blob", return_value=155)
    @patch.object(server_host, "download_blob_to_file", return_value=0)
    @patch.object(server_host, "get_credential", return_value=object())
    def test_completed_invocation_can_be_retrieved(
        self,
        _get_credential,
        _download_blob_to_file,
        _upload_file_to_blob,
    ):
        payload = {
            "input_blob_path": (
                "https://example.blob.core.windows.net/files/input.json"
            ),
            "output_blob_path": (
                "https://example.blob.core.windows.net/files/output.json"
            ),
        }

        invoke_request = build_request(
            "POST",
            "/invocations",
            json.dumps(payload).encode("utf-8"),
        )
        invoke_response = asyncio.run(
            server_host.app._create_invocation_endpoint(invoke_request)
        )
        invoke_document = json.loads(invoke_response.body)
        invocation_id = invoke_document["id"]

        get_request = build_request(
            "GET",
            f"/invocations/{invocation_id}",
            path_params={"invocation_id": invocation_id},
        )
        get_response = asyncio.run(
            server_host.app._get_invocation_endpoint(get_request)
        )
        get_document = json.loads(get_response.body)

        self.assertEqual(200, invoke_response.status_code)
        self.assertEqual("completed", invoke_document["status"])
        self.assertEqual(200, get_response.status_code)
        self.assertEqual(invoke_document, get_document)

    def test_retained_invocation_results_are_bounded(self):
        for index in range(
            server_host.MAX_RETAINED_INVOCATION_RESULTS + 1
        ):
            invocation_id = f"invocation-{index}"
            server_host._retain_invocation_result(
                invocation_id,
                {"id": invocation_id},
            )

        self.assertEqual(
            server_host.MAX_RETAINED_INVOCATION_RESULTS,
            len(server_host._invocation_results),
        )
        self.assertNotIn("invocation-0", server_host._invocation_results)


if __name__ == "__main__":
    unittest.main()
