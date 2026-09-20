"""Data models for Morrow Mobile AMARP chat relay."""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

DEFAULT_CHAT_TTL_S = 7 * 86400  # 7 days
DEFAULT_MAX_CAPACITY_BYTES = 2 * 1024 * 1024 * 1024  # 2 GB


@dataclass
class ChatMessage:
    id: str
    session_id: str
    seq: int
    sender: str
    content: str
    reply_to: str | None = None
    type: str = "text"
    status: str = "sent"
    tool_info: dict[str, Any] | None = None
    created_at: float = field(default_factory=time.time)
    expires_at: float = field(default_factory=lambda: time.time() + DEFAULT_CHAT_TTL_S)
    payload_bytes: int = 0
    account: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "session_id": self.session_id,
            "seq": self.seq,
            "reply_to": self.reply_to,
            "sender": self.sender,
            "type": self.type,
            "status": self.status,
            "content": self.content,
            "tool_info": self.tool_info,
            "created_at": self.created_at,
            "expires_at": self.expires_at,
            "payload_bytes": self.payload_bytes,
            "account": self.account,
            "metadata": self.metadata,
        }


@dataclass
class SyncResponse:
    messages: list[ChatMessage]
    has_more: bool
    latest_seq: int
    total_staged: int


@dataclass
class AckResponse:
    acked: list[str]
    staged_remaining: int
