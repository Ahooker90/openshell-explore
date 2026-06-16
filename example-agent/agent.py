#!/usr/bin/env python3
"""Minimal example agent for OpenShell.

It sends a chat-completion request to an OpenAI-compatible endpoint. Inside an
OpenShell sandbox that endpoint is `https://inference.local/v1`, which the
gateway's privacy router forwards to whatever backend you configured with
`setup.sh` — local Ollama, or a corporate endpoint. **The agent code does not
change between environments**; only the gateway-side provider does.

Dependency-free: standard library only, so it runs in the stock `base` sandbox
image under the tightest network policy (no `pip`, no extra egress).
"""
import json
import os
import sys
import urllib.request

# Inside a sandbox the agent always targets inference.local. You can override
# these for local debugging, but the point of OpenShell is that you don't:
# the backend + credentials live in the gateway, not in the agent.
BASE_URL = os.environ.get("OPENAI_BASE_URL", "https://inference.local/v1")
API_KEY = os.environ.get("OPENAI_API_KEY", "unused")  # placeholder; router injects the real key
MODEL = os.environ.get("MODEL", "router")             # router rewrites this to the configured model


def chat(prompt: str) -> dict:
    body = json.dumps(
        {
            "model": MODEL,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0,
            "max_tokens": 256,
        }
    ).encode()
    req = urllib.request.Request(
        f"{BASE_URL}/chat/completions",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {API_KEY}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        return json.load(resp)


def main() -> None:
    prompt = " ".join(sys.argv[1:]).strip() or "In one sentence, what is OpenShell?"
    print(f"-> endpoint: {BASE_URL}")
    print(f"-> prompt:   {prompt}\n")

    data = chat(prompt)
    reply = data["choices"][0]["message"]["content"].strip()
    print(f"<- model: {data.get('model')}")
    print(f"<- reply: {reply}")


if __name__ == "__main__":
    main()
