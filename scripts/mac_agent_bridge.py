#!/usr/bin/env python3
"""MacBook Local Agent Bridge for AMARP (LSM Mobile-Agent Relay Protocol).

This daemon runs locally on your MacBook, polls pending user prompts from the VPS relay,
invokes your local Agent (antigravity-0, antigravity-1, codex, or custom CLI),
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
from datetime import datetime
from pathlib import Path
from typing import Any

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [MacAgentBridge] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("MacAgentBridge")


def parse_iso_datetime(ts: str) -> datetime | None:
    """Safely parses ISO8601 timestamp string into datetime."""
    if not ts:
        return None
    try:
        clean = ts[:-1] + "+00:00" if ts.endswith("Z") else ts
        return datetime.fromisoformat(clean)
    except Exception:
        return None


def get_agent_profiles() -> dict[str, dict[str, Any]]:
    raw_home = Path.home()
    if raw_home.name == ".antigravity-personal":
        user_home = raw_home.parent
        personal_home = raw_home
    else:
        user_home = raw_home
        personal_home = raw_home / ".antigravity-personal"

    agy_0_bin = (
        str(user_home / "bin" / "agy-0")
        if (user_home / "bin" / "agy-0").exists()
        else (shutil.which("agy") or str(user_home / ".local" / "bin" / "agy-0") or str(user_home / ".local" / "bin" / "agy"))
    )
    agy_1_bin = (
        str(user_home / "bin" / "agy-1")
        if (user_home / "bin" / "agy-1").exists()
        else (str(user_home / ".local" / "bin" / "agy-1"))
    )

    return {
        "antigravity-0": {
            "account": "antigravity-0",
            "type": "antigravity",
            "home": user_home,
            "gemini_dir": user_home / ".gemini",
            "app_data_dir": user_home / ".gemini" / "antigravity",
            "session_map_path": user_home / ".gemini" / "antigravity" / "mobile_session_map.json",
            "transcripts_dir": user_home / ".gemini" / "antigravity" / "mobile_transcripts",
            "db_path": user_home / ".gemini" / "antigravity" / "conversation_summaries.db",
            "config_projects_dir": user_home / ".gemini" / "config" / "projects",
            "brain_dir": user_home / ".gemini" / "antigravity" / "brain",
            "agy_bin": agy_0_bin,
            "parent_keyword": None,
            "exclude_parent_keyword": "Antigravity-Personal",
        },
        "antigravity-1": {
            "account": "antigravity-1",
            "type": "antigravity",
            "home": personal_home,
            "gemini_dir": personal_home / ".gemini",
            "app_data_dir": personal_home / ".gemini" / "antigravity",
            "session_map_path": personal_home / ".gemini" / "antigravity" / "mobile_session_map.json",
            "transcripts_dir": personal_home / ".gemini" / "antigravity" / "mobile_transcripts",
            "db_path": personal_home / ".gemini" / "antigravity" / "conversation_summaries.db",
            "config_projects_dir": personal_home / ".gemini" / "config" / "projects",
            "brain_dir": personal_home / ".gemini" / "antigravity" / "brain",
            "agy_bin": agy_1_bin,
            "parent_keyword": "Antigravity-Personal",
            "exclude_parent_keyword": None,
        },
    }


def resolve_profile(account: str | None = None) -> dict[str, Any]:
    profiles = get_agent_profiles()
    acct = (account or "").strip().lower()
    if acct in ("antigravity-1", "personal", "agy-1"):
        return profiles["antigravity-1"]
    elif acct.startswith("codex"):
        home = Path.home()
        codex_dir = home / ".codex"
        codex_bin = shutil.which(acct) or shutil.which("codex") or "codex"
        return {
            "account": acct,
            "type": "codex",
            "home": home,
            "gemini_dir": None,
            "app_data_dir": codex_dir,
            "session_map_path": codex_dir / "mobile_session_map.json",
            "transcripts_dir": codex_dir / "transcripts",
            "db_path": None,
            "config_projects_dir": None,
            "brain_dir": None,
            "agy_bin": codex_bin,
            "parent_keyword": None,
            "exclude_parent_keyword": None,
        }
    else:
        return profiles["antigravity-0"]


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
        self._last_quota_sync_time: float = 0.0
        self._last_db_mtimes: dict[str, float] = {}

    def stop(self) -> None:
        self._running = False

    def _get_session_conv_id(self, profile: dict[str, Any], session_id: str) -> str | None:
        """Retrieves mapped conversation UUID for a mobile session."""
        if len(session_id) == 36 and session_id.count("-") == 4:
            return session_id
        session_map_path = profile.get("session_map_path")
        if not session_map_path or not session_map_path.exists():
            return None
        try:
            with open(session_map_path, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data.get(session_id)
        except Exception:
            return None

    def _set_session_conv_id(self, profile: dict[str, Any], session_id: str, conv_id: str) -> None:
        """Saves mapped conversation UUID for a mobile session."""
        session_map_path = profile.get("session_map_path")
        if not session_map_path:
            return
        try:
            data = {}
            if session_map_path.exists():
                with open(session_map_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
            data[session_id] = conv_id
            session_map_path.parent.mkdir(parents=True, exist_ok=True)
            with open(session_map_path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
        except Exception as exc:
            logger.warning(f"Failed to save session map for {profile.get('account')}: {exc}")

    def _get_active_project_id(self, profile: dict[str, Any]) -> str:
        """Finds the most recently active non-empty project_id, defaulting to 'outside-of-project'."""
        try:
            db_path = profile.get("db_path")
            if db_path and db_path.exists():
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
            logger.warning(f"Failed to query active project_id for {profile.get('account')}: {exc}")
        return "outside-of-project"

    def _get_latest_conv_id(self, profile: dict[str, Any]) -> str | None:
        """Finds the most recently updated conversation in conversation_summaries.db."""
        try:
            db_path = profile.get("db_path")
            if not db_path or not db_path.exists():
                return None
            conn = sqlite3.connect(db_path)
            c = conn.cursor()
            c.execute("SELECT conversation_id FROM conversation_summaries WHERE conversation_id != '' ORDER BY last_modified_time DESC LIMIT 1;")
            row = c.fetchone()
            conn.close()
            return row[0] if row else None
        except Exception as exc:
            logger.warning(f"Failed to query conversation_summaries.db for {profile.get('account')}: {exc}")
            return None

    def _discover_language_server(self, profile: dict[str, Any]) -> tuple[int, str] | None:
        """Finds running language_server port and CSRF token for the specified profile."""
        if profile.get("type") != "antigravity":
            return None
        try:
            ps_out = subprocess.check_output(["ps", "-eo", "pid,ppid,command"], text=True)
            matched_pid = None
            matched_csrf = None

            for line in ps_out.splitlines():
                if "/language_server " in line and "--app_data_dir antigravity" in line:
                    m = re.match(r"\s*(\d+)\s+(\d+)", line)
                    if not m:
                        continue
                    pid, ppid = m.group(1), m.group(2)
                    try:
                        parent_cmd = subprocess.check_output(
                            ["ps", "-ww", "-p", ppid, "-o", "command="], text=True
                        )
                    except Exception:
                        parent_cmd = ""

                    is_personal = "Antigravity-Personal" in parent_cmd
                    target_is_personal = profile.get("account") == "antigravity-1"

                    if target_is_personal == is_personal:
                        m_csrf = re.search(r"--csrf_token\s+([0-9a-fA-F-]+)", line)
                        if m_csrf:
                            matched_pid = pid
                            matched_csrf = m_csrf.group(1)
                            break

            if not matched_pid or not matched_csrf:
                return None

            lsof_out = subprocess.check_output(
                ["lsof", "-a", "-p", matched_pid, "-iTCP", "-sTCP:LISTEN", "-P", "-n"],
                text=True,
            )
            ports = [
                int(m.group(1))
                for l in lsof_out.splitlines()
                if (m := re.search(r":(\d+)\s+\(LISTEN\)", l))
            ]
            if not ports:
                return None
            return min(ports), matched_csrf
        except Exception as exc:
            logger.debug(f"Could not discover language_server for {profile.get('account')}: {exc}")
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

    def _notify_antigravity_app(self, profile: dict[str, Any], conv_id: str, prompt: str, project_id: str | None = None) -> None:
        """Notifies Antigravity Desktop App about a new conversation or updated turn."""
        ls_info = self._discover_language_server(profile)
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
        active_project_id = project_id or self._get_active_project_id(profile)
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
                db_path = profile.get("db_path")
                if db_path and db_path.exists():
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
                conv_db = (profile.get("app_data_dir") or Path.home() / ".gemini" / "antigravity") / "conversations" / f"{conv_id}.db"
                if conv_db.exists():
                    conn = sqlite3.connect(conv_db)
                    c = conn.cursor()
                    c.execute("SELECT data FROM trajectory_metadata_blob WHERE id = 'main'")
                    row = c.fetchone()
                    if row and row[0]:
                        blob = row[0]
                        tag = bytes([0x92, 0x01, len(active_project_id.encode())]) + active_project_id.encode()
                        old_default = bytes([0x92, 0x01, 0x13]) + b"default-cli-project"
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

            logger.info(f"[{profile.get('account')}] Synchronized conversation {conv_id} to Antigravity App UI (project: {active_project_id}).")
        except Exception as exc:
            logger.warning(f"[{profile.get('account')}] Failed to notify Antigravity App UI: {exc}")

    def _execute_via_language_server(
        self,
        profile: dict[str, Any],
        prompt: str,
        session_id: str,
        conv_id: str | None,
        project_id: str | None = None,
        project_name: str | None = None,
    ) -> tuple[str, str] | None:
        """Executes a prompt directly via running language_server ConnectRPC service for this profile."""
        ls_info = self._discover_language_server(profile)
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
                proj_cfg_dir = profile.get("config_projects_dir")
                if proj_cfg_dir:
                    proj_cfg = proj_cfg_dir / f"{project_id}.json"
                    if not proj_cfg.exists():
                        try:
                            proj_cfg.parent.mkdir(parents=True, exist_ok=True)
                            proj_cfg.write_text(json.dumps({
                                "id": project_id,
                                "name": project_name or project_id,
                                "projectResources": {}
                            }, ensure_ascii=False, indent=2))
                            logger.info(f"[{profile.get('account')}] Registered project config for '{project_name}' ({project_id}).")
                        except Exception as exc:
                            logger.warning(f"Failed to write project config for {project_id}: {exc}")

            active_project_id = project_id or self._get_active_project_id(profile)

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
                self._set_session_conv_id(profile, session_id, active_conv_id)

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
            logger.info(f"[{profile.get('account')}] Dispatching prompt via language_server ConnectRPC (conv: {active_conv_id})...")
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
            self._notify_antigravity_app(profile, active_conv_id, prompt, project_id=active_project_id)

            # 7. Record session mapping
            self._set_session_conv_id(profile, session_id, active_conv_id)

            logger.info(f"[{profile.get('account')}] Successfully processed turn natively in Antigravity App for conversation {active_conv_id}")
            return reply_text, active_conv_id

        except Exception as exc:
            logger.warning(f"[{profile.get('account')}] Native language_server execution failed: {exc}, will fall back to CLI if possible.")
            return None

    def _request(self, endpoint: str, payload: dict[str, Any] | None = None, method: str = "POST") -> dict[str, Any]:
        url = f"{self.relay_url}{endpoint}"
        headers = {
            "Content-Type": "application/json",
            "User-Agent": "MorrowMobile/1.0",
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
            # Automatic fallback to sslip.io while DNS propagates for mobile.xycdev.com
            if "mobile.xycdev.com" in self.relay_url:
                try:
                    fb_url = url.replace("mobile.xycdev.com", "mobile.51-79-159-224.sslip.io")
                    fb_req = urllib.request.Request(fb_url, data=data, headers=headers, method=method)
                    with urllib.request.urlopen(fb_req, timeout=30) as resp:
                        raw = resp.read().decode("utf-8")
                        self.relay_url = "https://mobile.51-79-159-224.sslip.io"
                        logger.info("Using https://mobile.51-79-159-224.sslip.io until mobile.xycdev.com DNS is active")
                        return json.loads(raw)
                except Exception:
                    pass
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
        account: str = "",
        msg_type: str = "text",
        status: str = "completed",
        tokens: int | None = None,
        duration: float | None = None,
    ) -> bool:
        """Pushes an agent response or status update to VPS Outbox."""
        payload = {
            "id": f"msg_{uuid.uuid4().hex[:16]}",
            "session_id": session_id,
            "reply_to": reply_to,
            "account": account,
            "sender": "agent",
            "type": msg_type,
            "status": status,
            "content": content,
            "created_at": time.time(),
        }
        if tokens is not None:
            payload["tokens"] = tokens
        if duration is not None:
            payload["duration"] = duration
        try:
            res = self._request("/api/chat/push-outbox", payload=payload)
            return bool(res.get("ok"))
        except Exception as exc:
            logger.error(f"Failed to push outbox for session {session_id} ({account}): {exc}")
            return False

    def _save_local_transcript(
        self, profile: dict[str, Any], session_id: str, role: str, content: str, msg_id: str
    ) -> None:
        """Appends exchange to local durable JSONL transcript."""
        try:
            log_dir = profile.get("transcripts_dir") or (Path.home() / ".gemini" / "antigravity" / "mobile_transcripts")
            log_dir.mkdir(parents=True, exist_ok=True)
            record = {
                "timestamp": time.time(),
                "account": profile.get("account", "antigravity-0"),
                "session_id": session_id,
                "id": msg_id,
                "role": role,
                "content": content,
            }
            with (log_dir / f"{session_id}.jsonl").open("a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
        except Exception as exc:
            logger.warning(f"Failed to record local transcript for {profile.get('account')}: {exc}")

    def _extract_messages_for_conversation(self, profile: dict[str, Any], conv_id: str) -> list[dict[str, Any]]:
        """Parses local transcript.jsonl into structured user and agent messages."""
        brain_dir = profile.get("brain_dir")
        if not brain_dir:
            return []
        t_file = brain_dir / conv_id / ".system_generated" / "logs" / "transcript.jsonl"
        if not t_file.exists():
            return []
        messages = []
        last_user_time = None
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
                            last_user_time = parse_iso_datetime(created_at)
                            messages.append({
                                "id": f"msg_u_{step.get('step_index', len(messages))}",
                                "role": "user",
                                "content": clean_text,
                                "created_at": created_at,
                            })
                    elif stype == "PLANNER_RESPONSE":
                        clean_resp = content.strip()
                        if clean_resp:
                            duration = None
                            if last_user_time and created_at:
                                curr_time = parse_iso_datetime(created_at)
                                if curr_time:
                                    diff = (curr_time - last_user_time).total_seconds()
                                    if 0 < diff < 3600:
                                        duration = round(diff, 1)
                            messages.append({
                                "id": f"msg_a_{step.get('step_index', len(messages))}",
                                "role": "agent",
                                "content": clean_resp,
                                "created_at": created_at,
                                "duration": duration,
                            })
        except Exception as exc:
            logger.debug(f"Error reading transcript for {conv_id} ({profile.get('account')}): {exc}")
        return messages

    def sync_project_conversations(self, account: str | None = None, force: bool = False) -> int:
        """Collects conversations from conversation_summaries.db and syncs them to VPS relay."""
        profiles_to_sync = [resolve_profile(account)] if account else list(get_agent_profiles().values())
        total_synced = 0

        for profile in profiles_to_sync:
            acct_name = profile.get("account", "antigravity-0")
            db_path = profile.get("db_path")
            if not db_path or not db_path.exists():
                continue

            try:
                curr_mtime = db_path.stat().st_mtime
                if not force and curr_mtime == self._last_db_mtimes.get(acct_name, 0.0):
                    continue
            except Exception:
                curr_mtime = 0.0
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
                        proj_cfg_dir = profile.get("config_projects_dir")
                        proj_cfg = (proj_cfg_dir / f"{proj_id}.json") if proj_cfg_dir else None
                        if proj_cfg and proj_cfg.exists():
                            try:
                                pdata = json.loads(proj_cfg.read_text(encoding="utf-8"))
                                proj_name = pdata.get("name") or Path(proj_id).name or proj_id
                            except Exception:
                                proj_name = Path(proj_id).name or proj_id
                        else:
                            proj_name = Path(proj_id).name or proj_id

                    title = (title or preview or "新对话").strip()
                    preview = (preview or title or "").strip()
                    msgs = self._extract_messages_for_conversation(profile, cid)
                    if not msgs and preview:
                        msgs = [{
                            "id": f"msg_{cid[:8]}",
                            "role": "agent",
                            "content": preview,
                            "created_at": str(last_mod),
                        }]

                    conv_list.append({
                        "id": cid,
                        "account": acct_name,
                        "project_id": proj_id,
                        "project_name": proj_name,
                        "title": title,
                        "snippet": preview[:120],
                        "last_modified_at": str(last_mod),
                        "msg_count": len(msgs),
                        "messages": msgs,
                    })

                if not conv_list:
                    continue

                active_ids = [c["id"] for c in conv_list]
                res = self._request(
                    "/api/chat/sync-conversations",
                    payload={"account": acct_name, "conversations": conv_list, "active_ids": active_ids},
                )
                synced = res.get("data", {}).get("synced_count", len(conv_list))
                logger.info(f"[{acct_name}] Synced {synced} project conversations to VPS relay.")
                self._last_db_mtimes[acct_name] = curr_mtime
                total_synced += synced
            except Exception as exc:
                logger.warning(f"[{acct_name}] Failed to sync project conversations: {exc}")

        return total_synced

    def get_native_quota_status(self) -> dict[str, Any]:
        """Queries local language_server processes for native Antigravity quota information."""
        servers = []
        try:
            out = subprocess.check_output(["ps", "-ef"], text=True)
            for line in out.splitlines():
                if "language_server" in line and "--csrf_token" in line:
                    parts = line.split()
                    pid = parts[1]
                    m_token = re.search(r"--csrf_token\s+([a-f0-9\-]+)", line)
                    if not m_token:
                        continue
                    csrf_token = m_token.group(1)
                    account = "antigravity-1" if "antigravity-personal" in line.lower() else "antigravity-0"

                    ports: list[int] = []
                    try:
                        lsof_out = subprocess.check_output(
                            ["lsof", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN", "-Fn"],
                            text=True,
                        )
                        for pline in lsof_out.splitlines():
                            m = re.search(r":(\d+)$", pline)
                            if m:
                                ports.append(int(m.group(1)))
                    except Exception:
                        pass

                    servers.append({
                        "pid": pid,
                        "account": account,
                        "csrf_token": csrf_token,
                        "ports": sorted(set(ports)),
                    })
        except Exception as exc:
            logger.debug(f"Failed to scan language servers: {exc}")
            return {}

        results: dict[str, Any] = {}
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        for s in servers:
            acct = s["account"]
            if acct in results:
                continue
            for port in s["ports"]:
                url = f"https://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetUserStatus"
                req = urllib.request.Request(
                    url,
                    data=b"{}",
                    headers={
                        "Content-Type": "application/json",
                        "x-codeium-csrf-token": s["csrf_token"],
                    },
                )
                try:
                    with urllib.request.urlopen(req, context=ctx, timeout=2.5) as resp:
                        raw = json.loads(resp.read().decode("utf-8"))
                        us = raw.get("userStatus", {})
                        if not us:
                            continue
                        user_name = us.get("name", "")
                        user_email = us.get("email", "")
                        user_tier = us.get("userTier", {}).get("name", "")
                        model_configs = us.get("cascadeModelConfigData", {}).get("clientModelConfigs", [])
                        models = []
                        for m in model_configs:
                            qi = m.get("quotaInfo", {})
                            models.append({
                                "label": m.get("label", ""),
                                "model_id": m.get("modelId", ""),
                                "remaining_fraction": qi.get("remainingFraction", 1.0),
                                "reset_time": qi.get("resetTime"),
                            })

                        models = self._aggregate_models(models)

                        from datetime import timezone
                        results[acct] = {
                            "account": acct,
                            "name": user_name,
                            "email": user_email,
                            "tier": user_tier,
                            "models": models,
                            "updated_at": datetime.now(timezone.utc).isoformat(),
                        }
                        break
                except Exception:
                    continue

        return results

    @staticmethod
    def _aggregate_models(raw_models: list) -> list:
        """Groups models into Gemini and GPT/Claude for clear presentation."""
        if not raw_models:
            return []

        gemini_models = [
            m for m in raw_models
            if "gemini" in (m.get("label", "") + m.get("model_id", "")).lower()
        ]
        other_models = [
            m for m in raw_models
            if "gemini" not in (m.get("label", "") + m.get("model_id", "")).lower()
        ]

        aggregated = []
        if gemini_models:
            min_frac = min(m.get("remaining_fraction", 1.0) for m in gemini_models)
            exhausted = [m for m in gemini_models if m.get("remaining_fraction", 1.0) <= 0.05]
            if exhausted:
                reset_times = [m.get("reset_time") for m in exhausted if m.get("reset_time")]
                reset_time = min(reset_times) if reset_times else gemini_models[0].get("reset_time")
            else:
                reset_time = gemini_models[0].get("reset_time")

            aggregated.append({
                "label": "Gemini",
                "model_id": "gemini",
                "description": "Flash & Pro 全系列",
                "remaining_fraction": min_frac,
                "reset_time": reset_time,
            })

        if other_models:
            min_frac = min(m.get("remaining_fraction", 1.0) for m in other_models)
            exhausted = [m for m in other_models if m.get("remaining_fraction", 1.0) <= 0.05]
            if exhausted:
                reset_times = [m.get("reset_time") for m in exhausted if m.get("reset_time")]
                reset_time = min(reset_times) if reset_times else other_models[0].get("reset_time")
            else:
                reset_time = other_models[0].get("reset_time")

            aggregated.append({
                "label": "GPT / Claude",
                "model_id": "gpt-claude",
                "description": "Claude Opus / Sonnet, GPT-OSS",
                "remaining_fraction": min_frac,
                "reset_time": reset_time,
            })

        return aggregated if aggregated else raw_models

    def sync_native_quota(self) -> int:
        """Fetches native Antigravity quota from local language_server and syncs to VPS relay."""
        quotas = self.get_native_quota_status()
        if not quotas:
            return 0
        try:
            res = self._request("/api/chat/sync-quota", payload={"quotas": quotas})
            synced = res.get("data", {}).get("saved", len(quotas))
            logger.info(f"Synced native quota for {len(quotas)} account(s) to VPS relay.")
            return synced
        except Exception as exc:
            logger.warning(f"Failed to sync native quota to VPS relay: {exc}")
            return 0

    def execute_agent(
        self,
        prompt: str,
        session_id: str,
        user_msg_id: str,
        profile: dict[str, Any] | None = None,
        project_id: str | None = None,
        project_name: str | None = None,
    ) -> str:
        """Executes the local agent with the given prompt for the profile."""
        if profile is None:
            profile = resolve_profile()
        acct_name = profile.get("account", "antigravity-0")
        if self.dry_run:
            logger.info(f"[DryRun] Mock agent ({acct_name}) received: '{prompt}'")
            time.sleep(0.5)
            return f"[MacBook Mock Agent Response ({acct_name})] Received prompt: {prompt}"

        # Notify iPhone that agent started running
        self.push_outbox(
            session_id=session_id,
            reply_to=user_msg_id,
            content="Agent started processing...",
            account=acct_name,
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
                    env=dict(os.environ, HOME=str(profile["home"])),
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

        # If profile type is codex or other custom agent CLI
        if profile.get("type") == "codex":
            codex_bin = profile.get("agy_bin") or "codex"
            logger.info(f"Executing codex agent ({codex_bin})...")
            try:
                cmd = [codex_bin, "exec", prompt]
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                output = proc.stdout.strip() or proc.stderr.strip()
                return output or f"(Codex executed prompt: {prompt})"
            except Exception as exc:
                return f"Codex execution failed: {exc}"

        conv_id = self._get_session_conv_id(profile, session_id)

        # 2. Try native in-process execution via language_server ConnectRPC (Desktop App)
        ls_result = self._execute_via_language_server(
            profile, prompt, session_id, conv_id, project_id=project_id, project_name=project_name
        )
        if ls_result is not None:
            reply_text, _ = ls_result
            return reply_text

        # 3. Fallback to CLI wrapper for this profile
        agy_bin = profile.get("agy_bin")
        if agy_bin and Path(agy_bin).exists():
            logger.info(f"Executing with Antigravity CLI fallback for {acct_name} ({agy_bin})...")
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
                proc = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=300,
                    env=dict(os.environ, HOME=str(profile["home"])),
                )
                output = proc.stdout.strip()
                if proc.stderr:
                    err_lines = [
                        line
                        for line in proc.stderr.strip().splitlines()
                        if "warning: conversation" not in line
                    ]
                    if err_lines and not output:
                        output = "\n".join(err_lines)

                active_conv_id = self._get_latest_conv_id(profile)
                if active_conv_id:
                    if not conv_id or conv_id != active_conv_id:
                        self._set_session_conv_id(profile, session_id, active_conv_id)
                    self._notify_antigravity_app(profile, active_conv_id, prompt, project_id=project_id)

                return output or "(Agent executed with no output)"
            except subprocess.TimeoutExpired:
                return f"Antigravity CLI ({acct_name}) timed out after 300 seconds."
            except Exception as exc:
                return f"Antigravity CLI ({acct_name}) execution failed: {exc}"

        return f"[MacBook Default Agent ({acct_name})] Processed prompt for session {session_id}: {prompt}"

    def process_message(self, msg: dict[str, Any]) -> None:
        msg_id = msg.get("id")
        session_id = msg.get("session_id", "default")
        content = msg.get("content", "")
        sender = msg.get("sender")
        account = msg.get("account") or "antigravity-0"
        project_id = msg.get("project_id") or "outside-of-project"
        project_name = msg.get("project_name") or "Outside of Project"

        if sender != "user" or not msg_id:
            return

        profile = resolve_profile(account)

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
            logger.info(f"Processing message {msg_id} in session [{session_id}] (account: {profile['account']}, project: {project_name}): {content[:80]}")

            # 1. Save user message to durable local transcript
            self._save_local_transcript(profile=profile, session_id=session_id, role="user", content=content, msg_id=msg_id)

            # 2. Run local agent
            t0 = time.monotonic()
            agent_reply = self.execute_agent(
                profile=profile,
                prompt=content,
                session_id=session_id,
                user_msg_id=msg_id,
                project_id=project_id,
                project_name=project_name,
            )
            exec_duration = round(time.monotonic() - t0, 1)

            # 3. Save agent reply to durable local transcript
            self._save_local_transcript(profile=profile, session_id=session_id, role="agent", content=agent_reply, msg_id=f"reply_{msg_id}")

            # 4. Push final reply to VPS Outbox (staged for iPhone) with retry
            pushed = False
            for attempt in range(3):
                pushed = self.push_outbox(
                    session_id=session_id,
                    reply_to=msg_id,
                    content=agent_reply,
                    account=profile["account"],
                    msg_type="text",
                    status="completed",
                    duration=exec_duration,
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

            # 7. Proactively trigger project conversation sync and quota sync for this account
            try:
                self.sync_project_conversations(account=profile["account"], force=True)
                self._last_conv_sync_time = time.time()
                self.sync_native_quota()
                self._last_quota_sync_time = time.time()
            except Exception:
                pass
        finally:
            self._processing_msg_ids.discard(msg_id)

    def run_loop(self) -> None:
        logger.info(f"Starting MacAgentBridge connected to {self.relay_url} (poll interval: {self.poll_interval_s}s)")
        if self.dry_run:
            logger.info("Running in DRY RUN mode (echo mock agent).")

        # Initial sync on startup for all accounts
        try:
            self.sync_project_conversations(force=True)
            self._last_conv_sync_time = time.time()
        except Exception as exc:
            logger.warning(f"Initial conversation sync note: {exc}")

        try:
            self.sync_native_quota()
            self._last_quota_sync_time = time.time()
        except Exception as exc:
            logger.warning(f"Initial quota sync note: {exc}")

        backoff = self.poll_interval_s
        while self._running:
            try:
                now = time.time()
                # Periodic background sync of project conversations (only if db mtime changed)
                if now - self._last_conv_sync_time >= 15.0:
                    self.sync_project_conversations(force=False)
                    self._last_conv_sync_time = now

                # Periodic background sync of native quota (every 30s)
                if now - self._last_quota_sync_time >= 30.0:
                    self.sync_native_quota()
                    self._last_quota_sync_time = now

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
    parser.add_argument("--relay-url", default="https://mobile.xycdev.com", help="VPS Relay API URL")
    parser.add_argument("--token", default=None, help="Bearer authorization token")
    parser.add_argument("--session-id", default=None, help="Filter to specific session ID")
    parser.add_argument("--poll-interval", type=float, default=2.0, help="Polling interval in seconds")
    parser.add_argument("--agent-command", default=None, help='Command template to execute, e.g. agy "{prompt}"')
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
