"""Storage and staging engine for Morrow Mobile AMARP chat relay."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any

from .models import (
    DEFAULT_CHAT_TTL_S,
    DEFAULT_MAX_CAPACITY_BYTES,
    AckResponse,
    ChatMessage,
    SyncResponse,
)


def _parse_timestamp(val: Any, default: float) -> float:
    if val is None:
        return default
    if isinstance(val, (int, float)):
        return float(val)
    val_str = str(val).strip()
    if not val_str:
        return default
    try:
        return float(val_str)
    except ValueError:
        pass
    try:
        from datetime import datetime
        clean = val_str[:-1] + "+00:00" if val_str.endswith("Z") else val_str
        return datetime.fromisoformat(clean).timestamp()
    except Exception:
        return default


class ChatRelayStore:
    """Manages ephemeral inbox, outbox, and conversation staging queues."""

    def __init__(
        self,
        db_path: str | Path = ":memory:",
        ttl_s: int = DEFAULT_CHAT_TTL_S,
        max_capacity_bytes: int = DEFAULT_MAX_CAPACITY_BYTES,
    ) -> None:
        self.db_path = str(db_path)
        self.ttl_s = ttl_s
        self.max_capacity_bytes = max_capacity_bytes
        self._lock = threading.RLock()

        if self.db_path != ":memory:":
            Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)

        self._conn = sqlite3.connect(self.db_path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._init_schema()

    def _init_schema(self) -> None:
        with self._lock, self._conn:
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS chat_inbox (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    reply_to TEXT,
                    sender TEXT NOT NULL,
                    type TEXT NOT NULL,
                    status TEXT NOT NULL,
                    content TEXT NOT NULL,
                    tool_info TEXT,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    payload_bytes INTEGER NOT NULL,
                    account TEXT DEFAULT '',
                    metadata TEXT DEFAULT '{}'
                )
                """
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS chat_outbox (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    reply_to TEXT,
                    sender TEXT NOT NULL,
                    type TEXT NOT NULL,
                    status TEXT NOT NULL,
                    content TEXT NOT NULL,
                    tool_info TEXT,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    payload_bytes INTEGER NOT NULL,
                    account TEXT DEFAULT '',
                    metadata TEXT DEFAULT '{}'
                )
                """
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS project_conversations (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    project_name TEXT NOT NULL,
                    title TEXT NOT NULL,
                    snippet TEXT NOT NULL,
                    msg_count INTEGER NOT NULL,
                    last_modified_at REAL NOT NULL,
                    account TEXT DEFAULT '',
                    messages_json TEXT DEFAULT '[]',
                    updated_at REAL NOT NULL
                )
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_inbox_session_seq ON chat_inbox(session_id, seq)"
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_outbox_session_seq ON chat_outbox(session_id, seq)"
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_inbox_account ON chat_inbox(account)"
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_outbox_account ON chat_outbox(account)"
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_proj_conv_account ON project_conversations(account)"
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS account_quotas (
                    account TEXT PRIMARY KEY,
                    quota_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )

    def push_inbox(self, msg: ChatMessage) -> None:
        with self._lock, self._conn:
            self._prune_expired()
            self._conn.execute(
                """
                INSERT OR REPLACE INTO chat_inbox (
                    id, session_id, seq, reply_to, sender, type, status, content,
                    tool_info, created_at, expires_at, payload_bytes, account, metadata
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    msg.id,
                    msg.session_id,
                    msg.seq,
                    msg.reply_to,
                    msg.sender,
                    msg.type,
                    msg.status,
                    msg.content,
                    json.dumps(msg.tool_info) if msg.tool_info else None,
                    msg.created_at,
                    msg.expires_at,
                    msg.payload_bytes,
                    msg.account,
                    json.dumps(msg.metadata),
                ),
            )

    def pull_inbox(self, session_id: str | None = None, limit: int = 20, account: str | None = None) -> list[ChatMessage]:
        with self._lock:
            self._prune_expired()
            cur = self._conn.cursor()
            conditions = []
            params: list[Any] = []
            if session_id:
                conditions.append("session_id = ?")
                params.append(session_id)
            if account:
                conditions.append("(account = ? OR account = '')")
                params.append(account)
            where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
            params.append(limit)
            cur.execute(f"SELECT * FROM chat_inbox {where} ORDER BY seq ASC, created_at ASC LIMIT ?", params)
            return [self._row_to_msg(r) for r in cur.fetchall()]

    def ack_inbox(self, ids: list[str]) -> AckResponse:
        with self._lock, self._conn:
            if not ids:
                return AckResponse(acked=[], staged_remaining=self._count_table("chat_inbox"))
            placeholders = ",".join("?" for _ in ids)
            self._conn.execute(f"DELETE FROM chat_inbox WHERE id IN ({placeholders})", ids)
            return AckResponse(acked=ids, staged_remaining=self._count_table("chat_inbox"))

    def push_outbox(self, msg: ChatMessage) -> None:
        with self._lock, self._conn:
            self._prune_expired()
            self._conn.execute(
                """
                INSERT OR REPLACE INTO chat_outbox (
                    id, session_id, seq, reply_to, sender, type, status, content,
                    tool_info, created_at, expires_at, payload_bytes, account, metadata
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    msg.id,
                    msg.session_id,
                    msg.seq,
                    msg.reply_to,
                    msg.sender,
                    msg.type,
                    msg.status,
                    msg.content,
                    json.dumps(msg.tool_info) if msg.tool_info else None,
                    msg.created_at,
                    msg.expires_at,
                    msg.payload_bytes,
                    msg.account,
                    json.dumps(msg.metadata),
                ),
            )

    def sync_outbox(
        self,
        session_id: str,
        since_seq: int = 0,
        limit: int = 50,
        account: str | None = None,
    ) -> SyncResponse:
        with self._lock:
            self._prune_expired()
            cur = self._conn.cursor()
            conditions = ["session_id = ?", "seq > ?"]
            params: list[Any] = [session_id, since_seq]
            if account:
                conditions.append("(account = ? OR account = '')")
                params.append(account)
            where = "WHERE " + " AND ".join(conditions)
            cur.execute(f"SELECT * FROM chat_outbox {where} ORDER BY seq ASC LIMIT ?", (*params, limit + 1))
            rows = cur.fetchall()
            has_more = len(rows) > limit
            result_rows = rows[:limit]
            msgs = [self._row_to_msg(r) for r in result_rows]
            latest_seq = msgs[-1].seq if msgs else since_seq
            return SyncResponse(
                messages=msgs,
                has_more=has_more,
                latest_seq=latest_seq,
                total_staged=len(rows),
            )

    def ack_outbox(self, ids: list[str]) -> AckResponse:
        with self._lock, self._conn:
            if not ids:
                return AckResponse(acked=[], staged_remaining=self._count_table("chat_outbox"))
            placeholders = ",".join("?" for _ in ids)
            self._conn.execute(f"DELETE FROM chat_outbox WHERE id IN ({placeholders})", ids)
            return AckResponse(acked=ids, staged_remaining=self._count_table("chat_outbox"))

    def save_project_conversations(self, convs: list[dict[str, Any]], account: str = "") -> int:
        with self._lock, self._conn:
            now = time.time()
            count = 0
            for c in convs:
                cid = c.get("id")
                if not cid:
                    continue
                pid = c.get("project_id", "outside-of-project")
                pname = c.get("project_name", "Outside of Project")
                title = c.get("title", "新对话")
                snippet = c.get("snippet", "")
                msg_count = int(c.get("msg_count", 0))
                last_mod = _parse_timestamp(c.get("last_modified_at"), now)
                msgs_json = json.dumps(c.get("messages", []), ensure_ascii=False)

                self._conn.execute(
                    """
                    INSERT OR REPLACE INTO project_conversations (
                        id, project_id, project_name, title, snippet, msg_count,
                        last_modified_at, account, messages_json, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (cid, pid, pname, title, snippet, msg_count, last_mod, account, msgs_json, now),
                )
                count += 1
            return count

    def get_project_conversations(self, account: str | None = None) -> dict[str, Any]:
        with self._lock:
            cur = self._conn.cursor()
            conditions = []
            params: list[Any] = []
            if account:
                conditions.append("(account = ? OR account = '')")
                params.append(account)
            where = ("WHERE " + " AND ".join(conditions)) if conditions else ""

            cur.execute(f"SELECT * FROM project_conversations {where} ORDER BY last_modified_at DESC", params)
            rows = cur.fetchall()
            convs = []
            for r in rows:
                messages = []
                try:
                    messages = json.loads(r["messages_json"])
                except Exception:
                    pass
                convs.append({
                    "id": r["id"],
                    "project_id": r["project_id"],
                    "project_name": r["project_name"],
                    "title": r["title"],
                    "snippet": r["snippet"],
                    "msg_count": r["msg_count"],
                    "last_modified_at": r["last_modified_at"],
                    "account": r["account"],
                    "messages": messages,
                })

            group_conditions = []
            group_params: list[Any] = []
            if account:
                group_conditions.append("(account = ? OR account = '')")
                group_params.append(account)
            group_where = ("WHERE " + " AND ".join(group_conditions)) if group_conditions else ""

            cur.execute(
                f"SELECT project_id, project_name, COUNT(*) as cnt, MAX(last_modified_at) as latest_time FROM project_conversations {group_where} GROUP BY project_id ORDER BY latest_time DESC",
                group_params,
            )
            proj_rows = cur.fetchall()
            projects = []
            for pr in proj_rows:
                pid = pr["project_id"]
                pname = pr["project_name"]
                icon = "📁"
                if pid == "outside-of-project":
                    icon = "📁"
                elif "cli" in pid:
                    icon = "⌨️"
                else:
                    icon = "🛠️"
                projects.append({
                    "id": pid,
                    "name": pname,
                    "icon": icon,
                    "count": int(pr["cnt"]),
                })

            return {
                "projects": projects,
                "conversations": convs,
            }

    def delete_conversation(self, conversation_id: str, account: str | None = None) -> bool:
        with self._lock, self._conn:
            if account:
                cur = self._conn.execute(
                    "DELETE FROM project_conversations WHERE id = ? AND (account = ? OR account = '')",
                    (conversation_id, account),
                )
            else:
                cur = self._conn.execute("DELETE FROM project_conversations WHERE id = ?", (conversation_id,))
            return cur.rowcount > 0

    def get_sessions(self, account: str | None = None) -> list[str]:
        with self._lock:
            cur = self._conn.cursor()
            conditions = []
            params: list[Any] = []
            if account:
                conditions.append("(account = ? OR account = '')")
                params.append(account)
            where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
            cur.execute(
                f"""
                SELECT DISTINCT session_id FROM (
                    SELECT session_id, account FROM chat_inbox
                    UNION
                    SELECT session_id, account FROM chat_outbox
                ) {where}
                """,
                params,
            )
            return [r[0] for r in cur.fetchall()]

    def save_account_quotas(self, quotas: dict[str, Any]) -> int:
        with self._lock, self._conn:
            saved = 0
            now = time.time()
            for acct, data in quotas.items():
                if not isinstance(data, dict):
                    continue
                clean_acct = (acct or "").strip().lower()
                if not clean_acct:
                    continue
                self._conn.execute(
                    """
                    INSERT OR REPLACE INTO account_quotas (account, quota_json, updated_at)
                    VALUES (?, ?, ?)
                    """,
                    (clean_acct, json.dumps(data), now),
                )
                saved += 1
            return saved

    def get_account_quotas(self, account: str | None = None) -> dict[str, Any]:
        with self._lock:
            cur = self._conn.cursor()
            if account:
                cur.execute(
                    "SELECT account, quota_json, updated_at FROM account_quotas WHERE account = ?",
                    (account.strip().lower(),),
                )
            else:
                cur.execute("SELECT account, quota_json, updated_at FROM account_quotas")
            rows = cur.fetchall()
            results: dict[str, Any] = {}
            for row in rows:
                try:
                    data = json.loads(row["quota_json"])
                    results[row["account"]] = data
                except Exception:
                    pass
            return results

    def get_stats(self) -> dict[str, Any]:
        with self._lock:
            inbox_cnt = self._count_table("chat_inbox")
            outbox_cnt = self._count_table("chat_outbox")
            conv_cnt = self._count_table("project_conversations")
            return {
                "inbox_count": inbox_cnt,
                "outbox_count": outbox_cnt,
                "conversations_count": conv_cnt,
                "total_staged_messages": inbox_cnt + outbox_cnt,
            }

    def _prune_expired(self) -> None:
        now = time.time()
        self._conn.execute("DELETE FROM chat_inbox WHERE expires_at <= ?", (now,))
        self._conn.execute("DELETE FROM chat_outbox WHERE expires_at <= ?", (now,))

    def _count_table(self, table: str) -> int:
        cur = self._conn.cursor()
        cur.execute(f"SELECT COUNT(*) FROM {table}")
        row = cur.fetchone()
        return int(row[0]) if row else 0

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    @staticmethod
    def _row_to_msg(row: sqlite3.Row) -> ChatMessage:
        tool_info = json.loads(row["tool_info"]) if row["tool_info"] else None
        metadata = json.loads(row["metadata"]) if row["metadata"] else {}
        account = row["account"] if "account" in row.keys() else ""
        return ChatMessage(
            id=row["id"],
            session_id=row["session_id"],
            seq=row["seq"],
            reply_to=row["reply_to"],
            sender=row["sender"],
            type=row["type"],
            status=row["status"],
            content=row["content"],
            tool_info=tool_info,
            created_at=row["created_at"],
            expires_at=row["expires_at"],
            payload_bytes=row["payload_bytes"],
            account=account,
            metadata=metadata,
        )
