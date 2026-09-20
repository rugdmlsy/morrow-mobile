#!/usr/bin/env python3
"""MacBook Local Agent Bridge for AMARP (LSM Mobile-Agent Relay Protocol).

This daemon runs locally on your MacBook, polls pending user prompts from the VPS relay,
invokes your local Agent (e.g. Antigravity CLI / subprocess / custom model),
and streams or pushes the Agent's responses back to the VPS Outbox for your iPhone.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import shutil
import signal
import sqlite3
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [MacAgentBridge] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("MacAgentBridge")


class MacAgentBridge:
    def __init__(
        self,
        relay_url: str,
        token: str | None = None,
        session_id: str | None = None,
        poll_interval_s: float = 2.0,
        agent_command: str | None = None,
        dry_run: bool = False,
    ) -> None:
        self.relay_url = relay_url.rstrip("/")
        self.token = token
        self.session_id = session_id
        self.poll_interval_s = poll_interval_s
        self.agent_command = agent_command
        self.dry_run = dry_run
        self._running = True
        self._processed_msg_ids: set[str] = set()
        self._processing_msg_ids: set[str] = set()
        self._last_conv_sync_time: float = 0.0
        self.session_map_path = Path.home() / ".gemini" / "antigravity" / "mobile_session_map.json"

    def stop(self) -> None:
        self._running = False

    def _get_session_conv_id(self, session_id: str) -> str | None:
        """Retrieves mapped Antigravity conversation UUID for a mobile session."""
        if len(session_id) == 36 and session_id.count("-") == 4:
            return session_id
        if not self.session_map_path.exists():
            return None
        try:
            with open(self.session_map_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data.get(session_id)
        except Exception:
            return None

    def _set_session_conv_id(self, session_id: str, conv_id: str) -> None:
        """Saves mapped Antigravity conversation UUID for a mobile session."""
        try:
            data = {}
            if self.session_map_path.exists():
                with open(self.session_map_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
            data[session_id] = conv_id
            self.session_map_path.parent.mkdir(parents=True, exist_ok=True)
            with open(self.session_map_path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
        except Exception as exc:
            logger.warning(f"Failed to save session map: {exc}")

    def _get_active_project_id(self) -> str:
        """Finds the most recently active non-empty project_id, defaulting to 'outside-of-project'."""
        try:
            db_path = Path.home() / ".gemini" / "antigravity" / "conversation_summaries.db"
            if db_path.exists():
                conn = sqlite3.connect(db_path)
                c = conn.cursor()
                c.execute(
                    "SELECT project_id FROM conversation_summaries WHERE project_id != '' AND project_id != 'default-cli-project' ORDER BY last_modified_time DESC LIMIT 1;"
                )
                row = c.fetchone()
                conn.close()
                if row and row[0]:
                    return row[0]
        except Exception as exc:
            logger.warning(f"Failed to query active project_id: {exc}")
        return "outside-of-project"

    def _get_latest_conv_id(self) -> str | None:
        """Finds the most recently updated conversation in conversation_summaries.db."""
        try:
            db_path = Path.home() / ".gemini" / "antigravity" / "conversation_summaries.db"
            if not db_path.exists():
                return None
            conn = sqlite3.connect(db_path)
            c = conn.cursor()
            c.execute("SELECT conversation_id FROM conversation_summaries WHERE conversation_id != '' ORDER BY last_modified_time DESC LIMIT 1;")
            row = c.fetchone()
            conn.close()
            return row[0] if row else None
        except Exception as exc:
            logger.warning(f"Failed to query conversation_summaries.db: {exc}")
            return None

    def _discover_language_server(self) -> tuple[int, str] | None:
        """Finds running language_server port and CSRF token."""
        try:
            ps_out = subprocess.check_output(["ps", "-eo", "pid,command"], text=True)
            pid = None
            csrf = None
            for line in ps_out.splitlines():
                if "language_server" in line and "--app_data_dir antigravity" in line:
                    m_pid = re.match(r"\s*(\d+)", line)
                    m_csrf = re.search(r"--csrf_token\s+([0-9a-fA-F-]+)", line)
                    if m_pid and m_csrf:
                        pid = m_pid.group(1)
                        csrf = m_csrf.group(1)
                        break
            if not pid or not csrf:
                return None

            lsof_out = subprocess.check_output(
                ["lsof", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN", "-P", "-n"],
                text=True,
            )
            ports = [
                int(m.group(1))
                for l in lsof_out.splitlines()
                if (m := re.search(r":(\d+)\s+\(LISTEN\)", l))
            ]
            if not ports:
                return None
            return min(ports), csrf
        except Exception as exc:
            logger.debug(f"Could not discover language_server: {exc}")
            return None

    def _extract_reply_from_trajectory(self, traj_dict: dict[str, Any]) -> str:
        """Extracts the agent's textual response from trajectory protobuf structure."""
        steps = traj_dict.get("trajectory", {}).get("steps", [])
        last_user_idx = -1
        for i, step in enumerate(steps):
            if step.get("type") == "CORTEX_STEP_TYPE_USER_INPUT":
                last_user_idx = i

        reply_texts: list[str] = []
        error_texts: list[str] = []
        for step in steps[last_user_idx + 1 :]:
            stype = step.get("type")
            if stype == "CORTEX_STEP_TYPE_PLANNER_RESPONSE":
                pr = step.get("plannerResponse", {})
                resp = pr.get("response") or pr.get("modifiedResponse") or ""
                if isinstance(resp, dict):
                    resp = resp.get("text") or json.dumps(resp, ensure_ascii=False)
                resp = str(resp).strip()
                if resp:
                    reply_texts.append(resp)
            elif stype == "CORTEX_STEP_TYPE_ERROR_MESSAGE":
                err_val = step.get("errorMessage", {}).get("error", "")
                if isinstance(err_val, dict):
                    err = err_val.get("shortError") or err_val.get("errorId") or json.dumps(err_val, ensure_ascii=False)
                else:
                    err = str(err_val)
                err = err.strip()
                if err:
                    error_texts.append(f"[Error: {err}]")

        if reply_texts:
            return "\n\n".join(reply_texts)
        if error_texts:
            return "\n\n".join(error_texts)
        return "(Agent executed with no text output)"

    def _notify_antigravity_app(self, conv_id: str, prompt: str, project_id: str | None = None) -> None:
        """Notifies Antigravity Desktop App about a new conversation or updated turn."""
        ls_info = self._discover_language_server()
        if not ls_info:
            return
        port, csrf = ls_info
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        headers = {
            "Content-Type": "application/json",
            "x-codeium-csrf-token": csrf,
        }
        active_project_id = project_id or self._get_active_project_id()
        clean_title = prompt[:30].strip().replace("\n", " ")
        try:
            # 1. Load trajectory into memory
            req_load = urllib.request.Request(
                f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/LoadTrajectory",
                data=json.dumps({"cascadeId": conv_id}).encode("utf-8"),
                headers=headers,
            )
            with urllib.request.urlopen(req_load, context=ctx, timeout=5):
                pass

            # 2. Fetch existing summary to check if title already exists
            req_all = urllib.request.Request(
                f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories",
                data=b"{}",
                headers=headers,
            )
            with urllib.request.urlopen(req_all, context=ctx, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                summary_obj = data.get("trajectorySummaries", {}).get(conv_id)

            # 3. Only set title annotation if it doesn't already have one
            existing_title = summary_obj.get("annotations", {}).get("title") if summary_obj else None
            title_to_set = existing_title or clean_title
            if not existing_title:
                req_annot = urllib.request.Request(
                    f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/UpdateConversationAnnotations",
                    data=json.dumps({"cascadeId": conv_id, "annotations": {"title": title_to_set}}).encode("utf-8"),
                    headers=headers,
                )
                with urllib.request.urlopen(req_annot, context=ctx, timeout=5):
                    pass
                # Re-fetch summary after annotation
                with urllib.request.urlopen(req_all, context=ctx, timeout=5) as resp:
                    data = json.loads(resp.read().decode("utf-8"))
                    summary_obj = data.get("trajectorySummaries", {}).get(conv_id)

            # 4. Broadcast summary to Electron frontend via JetboxWriteSummary
            if summary_obj:
                summary_obj["summary"] = title_to_set
                if "annotations" not in summary_obj:
                    summary_obj["annotations"] = {}
                summary_obj["annotations"]["title"] = title_to_set
                if "trajectoryMetadata" not in summary_obj:
                    summary_obj["trajectoryMetadata"] = {}
                summary_obj["trajectoryMetadata"]["projectId"] = active_project_id
                summary_obj["projectId"] = active_project_id

                req_write = urllib.request.Request(
                    f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/JetboxWriteSummary",
                    data=json.dumps({"cascadeId": conv_id, "summary": summary_obj}).encode("utf-8"),
                    headers=headers,
                )
                with urllib.request.urlopen(req_write, context=ctx, timeout=5):
                    pass

            # 5. Persist project_id and clean title to conversation_summaries.db and SQLite blob
            try:
                db_path = Path.home() / ".gemini" / "antigravity" / "conversation_summaries.db"
                if db_path.exists():
                    conn = sqlite3.connect(db_path)
                    c = conn.cursor()
                    c.execute("SELECT conversation_id FROM conversation_summaries WHERE conversation_id = ?", (conv_id,))
                    if c.fetchone():
                        c.execute(
                            "UPDATE conversation_summaries SET project_id = ?, title = CASE WHEN title = '' THEN ? ELSE title END, preview = CASE WHEN preview = '' THEN ? ELSE preview END, last_modified_time = datetime('now') WHERE conversation_id = ?",
                            (active_project_id, title_to_set, title_to_set, conv_id)
                        )
                    else:
                        c.execute(
                            "INSERT INTO conversation_summaries (conversation_id, project_id, title, preview, last_modified_time, last_user_input_time, workspace_uris, source, app_data_dir) VALUES (?, ?, ?, ?, datetime('now'), datetime('now'), '', 'CORTEX_TRAJECTORY_SOURCE_JETBOX', 'antigravity')",
                            (conv_id, active_project_id, title_to_set, title_to_set)
                        )
                    conn.commit()
                    conn.close()
            except Exception as e:
                logger.debug(f"conversation_summaries db update note: {e}")

            try:
                conv_db = Path.home() / ".gemini" / "antigravity" / "conversations" / f"{conv_id}.db"
                if conv_db.exists():
                    conn = sqlite3.connect(conv_db)
                    c = conn.cursor()
                    c.execute("SELECT data FROM trajectory_metadata_blob WHERE id = 'main'")
                    row = c.fetchone()
                    if row and row[0]:
                        blob = row[0]
                        tag = b"\x92\x01" + bytes([len(active_project_id.encode())]) + active_project_id.encode()
                        old_default = b"\x92\x01\x13default-cli-project"
                        if old_default in blob:
                            blob = blob.replace(old_default, tag)
                            c.execute("UPDATE trajectory_metadata_blob SET data = ? WHERE id = 'main'", (blob,))
                            conn.commit()
                        elif tag not in blob:
                            c.execute("UPDATE trajectory_metadata_blob SET data = ? WHERE id = 'main'", (blob + tag,))
                            conn.commit()
                    conn.close()
            except Exception as e:
                logger.debug(f"trajectory blob tag note: {e}")

            logger.info(f"Synchronized conversation {conv_id} to Antigravity Desktop App UI (project: {active_project_id}).")
        except Exception as exc:
            logger.warning(f"Failed to notify Antigravity App UI: {exc}")

    def _execute_via_language_server(
        self,
        prompt: str,
        session_id: str,
        conv_id: str | None,
        project_id: str | None = None,
        project_name: str | None = None,
    ) -> tuple[str, str] | None:
        """Executes a prompt directly via running language_server ConnectRPC service.

        This performs in-process execution, ensuring real-time streaming updates
        to the Antigravity Desktop App UI and instant multi-turn state synchronization.
        """
        ls_info = self._discover_language_server()
        if not ls_info:
            return None

        port, csrf = ls_info
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        headers = {
            "Content-Type": "application/json",
            "x-codeium-csrf-token": csrf,
        }

        try:
            active_conv_id = conv_id
            is_new_conv = False

            # If a custom project was requested from mobile, register it in Antigravity configs
            if project_id and project_id not in ("outside-of-project", "default-cli-project"):
                proj_cfg = Path.home() / ".gemini" / "config" / "projects" / f"{project_id}.json"
                if not proj_cfg.exists():
                    try:
                        proj_cfg.parent.mkdir(parents=True, exist_ok=True)
                        proj_cfg.write_text(json.dumps({
                            "id": project_id,
                            "name": project_name or project_id,
                            "projectResources": {}
                        }, ensure_ascii=False, indent=2))
                        logger.info(f"Registered new Antigravity project config for '{project_name}' ({project_id}).")
                    except Exception as exc:
                        logger.warning(f"Failed to write project config for {project_id}: {exc}")

            active_project_id = project_id or self._get_active_project_id()

            # Verify existing conv has active projectId in memory; if not, treat as new
            if active_conv_id:
                try:
                    req_all = urllib.request.Request(
                        f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/GetAllCascadeTrajectories",
                        data=b"{}",
                        headers=headers,
                    )
                    with urllib.request.urlopen(req_all, context=ctx, timeout=5) as resp:
                        all_data = json.loads(resp.read().decode("utf-8"))
                        summary_obj = all_data.get("trajectorySummaries", {}).get(active_conv_id)
                        curr_proj = summary_obj.get("trajectoryMetadata", {}).get("projectId") if summary_obj else None
                        if session_id == "default" and curr_proj and curr_proj != active_project_id:
                            logger.info(
                                f"Existing conv {active_conv_id} has projectId '{curr_proj}' != active '{active_project_id}'. Starting fresh cascade for session {session_id}."
                            )
                            active_conv_id = None
                except Exception as exc:
                    logger.debug(f"Check conv project note: {exc}")

            # 1. Initialize or load trajectory
            if not active_conv_id:
                active_conv_id = str(uuid.uuid4())
                is_new_conv = True
                req_start = urllib.request.Request(
                    f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/StartCascade",
                    data=json.dumps({
                        "cascadeId": active_conv_id,
                        "source": "CORTEX_TRAJECTORY_SOURCE_JETBOX",
                        "projectEnvConfig": {
                            "projectId": active_project_id,
                            "defaultProjectEnvironment": {},
                        },
                    }).encode("utf-8"),
                    headers=headers,
                )
                with urllib.request.urlopen(req_start, context=ctx, timeout=10):
                    pass

                # Persist session mapping immediately
                self._set_session_conv_id(session_id, active_conv_id)

                # Annotate title immediately so Desktop App shows clean title right away
                clean_prompt = prompt[:30].strip().replace("\n", " ")
                req_annot = urllib.request.Request(
                    f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/UpdateConversationAnnotations",
                    data=json.dumps({"cascadeId": active_conv_id, "annotations": {"title": clean_prompt}}).encode("utf-8"),
                    headers=headers,
                )
                try:
                    with urllib.request.urlopen(req_annot, context=ctx, timeout=5):
                        pass
                except Exception:
                    pass
            else:
                # Ensure existing trajectory is loaded in memory
                req_load = urllib.request.Request(
                    f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/LoadTrajectory",
                    data=json.dumps({"cascadeId": active_conv_id}).encode("utf-8"),
                    headers=headers,
                )
                try:
                    with urllib.request.urlopen(req_load, context=ctx, timeout=5):
                        pass
                except Exception as exc:
                    logger.debug(f"LoadTrajectory note for {active_conv_id}: {exc}")

            # 2. Send user cascade message
            body = {
                "cascadeId": active_conv_id,
                "items": [{"text": prompt}],
                "cascadeConfig": {
                    "plannerConfig": {
                        "planModel": "MODEL_PLACEHOLDER_M318"
                    }
                },
            }
            logger.info(f"Dispatching prompt via language_server ConnectRPC (conv: {active_conv_id})...")
            req_send = urllib.request.Request(
                f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/SendUserCascadeMessage",
                data=json.dumps(body).encode("utf-8"),
                headers=headers,
            )
            with urllib.request.urlopen(req_send, context=ctx, timeout=15) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"SendUserCascadeMessage returned status {resp.status}")

            # 3. Wait for execution to fully complete
            time.sleep(0.5)
            req_wait = urllib.request.Request(
                f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/WaitForConversationFullyIdle",
                data=json.dumps({
                    "conversationId": active_conv_id,
                    "inactivityTimeoutSeconds": 15,
                }).encode("utf-8"),
                headers=headers,
            )
            with urllib.request.urlopen(req_wait, context=ctx, timeout=300):
                pass

            # 4. Fetch full trajectory to extract agent's response
            req_traj = urllib.request.Request(
                f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/GetCascadeTrajectory",
                data=json.dumps({"cascadeId": active_conv_id}).encode("utf-8"),
                headers=headers,
            )
            with urllib.request.urlopen(req_traj, context=ctx, timeout=15) as resp:
                traj_dict = json.loads(resp.read().decode("utf-8"))

            reply_text = self._extract_reply_from_trajectory(traj_dict)

            # 5. Set title annotation if this is a new conversation
            if is_new_conv:
                clean_prompt = prompt[:30].strip().replace("\n", " ")
                title = clean_prompt
                req_annot = urllib.request.Request(
                    f"https://localhost:{port}/exa.language_server_pb.LanguageServerService/UpdateConversationAnnotations",
                    data=json.dumps({"cascadeId": active_conv_id, "annotations": {"title": title}}).encode("utf-8"),
                    headers=headers,
                )
                try:
                    with urllib.request.urlopen(req_annot, context=ctx, timeout=5):
                        pass
                except Exception:
                    pass

            # 6. Broadcast summary update to Electron frontend
            self._notify_antigravity_app(active_conv_id, prompt, project_id=active_project_id)

            # 7. Record session mapping
            self._set_session_conv_id(session_id, active_conv_id)

            logger.info(f"Successfully processed turn natively in Antigravity App for conversation {active_conv_id}")
            return reply_text, active_conv_id

        except Exception as exc:
            logger.warning(f"Native language_server execution failed: {exc}, will fall back to CLI if possible.")
            return None

    def _request(self, endpoint: str, payload: dict[str, Any] | None = None, method: str = "POST") -> dict[str, Any]:
        url = f"{self.relay_url}{endpoint}"
        headers = {
            "Content-Type": "application/json",
            "User-Agent": "LSM-MacAgentBridge/1.0",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"

        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = urllib.request.Request(url, data=data, headers=headers, method=method)

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw)
        except urllib.error.HTTPError as err:
            err_body = err.read().decode("utf-8") if err.fp else ""
            logger.error(f"HTTP {err.code} on {endpoint}: {err_body}")
            raise
        except Exception as exc:
            logger.debug(f"Network error on {endpoint}: {exc}")
            raise

    def pull_inbox(self) -> list[dict[str, Any]]:
        """Pulls pending user prompts from the VPS relay Inbox."""
        payload: dict[str, Any] = {"limit": 20}
        if self.session_id:
            payload["session_id"] = self.session_id
        try:
            res = self._request("/api/chat/pull-inbox", payload=payload)
            if res.get("ok"):
                return res.get("data", {}).get("messages", [])
        except Exception:
            pass
        return []

    def ack_inbox(self, message_ids: list[str]) -> bool:
        """Confirms receipt of user prompt -> VPS permanently deletes the prompt copy."""
        if not message_ids:
            return True
        try:
            res = self._request("/api/chat/ack-inbox", payload={"ids": message_ids})
            return bool(res.get("ok"))
        except Exception as exc:
            logger.warning(f"Failed to ack inbox messages {message_ids}: {exc}")
            return False

    def push_outbox(
        self,
        session_id: str,
        reply_to: str,
        content: str,
        msg_type: str = "text",
        status: str = "completed",
    ) -> bool:
        """Pushes an agent response or status update to VPS Outbox."""
        payload = {
            "id": f"msg_{uuid.uuid4().hex[:16]}",
            "session_id": session_id,
            "reply_to": reply_to,
            "sender": "agent",
            "type": msg_type,
            "status": status,
            "content": content,
            "created_at": time.time(),
        }
        try:
            res = self._request("/api/chat/push-outbox", payload=payload)
            return bool(res.get("ok"))
        except Exception as exc:
            logger.error(f"Failed to push outbox for session {session_id}: {exc}")
            return False

    def _save_local_transcript(
        self, session_id: str, role: str, content: str, msg_id: str
    ) -> None:
        """Appends exchange to local durable JSONL transcript."""
        try:
            log_dir = Path.home() / ".gemini" / "antigravity" / "mobile_transcripts"
            log_dir.mkdir(parents=True, exist_ok=True)
            record = {
                "timestamp": time.time(),
                "session_id": session_id,
                "id": msg_id,
                "role": role,
                "content": content,
            }
            with (log_dir / f"{session_id}.jsonl").open("a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
        except Exception as exc:
            logger.warning(f"Failed to record local transcript: {exc}")

    def _extract_messages_for_conversation(self, conv_id: str) -> list[dict[str, Any]]:
        """Parses local transcript.jsonl into structured user and agent messages."""
        t_file = Path.home() / ".gemini" / "antigravity" / "brain" / conv_id / ".system_generated" / "logs" / "transcript.jsonl"
        if not t_file.exists():
            return []
        messages = []
        try:
            with open(t_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        step = json.loads(line)
                    except Exception:
                        continue
                    stype = step.get("type")
                    content = step.get("content", "")
                    created_at = step.get("created_at", "")
                    if stype == "USER_INPUT":
                        m = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", content, re.DOTALL)
                        clean_text = m.group(1) if m else content
                        clean_text = re.sub(r"<ADDITIONAL_METADATA>.*?</ADDITIONAL_METADATA>", "", clean_text, flags=re.DOTALL).strip()
                        if clean_text:
                            messages.append({
                                "id": f"msg_u_{step.get('step_index', len(messages))}",
                                "role": "user",
                                "content": clean_text,
                                "created_at": created_at,
                            })
                    elif stype == "PLANNER_RESPONSE":
                        clean_resp = content.strip()
                        if clean_resp:
                            messages.append({
                                "id": f"msg_a_{step.get('step_index', len(messages))}",
                                "role": "agent",
                                "content": clean_resp,
                                "created_at": created_at,
                            })
        except Exception as exc:
            logger.debug(f"Error reading transcript for {conv_id}: {exc}")
        return messages

    def sync_project_conversations(self) -> int:
        """Collects conversations from conversation_summaries.db and syncs them to VPS relay."""
        db_path = Path.home() / ".gemini" / "antigravity" / "conversation_summaries.db"
        if not db_path.exists():
            return 0
        try:
            conn = sqlite3.connect(db_path)
            c = conn.cursor()
            c.execute(
                "SELECT conversation_id, project_id, title, preview, last_modified_time "
                "FROM conversation_summaries WHERE conversation_id != '' "
                "ORDER BY last_modified_time DESC LIMIT 50;"
            )
            rows = c.fetchall()
            conn.close()

            conv_list = []
            for cid, proj_id, title, preview, last_mod in rows:
                proj_id = (proj_id or "outside-of-project").strip()
                if not proj_id or proj_id == "outside-of-project":
                    proj_name = "Outside of Project"
                elif proj_id == "default-cli-project":
                    proj_name = "CLI Project"
                else:
                    proj_cfg = Path.home() / ".gemini" / "config" / "projects" / f"{proj_id}.json"
                    if proj_cfg.exists():
                        try:
                            pdata = json.loads(proj_cfg.read_text(encoding="utf-8"))
                            proj_name = pdata.get("name") or Path(proj_id).name or proj_id
                        except Exception:
                            proj_name = Path(proj_id).name or proj_id
                    else:
                        proj_name = Path(proj_id).name or proj_id

                title = (title or preview or "新对话").strip()
                preview = (preview or title or "").strip()
                msgs = self._extract_messages_for_conversation(cid)
                if not msgs and preview:
                    msgs = [{
                        "id": f"msg_{cid[:8]}",
                        "role": "agent",
                        "content": preview,
                        "created_at": str(last_mod),
                    }]

                conv_list.append({
                    "id": cid,
                    "project_id": proj_id,
                    "project_name": proj_name,
                    "title": title,
                    "snippet": preview[:120],
                    "last_modified_at": str(last_mod),
                    "msg_count": len(msgs),
                    "messages": msgs,
                })

            if not conv_list:
                return 0

            active_ids = [c["id"] for c in conv_list]
            res = self._request(
                "/api/chat/sync-conversations",
                payload={"conversations": conv_list, "active_ids": active_ids},
            )
            synced = res.get("data", {}).get("synced_count", len(conv_list))
            logger.info(f"Synced {synced} project conversations to VPS relay.")
            return synced
        except Exception as exc:
            logger.warning(f"Failed to sync project conversations: {exc}")
            return 0

    def execute_agent(
        self,
        prompt: str,
        session_id: str,
        user_msg_id: str,
        project_id: str | None = None,
        project_name: str | None = None,
    ) -> str:
        """Executes the local agent (agy or custom CLI) with the given prompt."""
        if self.dry_run:
            logger.info(f"[DryRun] Mock agent received: '{prompt}'")
            time.sleep(0.5)
            return f"[MacBook Mock Agent Response] Received prompt: {prompt}"

        # Notify iPhone that agent started running
        self.push_outbox(
            session_id=session_id,
            reply_to=user_msg_id,
            content="Agent started processing...",
            msg_type="status",
            status="running",
        )

        # 1. Custom external command override if configured
        if self.agent_command:
            if "{prompt}" in self.agent_command:
                cmd = self.agent_command.format(prompt=prompt)
            else:
                cmd = f"{self.agent_command} '{prompt}'"
            logger.info(f"Executing custom agent: {cmd}")
            try:
                proc = subprocess.run(
                    cmd,
                    shell=True,
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
                output = proc.stdout.strip()
                if proc.stderr:
                    if output:
                        output += f"\n\n[stderr]\n{proc.stderr.strip()}"
                    else:
                        output = proc.stderr.strip()
                return output or "(Agent executed with no output)"
            except subprocess.TimeoutExpired:
                return "Agent execution timed out after 300 seconds."
            except Exception as exc:
                return f"Agent execution failed: {exc}"

        conv_id = self._get_session_conv_id(session_id)

        # 2. Try native in-process execution via language_server ConnectRPC (Desktop App)
        ls_result = self._execute_via_language_server(
            prompt, session_id, conv_id, project_id=project_id, project_name=project_name
        )
        if ls_result is not None:
            reply_text, _ = ls_result
            return reply_text

        # 3. Fallback to Official Antigravity CLI (agy) if Desktop App is closed or RPC failed
        agy_bin = shutil.which("agy") or str(Path.home() / ".local" / "bin" / "agy")
        if Path(agy_bin).exists():
            logger.info(f"Executing with Antigravity CLI fallback ({agy_bin})...")
            cmd = [
                agy_bin,
                "--app_data_dir",
                "antigravity",
                "--dangerously-skip-permissions",
            ]
            if conv_id:
                cmd.extend(["--conversation", conv_id])
            cmd.extend(["-p", prompt])

            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                output = proc.stdout.strip()
                # Clean up benign conversation lookup warning if any
                if proc.stderr:
                    err_lines = [
                        line
                        for line in proc.stderr.strip().splitlines()
                        if "warning: conversation" not in line
                    ]
                    if err_lines and not output:
                        output = "\n".join(err_lines)

                # Track conversation UUID and live-sync to Desktop App UI
                active_conv_id = self._get_latest_conv_id()
                if active_conv_id:
                    if not conv_id or conv_id != active_conv_id:
                        self._set_session_conv_id(session_id, active_conv_id)
                    self._notify_antigravity_app(active_conv_id, prompt, project_id=project_id)

                return output or "(Agent executed with no output)"
            except subprocess.TimeoutExpired:
                return "Antigravity CLI execution timed out after 300 seconds."
            except Exception as exc:
                return f"Antigravity CLI execution failed: {exc}"

        # 4. Default echo runner when neither custom command nor agy is found
        return f"[MacBook Default Agent] Processed prompt for session {session_id}: {prompt}"

    def process_message(self, msg: dict[str, Any]) -> None:
        msg_id = msg.get("id")
        session_id = msg.get("session_id", "default")
        content = msg.get("content", "")
        sender = msg.get("sender")
        project_id = msg.get("project_id") or "outside-of-project"
        project_name = msg.get("project_name") or "Outside of Project"

        if sender != "user" or not msg_id:
            return

        # Deduplication check: prevent running same message multiple times
        if msg_id in self._processing_msg_ids:
            logger.info(f"Message {msg_id} is already in-flight, skipping duplicate execution.")
            return

        if msg_id in self._processed_msg_ids:
            logger.info(f"Message {msg_id} was already processed, acknowledging duplicate...")
            self.ack_inbox([msg_id])
            return

        self._processing_msg_ids.add(msg_id)
        try:
            logger.info(f"Processing message {msg_id} in session [{session_id}] (project: {project_name}): {content[:80]}")

            # 1. Save user message to durable local transcript
            self._save_local_transcript(session_id=session_id, role="user", content=content, msg_id=msg_id)

            # 2. Run local agent
            agent_reply = self.execute_agent(
                prompt=content,
                session_id=session_id,
                user_msg_id=msg_id,
                project_id=project_id,
                project_name=project_name,
            )

            # 3. Save agent reply to durable local transcript
            self._save_local_transcript(session_id=session_id, role="agent", content=agent_reply, msg_id=f"reply_{msg_id}")

            # 4. Push final reply to VPS Outbox (staged for iPhone) with retry
            pushed = False
            for attempt in range(3):
                pushed = self.push_outbox(
                    session_id=session_id,
                    reply_to=msg_id,
                    content=agent_reply,
                    msg_type="text",
                    status="completed",
                )
                if pushed:
                    break
                logger.warning(f"Push outbox attempt {attempt + 1} failed for {msg_id}, retrying...")
                time.sleep(1.0)

            # 5. Mark as processed so it will NEVER be re-executed
            self._processed_msg_ids.add(msg_id)
            if len(self._processed_msg_ids) > 1000:
                self._processed_msg_ids.pop()

            # 6. ACK inbox message with retry
            for attempt in range(3):
                if self.ack_inbox([msg_id]):
                    logger.info(f"Successfully replied and ACKed message {msg_id}")
                    break
                time.sleep(1.0)

            # 7. Proactively trigger project conversation sync
            try:
                self.sync_project_conversations()
                self._last_conv_sync_time = time.time()
            except Exception:
                pass
        finally:
            self._processing_msg_ids.discard(msg_id)

    def run_loop(self) -> None:
        logger.info(f"Starting MacAgentBridge connected to {self.relay_url} (poll interval: {self.poll_interval_s}s)")
        if self.dry_run:
            logger.info("Running in DRY RUN mode (echo mock agent).")

        # Initial sync on startup
        try:
            self.sync_project_conversations()
            self._last_conv_sync_time = time.time()
        except Exception as exc:
            logger.warning(f"Initial conversation sync note: {exc}")

        backoff = self.poll_interval_s
        while self._running:
            try:
                # Periodic background sync of project conversations
                now = time.time()
                if now - self._last_conv_sync_time >= 15.0:
                    self.sync_project_conversations()
                    self._last_conv_sync_time = now

                messages = self.pull_inbox()
                if messages:
                    backoff = self.poll_interval_s
                    for msg in messages:
                        if not self._running:
                            break
                        self.process_message(msg)
                else:
                    time.sleep(backoff)
            except Exception as exc:
                logger.warning(f"Error in poll loop: {exc}. Retrying in {backoff:.1f}s...")
                time.sleep(backoff)
                backoff = min(backoff * 1.5, 30.0)

        logger.info("MacAgentBridge stopped cleanly.")


def main() -> None:
    parser = argparse.ArgumentParser(description="LSM MacBook Local Agent Bridge")
    parser.add_argument("--relay-url", default="http://127.0.0.1:8765", help="VPS Relay API URL")
    parser.add_argument("--token", default=None, help="Bearer authorization token")
    parser.add_argument("--session-id", default=None, help="Filter to specific session ID")
    parser.add_argument("--poll-interval", type=float, default=2.0, help="Polling interval in seconds")
    parser.add_argument("--agent-command", default=None, help="Command template to execute, e.g. 'agy \"{prompt}\"'")
    parser.add_argument("--dry-run", action="store_true", help="Run with mock agent without executing commands")
    args = parser.parse_args()

    bridge = MacAgentBridge(
        relay_url=args.relay_url,
        token=args.token,
        session_id=args.session_id,
        poll_interval_s=args.poll_interval,
        agent_command=args.agent_command,
        dry_run=args.dry_run,
    )

    def _sigint_handler(sig: int, frame: Any) -> None:
        logger.info("Received interrupt signal, stopping...")
        bridge.stop()

    signal.signal(signal.SIGINT, _sigint_handler)
    signal.signal(signal.SIGTERM, _sigint_handler)

    bridge.run_loop()


if __name__ == "__main__":
    main()
