"""Morrow Mobile AMARP Chat Relay Server.

Standalone service running independently of Local Shell MCP.
"""

from __future__ import annotations

import argparse
import os
import uuid
from pathlib import Path
from typing import Any

import uvicorn
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route

from .models import ChatMessage
from .relay_store import ChatRelayStore

DEFAULT_DB_PATH = Path(os.environ.get("MOBILE_RELAY_DB", "/var/lib/morrow-mobile/relay.db"))
_store: ChatRelayStore | None = None


def get_store() -> ChatRelayStore:
    global _store
    if _store is None:
        db_path = DEFAULT_DB_PATH
        if not db_path.parent.exists():
            db_path.parent.mkdir(parents=True, exist_ok=True)
        _store = ChatRelayStore(db_path=db_path)
    return _store


async def healthz(_: Request) -> PlainTextResponse:
    return PlainTextResponse("OK")


async def stats(_: Request) -> JSONResponse:
    store = get_store()
    return JSONResponse({"ok": True, "data": store.get_stats()})


async def send_message(request: Request) -> JSONResponse:
    payload = await request.json()
    session_id = payload.get("session_id", "default")
    content = payload.get("content", "")
    account = payload.get("account", "")

    msg = ChatMessage(
        id=payload.get("id") or f"msg_{uuid.uuid4().hex[:16]}",
        session_id=session_id,
        seq=payload.get("seq", 0),
        sender=payload.get("sender", "user"),
        content=content,
        reply_to=payload.get("reply_to"),
        type=payload.get("type", "text"),
        status=payload.get("status", "sent"),
        account=account,
        metadata=payload.get("metadata", {}),
    )
    store = get_store()
    store.push_inbox(msg)
    return JSONResponse({"ok": True, "data": msg.to_dict()})


async def pull_inbox(request: Request) -> JSONResponse:
    payload = {}
    if request.method == "POST":
        try:
            payload = await request.json()
        except Exception:
            payload = {}
    session_id = payload.get("session_id")
    account = payload.get("account") or request.query_params.get("account")
    limit = int(payload.get("limit", 20))

    store = get_store()
    msgs = store.pull_inbox(session_id=session_id, limit=limit, account=account)
    return JSONResponse({"ok": True, "data": {"messages": [m.to_dict() for m in msgs], "count": len(msgs)}})


async def ack_inbox(request: Request) -> JSONResponse:
    payload = await request.json()
    ids = payload.get("ids", [])
    store = get_store()
    res = store.ack_inbox(ids)
    return JSONResponse({"ok": True, "data": {"acked": res.acked, "staged_remaining": res.staged_remaining}})


async def push_outbox(request: Request) -> JSONResponse:
    payload = await request.json()
    session_id = payload.get("session_id", "default")
    content = payload.get("content", "")
    account = payload.get("account", "")

    msg = ChatMessage(
        id=payload.get("id") or f"msg_{uuid.uuid4().hex[:16]}",
        session_id=session_id,
        seq=payload.get("seq", 0),
        sender=payload.get("sender", "agent"),
        content=content,
        reply_to=payload.get("reply_to"),
        type=payload.get("type", "text"),
        status=payload.get("status", "completed"),
        tool_info=payload.get("tool_info"),
        account=account,
        metadata=payload.get("metadata", {}),
    )
    store = get_store()
    store.push_outbox(msg)
    return JSONResponse({"ok": True, "data": msg.to_dict()})


async def sync_outbox(request: Request) -> JSONResponse:
    payload = {}
    if request.method == "POST":
        try:
            payload = await request.json()
        except Exception:
            payload = {}
    session_id = payload.get("session_id", "default")
    since_seq = int(payload.get("since_seq", 0))
    limit = int(payload.get("limit", 50))
    account = payload.get("account") or request.query_params.get("account")

    store = get_store()
    res = store.sync_outbox(session_id=session_id, since_seq=since_seq, limit=limit, account=account)
    return JSONResponse({
        "ok": True,
        "data": {
            "messages": [m.to_dict() for m in res.messages],
            "has_more": res.has_more,
            "latest_seq": res.latest_seq,
            "total_staged": res.total_staged,
        },
    })


