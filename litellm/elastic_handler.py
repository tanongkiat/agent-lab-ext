"""
LiteLLM custom provider for Elastic inference endpoints (incl. EIS), using
username/password (basic auth).

Env vars (or set api_base / api_key in config.yaml):
  ELASTICSEARCH_URL  e.g. https://<cluster>.es.<region>.aws.found.io
  ES_USER, ES_PASS   your Elastic login

Model name in LiteLLM:  elastic/<inference_id>
"""
import json
import os
from typing import AsyncIterator, Iterator

import httpx
import litellm
from litellm import CustomLLM
from litellm.types.utils import GenericStreamingChunk, ModelResponse

DEFAULT_URL = ""  # no default: ELASTICSEARCH_URL must be set explicitly
TIMEOUT = httpx.Timeout(300.0, connect=15.0)


def _settings(model: str, api_base=None, optional_params=None):
    inference_id = model.split("/", 1)[1] if model.startswith("elastic/") else model
    base = (api_base or os.getenv("ELASTICSEARCH_URL") or DEFAULT_URL).rstrip("/")
    user = os.getenv("ES_USER")
    pwd = os.getenv("ES_PASS")
    if not base:
        raise ValueError("Set ELASTICSEARCH_URL environment variable")
    if not user or not pwd:
        raise ValueError("Set ES_USER and ES_PASS environment variables")
    url = f"{base}/_inference/chat_completion/{inference_id}/_stream"
    return url, (user, pwd)


def _body(messages, optional_params):
    body = {"messages": messages}
    op = optional_params or {}
    for k in ("temperature", "top_p", "max_completion_tokens", "stop", "tools", "tool_choice"):
        if op.get(k) is not None:
            body[k] = op[k]
    if op.get("max_tokens") is not None and "max_completion_tokens" not in body:
        body["max_completion_tokens"] = op["max_tokens"]
    return body


def _parse_line(line: str):
    """Return (text, finish_reason, done) for one SSE line, or None to skip."""
    line = line.strip()
    if not line.startswith("data:"):
        if line.startswith("{") and '"error"' in line:
            raise RuntimeError(f"Elastic error: {line}")
        return None
    data = line[5:].strip()
    if data == "[DONE]":
        return "", "stop", True
    obj = json.loads(data)
    if "error" in obj:
        raise RuntimeError(f"Elastic error: {data}")
    obj = obj.get("chat_completion", obj)  # older versions wrap the chunk
    choices = obj.get("choices") or [{}]
    ch = choices[0]
    text = (ch.get("delta") or {}).get("content") or ""
    return text, ch.get("finish_reason"), False


def _chunk(text, finish_reason=None, done=False) -> GenericStreamingChunk:
    return {
        "text": text,
        "is_finished": done,
        "finish_reason": finish_reason or ("stop" if done else ""),
        "index": 0,
        "tool_use": None,
        "usage": None,
    }


def _raise_for_status(r: httpx.Response, body: bytes):
    if r.status_code >= 400:
        raise RuntimeError(f"Elastic HTTP {r.status_code}: {body.decode(errors='replace')[:1000]}")


def _response(model: str, text: str) -> ModelResponse:
    return ModelResponse(
        model=model,
        choices=[{"index": 0, "finish_reason": "stop",
                  "message": {"role": "assistant", "content": text}}],
    )


class ElasticLLM(CustomLLM):
    # ---------- streaming ----------
    def streaming(self, model, messages, api_base=None, optional_params=None, **kw) -> Iterator[GenericStreamingChunk]:
        url, auth = _settings(model, api_base, optional_params)
        with httpx.Client(timeout=TIMEOUT) as c:
            with c.stream("POST", url, auth=auth, json=_body(messages, optional_params)) as r:
                if r.status_code >= 400:
                    _raise_for_status(r, r.read())
                for line in r.iter_lines():
                    p = _parse_line(line)
                    if p is None:
                        continue
                    text, fr, done = p
                    if done:
                        break
                    if text:
                        yield _chunk(text)
        yield _chunk("", "stop", True)

    async def astreaming(self, model, messages, api_base=None, optional_params=None, **kw) -> AsyncIterator[GenericStreamingChunk]:
        url, auth = _settings(model, api_base, optional_params)
        async with httpx.AsyncClient(timeout=TIMEOUT) as c:
            async with c.stream("POST", url, auth=auth, json=_body(messages, optional_params)) as r:
                if r.status_code >= 400:
                    _raise_for_status(r, await r.aread())
                async for line in r.aiter_lines():
                    p = _parse_line(line)
                    if p is None:
                        continue
                    text, fr, done = p
                    if done:
                        break
                    if text:
                        yield _chunk(text)
        yield _chunk("", "stop", True)

    # ---------- non-streaming (Elastic only streams, so collect it) ----------
    def completion(self, model, messages, api_base=None, optional_params=None, **kw) -> ModelResponse:
        text = "".join(c["text"] for c in self.streaming(model, messages, api_base, optional_params))
        return _response(model, text)

    async def acompletion(self, model, messages, api_base=None, optional_params=None, **kw) -> ModelResponse:
        parts = [c["text"] async for c in self.astreaming(model, messages, api_base, optional_params)]
        return _response(model, "".join(parts))


elastic_llm = ElasticLLM()
