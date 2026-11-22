# ana:description Assistente local (sem internet): acha a rotina pelas palavras do pedido e tira os números dele
# ana:menu no
"""Spec 052 (D4, spec 066 D5). The model of installations without internet (and of the tests): the same contract as
the language model — it receives the conversation and the tools and answers text or one tool call, in the Messages
API format. It runs as the user, read-only. It understands only simple requests ("cancele o pedido 123", "abra o
pedido 45", "saldo de estoque"): the right words of a routine and its numbers. Whatever it chooses goes through the
same rules as the language model: queries run, routines that write are only rehearsed and wait for the person."""

import re
import unicodedata

PARAMS = {"request": {"type": "dict", "required": True, "label": "pedido no formato da API de mensagens"}}
STOP = {"para", "com", "sem", "uma", "uns", "umas", "por", "favor", "que", "dos", "das", "nos", "nas", "meu", "minha",
        "esse", "essa", "este", "esta", "isso", "isto", "qual", "quais", "como", "quero", "preciso", "pode", "poderia",
        "voce", "mim", "me", "o", "a", "os", "as", "de", "do", "da", "em", "no", "na", "e", "ou", "um", "the"}
KEYS = ("number", "order", "key", "id", "bill", "request", "invoice")


def norm(text):
    t = unicodedata.normalize("NFD", str(text or "")).encode("ascii", "ignore").decode().lower()
    return re.findall(r"[a-z0-9]+", t)


def stems(words):
    return {w[:5] for w in words if len(w) >= 3 and w not in STOP and not w.isdigit()}


def last_user_text(messages):
    content = messages[-1].get("content") if messages else ""
    if isinstance(content, str):
        return content
    texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"
             and not b.get("text", "").startswith("Registro do ANA")]
    return " ".join(texts)


def tool_results(messages):
    content = messages[-1].get("content") if messages else None
    if not isinstance(content, list):
        return []
    return [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"]


def text(t):
    return {"content": [{"type": "text", "text": t}], "stop_reason": "end_turn", "usage": {"input_tokens": 0, "output_tokens": 0}}


def score(asked, tool):
    desc = norm(tool.get("description", "").split("[")[0])
    have = stems(desc) | stems(norm(tool["name"].replace("__", " ").replace("_", " ")))
    s = len(asked & have)
    content = [w for w in desc if w not in STOP and not w.isdigit()]
    if s and content and content[0][:5] in asked:           # the routine's verb is the one asked ("cancela" ← "cancele")
        s += 2
        if len(content) > 1 and content[1][:5] in asked:     # and its object ("Cancela pedido", not "Cancela a fatura")
            s += 1
    return s


def fill(tool, words):
    props = tool.get("input_schema", {}).get("properties", {})
    numbers = [int(w) for w in words if w.isdigit()]
    params = {}
    ints = sorted((k for k, p in props.items() if p.get("type") == "integer"),
                  key=lambda k: (0 if k in KEYS else 1, k))
    for k in ints:
        if numbers:
            params[k] = numbers.pop(0)
    missing = [props[k].get("description") or k for k in tool.get("input_schema", {}).get("required", []) if k not in params]
    return params, missing


def main(request):
    messages = request.get("messages") or []
    tools = request.get("tools") or []
    results = tool_results(messages)
    if results:
        parts = [r.get("content") if isinstance(r.get("content"), str) else "" for r in results]
        return text("\n".join(p[:600] for p in parts if p) or "Pronto.")
    words = norm(last_user_text(messages))
    asked = stems(words)
    ranked = sorted(((score(asked, t), t["name"], t) for t in tools), key=lambda x: (-x[0], x[1]))
    if not ranked or ranked[0][0] < 2:
        hint = ", ".join(t.get("description", "").split("[")[0].strip().rstrip(".") for s, _n, t in ranked[:3] if s)
        return text("Não encontrei uma rotina para isso com o seu acesso." + (f" Talvez: {hint}." if hint else ""))
    tool = ranked[0][2]
    params, missing = fill(tool, words)
    if missing:
        return text(f"Para isso preciso de: {', '.join(missing)}.")
    return {"content": [{"type": "tool_use", "id": "local_1", "name": tool["name"], "input": params}],
            "stop_reason": "tool_use", "usage": {"input_tokens": 0, "output_tokens": 0}}
