#!/usr/bin/env python3

"""为真实 Chrome E2E 同时提供固定网页和本机 Responses API。"""

from __future__ import annotations

import argparse
import json
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


class AwaitCueE2EHandler(SimpleHTTPRequestHandler):
    """只服务 loopback fixture，并记录模型实际收到的文字证据。"""

    request_log: Path
    log_lock = threading.Lock()

    def do_GET(self) -> None:  # noqa: N802 - http.server 固定接口名
        if self.path == "/health":
            self._send_json({"ok": True})
            return
        super().do_GET()

    def do_POST(self) -> None:  # noqa: N802 - http.server 固定接口名
        if self.path != "/v1/responses":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            format_name = body["text"]["format"]["name"]
            input_text = self._input_text(body)
            self._record_request(format_name, input_text)
            output = self._structured_output(format_name, input_text)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            self._send_json({"error": str(error)}, status=400)
            return

        self._send_json(
            {
                "status": "completed",
                "output": [
                    {
                        "type": "message",
                        "content": [
                            {
                                "type": "output_text",
                                "text": json.dumps(output, ensure_ascii=False),
                            }
                        ],
                    }
                ],
            }
        )

    def log_message(self, _format: str, *_args: object) -> None:
        """真实 E2E 只保留结构化请求日志，避免 HTTP access log 干扰诊断。"""

    @staticmethod
    def _input_text(body: dict[str, Any]) -> str:
        chunks: list[str] = []
        for message in body.get("input", []):
            for content in message.get("content", []):
                if content.get("type") == "input_text":
                    chunks.append(str(content.get("text", "")))
        return "\n".join(chunks)

    @staticmethod
    def _structured_output(format_name: str, input_text: str) -> dict[str, Any]:
        if format_name == "condition_preparation":
            return {
                "confirmedSummary": "CN 全流量部署状态显示完成",
                "requiredEvidence": "dom",
                "currentDecision": "notMatched",
                "confidence": 0.99,
            }
        if format_name == "condition_evaluation":
            matched = "data-status:success" in input_text
            return {
                "decision": "matched" if matched else "notMatched",
                "confidence": 0.99,
            }
        if format_name == "interruptibility_evaluation":
            return {"decision": "notInterruptible", "confidence": 0.99}
        raise ValueError(f"unsupported response schema: {format_name}")

    def _record_request(self, format_name: str, input_text: str) -> None:
        snapshot = json.dumps(
            {"name": format_name, "input_text": input_text},
            ensure_ascii=False,
        )
        with self.log_lock:
            with self.request_log.open("a", encoding="utf-8") as stream:
                stream.write(snapshot + "\n")

    def _send_json(self, value: dict[str, Any], status: int = 200) -> None:
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main() -> None:
    """启动仅监听 127.0.0.1 的多线程 fixture server。"""

    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--request-log", type=Path, required=True)
    args = parser.parse_args()
    AwaitCueE2EHandler.request_log = args.request_log
    handler = lambda *handler_args, **handler_kwargs: AwaitCueE2EHandler(  # noqa: E731
        *handler_args,
        directory=str(args.directory),
        **handler_kwargs,
    )
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