async def ack_outbox(request: Request) -> JSONResponse:
    payload = await request.json()
    ids = payload.get("ids", [])
    store = get_store()
    res = store.ack_outbox(ids)
    return JSONResponse({"ok": True, "data": {"acked": res.acked, "staged_remaining": res.staged_remaining}})


async def conversations(request: Request) -> JSONResponse:
    account = None
    if request.method == "POST":
        try:
            payload = await request.json()
            account = payload.get("account")
        except Exception:
            pass
    if not account:
        account = request.query_params.get("account")

    store = get_store()
    data = store.get_project_conversations(account=account)
    data["quotas"] = store.get_account_quotas()
    return JSONResponse({"ok": True, "data": data})


async def sync_conversations(request: Request) -> JSONResponse:
    payload = await request.json()
    convs = payload.get("conversations", [])
    account = payload.get("account", "")
    store = get_store()
    saved = store.save_project_conversations(convs, account=account)
    return JSONResponse({"ok": True, "data": {"saved": saved}})


async def delete_conversation(request: Request) -> JSONResponse:
    payload = await request.json()
    cid = payload.get("conversation_id", "")
    account = payload.get("account")
    store = get_store()
    deleted = store.delete_conversation(cid, account=account)
    return JSONResponse({"ok": True, "data": {"deleted": deleted}})


async def sessions(request: Request) -> JSONResponse:
    account = request.query_params.get("account")
    store = get_store()
    return JSONResponse({"ok": True, "data": {"sessions": store.get_sessions(account=account)}})


async def get_quota(request: Request) -> JSONResponse:
    account = request.query_params.get("account")
    store = get_store()
    quotas = store.get_account_quotas(account=account)
    return JSONResponse({"ok": True, "data": {"quotas": quotas}})


async def sync_quota(request: Request) -> JSONResponse:
    payload = await request.json()
    quotas = payload.get("quotas", {})
    store = get_store()
    saved = store.save_account_quotas(quotas)
    return JSONResponse({"ok": True, "data": {"saved": saved}})


routes = [
    Route("/healthz", healthz, methods=["GET"]),
    Route("/api/chat/stats", stats, methods=["GET"]),
    Route("/api/chat/send", send_message, methods=["POST"]),
    Route("/api/chat/pull-inbox", pull_inbox, methods=["GET", "POST"]),
    Route("/api/chat/ack-inbox", ack_inbox, methods=["POST"]),
    Route("/api/chat/push-outbox", push_outbox, methods=["POST"]),
    Route("/api/chat/sync-outbox", sync_outbox, methods=["GET", "POST"]),
    Route("/api/chat/ack-outbox", ack_outbox, methods=["POST"]),
    Route("/api/chat/conversations", conversations, methods=["GET", "POST"]),
    Route("/api/chat/sync-conversations", sync_conversations, methods=["POST"]),
    Route("/api/chat/delete-conversation", delete_conversation, methods=["POST"]),
    Route("/api/chat/sessions", sessions, methods=["GET"]),
    Route("/api/chat/quota", get_quota, methods=["GET"]),
    Route("/api/chat/sync-quota", sync_quota, methods=["POST"]),
]

middleware = [
    Middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )
]

app = Starlette(routes=routes, middleware=middleware)


def main() -> None:
    parser = argparse.ArgumentParser(description="Morrow Mobile AMARP Relay Server")
    parser.add_argument("--port", type=int, default=18170, help="Listen port")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="Listen host")
    parser.add_argument("--db", type=str, default=str(DEFAULT_DB_PATH), help="SQLite DB path")
    args = parser.parse_args()

    global _store
    db_p = Path(args.db)
    db_p.parent.mkdir(parents=True, exist_ok=True)
    _store = ChatRelayStore(db_path=db_p)

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
