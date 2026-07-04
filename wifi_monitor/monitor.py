#!/usr/bin/env python3
"""FPGA电能质量WiFi监控程序，仅使用Python标准库。"""

from __future__ import annotations

import argparse
import csv
import html
import json
import math
import socket
import sqlite3
import threading
import webbrowser
from collections import deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


REQUIRED_FIELDS = ("R", "P", "F", "T", "M", "Z", "A", "E", "D", "S", "U", "G", "N")
ADC_REFERENCE_VOLTS = 3.3
ADC_CODE_LEVELS = 256
CSV_FIELDS = (
    "pc_time", "seq", "rms", "peak", "freq", "fault_type", "fault_mode",
    "freeze", "alarm", "event_count", "adc", "system_time", "duration",
    "running", "checksum", "missing_before", "raw",
)
CSV_HEADERS = CSV_FIELDS[:-1] + ("wifi_raw_frame",)
WIFI_FIELD_DESCRIPTION = (
    "WiFi字段说明: PQ=Power Quality(电能质量); "
    "R=Root Mean Square(均方根值); P=Peak(峰值); F=Frequency(频率); "
    "T=Fault Type(故障类型); M=Fault Mode(故障注入模式); "
    "Z=Freeze Status(冻结状态); A=Alarm Status(报警状态); "
    "E=Event Count(事件计数); D=ADC Data(ADC采样值); "
    "S=System Time(系统运行时间); U=Fault Duration(故障持续时间); "
    "G=Run/Stop Status(启停状态); N=Frame Number(帧序号); "
    "C=Checksum(异或校验码)"
)


class FrameError(ValueError):
    """遥测帧格式或校验错误。"""

    def __init__(self, message: str, checksum_error: bool = False) -> None:
        super().__init__(message)
        self.checksum_error = checksum_error


def xor_checksum(payload: str) -> int:
    value = 0
    for byte in payload.encode("ascii"):
        value ^= byte
    return value


def code_to_volts(code: int) -> float:
    """将8位ADC码值换算为ADC引脚处电压。"""
    return round(code * ADC_REFERENCE_VOLTS / ADC_CODE_LEVELS, 4)


def add_physical_values(sample: dict[str, Any]) -> dict[str, Any]:
    """为实时帧和数据库历史帧补充物理量，不改变原始码值。"""
    sample["rms_volts"] = code_to_volts(sample["rms"])
    sample["peak_volts"] = code_to_volts(sample["peak"])
    sample["adc_volts"] = code_to_volts(sample["adc"])
    return sample


def parse_frame(line: str) -> dict[str, Any]:
    raw = line.strip("\r\n \t")
    start = raw.find("PQ,")
    if start < 0:
        raise FrameError("未找到PQ帧头")
    raw = raw[start:]

    marker = ",C="
    if marker not in raw:
        raise FrameError("缺少校验字段")
    payload, checksum_text = raw.rsplit(marker, 1)
    if len(checksum_text) != 2:
        raise FrameError("校验字段长度错误")
    try:
        received_checksum = int(checksum_text, 16)
    except ValueError as exc:
        raise FrameError("校验字段不是十六进制") from exc

    calculated_checksum = xor_checksum(payload)
    if received_checksum != calculated_checksum:
        raise FrameError(
            f"校验失败: 接收{received_checksum:02X}, 计算{calculated_checksum:02X}",
            checksum_error=True,
        )

    parts = payload.split(",")
    if not parts or parts[0] != "PQ":
        raise FrameError("帧头错误")
    fields: dict[str, str] = {}
    for part in parts[1:]:
        if "=" not in part:
            raise FrameError(f"字段格式错误: {part}")
        key, value = part.split("=", 1)
        fields[key] = value

    missing = [key for key in REQUIRED_FIELDS if key not in fields]
    if missing:
        raise FrameError("缺少字段: " + ",".join(missing))

    try:
        sample = {
            "seq": int(fields["N"]),
            "rms": int(fields["R"]),
            "peak": int(fields["P"]),
            "freq": int(fields["F"]),
            "fault_type": int(fields["T"]),
            "fault_mode": int(fields["M"]),
            "freeze": int(fields["Z"]),
            "alarm": int(fields["A"]),
            "event_count": int(fields["E"]),
            "adc": int(fields["D"]),
            "system_time": fields["S"],
            "duration": int(fields["U"]),
            "running": int(fields["G"]),
            "checksum": checksum_text.upper(),
            "raw": raw,
        }
    except ValueError as exc:
        raise FrameError("数字字段格式错误") from exc

    if not 0 <= sample["seq"] <= 999:
        raise FrameError("帧序号超出范围")
    if sample["running"] not in (0, 1):
        raise FrameError("运行状态码超出范围")
    return add_physical_values(sample)


def format_frame(fields: dict[str, int | str]) -> str:
    """生成测试帧，字段顺序与FPGA发送端一致。"""
    payload = (
        "PQ,R={R:03d},P={P:03d},F={F:03d},T={T},M={M},Z={Z},A={A},"
        "E={E:02d},D={D:03d},S={S},U={U:03d},G={G},N={N:03d}"
    ).format(**fields)
    return f"{payload},C={xor_checksum(payload):02X}"


class SequenceTracker:
    def __init__(self) -> None:
        self.last: int | None = None

    def reset(self) -> None:
        self.last = None

    def observe(self, sequence: int) -> int:
        if self.last is None:
            self.last = sequence
            return 0
        if sequence == self.last:
            return 0
        expected = (self.last + 1) % 1000
        missing = (sequence - expected) % 1000
        self.last = sequence
        return missing


class MonitorState:
    def __init__(self, target: str, csv_path: Path, database_path: Path, session_id: int) -> None:
        self.lock = threading.Lock()
        self.samples: deque[dict[str, Any]] = deque(maxlen=1200)
        self.next_id = 1
        self.status: dict[str, Any] = {
            "connection": "等待连接",
            "target": target,
            "received": 0,
            "valid": 0,
            "checksum_errors": 0,
            "parse_errors": 0,
            "missing_frames": 0,
            "last_error": "",
            "last_frame_time": "",
            "csv_path": str(csv_path),
            "database_path": str(database_path),
            "session_id": session_id,
        }

    def set_status(self, **values: Any) -> None:
        with self.lock:
            self.status.update(values)

    def record_error(self, error: FrameError) -> None:
        with self.lock:
            self.status["received"] += 1
            key = "checksum_errors" if error.checksum_error else "parse_errors"
            self.status[key] += 1
            self.status["last_error"] = str(error)

    def add_sample(self, sample: dict[str, Any], missing: int) -> dict[str, Any]:
        now = datetime.now().astimezone().isoformat(timespec="milliseconds")
        with self.lock:
            item = dict(sample)
            item["id"] = self.next_id
            item["pc_time"] = now
            item["missing_before"] = missing
            self.next_id += 1
            self.samples.append(item)
            self.status["received"] += 1
            self.status["valid"] += 1
            self.status["missing_frames"] += missing
            self.status["last_frame_time"] = now
            self.status["last_error"] = ""
            return item

    def snapshot(self, after: int) -> dict[str, Any]:
        with self.lock:
            samples = [sample for sample in self.samples if sample["id"] > after]
            return {"status": dict(self.status), "samples": samples[-500:]}


class CsvRecorder:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        is_new = not path.exists() or path.stat().st_size == 0
        self.handle = path.open("a", newline="", encoding="utf-8-sig")
        self.writer = csv.DictWriter(self.handle, fieldnames=CSV_HEADERS)
        if is_new:
            description_row = {key: "" for key in CSV_HEADERS}
            description_row["wifi_raw_frame"] = WIFI_FIELD_DESCRIPTION
            self.writer.writerow(description_row)
            self.writer.writeheader()
            self.handle.flush()

    def write(self, sample: dict[str, Any]) -> None:
        row = {key: sample.get(key, "") for key in CSV_FIELDS[:-1]}
        row["wifi_raw_frame"] = sample.get("raw", "")
        self.writer.writerow(row)
        self.handle.flush()

    def close(self) -> None:
        self.handle.close()


class DatabaseStore:
    """线程安全的SQLite会话、采样与错误存储。"""

    def __init__(self, path: Path, target: str, csv_path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.lock = threading.RLock()
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.connection.row_factory = sqlite3.Row
        with self.lock:
            self.connection.execute("PRAGMA journal_mode=WAL")
            self.connection.execute("PRAGMA synchronous=NORMAL")
            self.connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    target TEXT NOT NULL,
                    csv_path TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS samples (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL,
                    pc_time TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    rms INTEGER NOT NULL,
                    peak INTEGER NOT NULL,
                    freq INTEGER NOT NULL,
                    fault_type INTEGER NOT NULL,
                    fault_mode INTEGER NOT NULL,
                    freeze_state INTEGER NOT NULL,
                    alarm INTEGER NOT NULL,
                    event_count INTEGER NOT NULL,
                    adc INTEGER NOT NULL,
                    system_time TEXT NOT NULL,
                    duration INTEGER NOT NULL,
                    running INTEGER NOT NULL,
                    checksum TEXT NOT NULL,
                    missing_before INTEGER NOT NULL,
                    raw TEXT NOT NULL,
                    FOREIGN KEY(session_id) REFERENCES sessions(id)
                );
                CREATE TABLE IF NOT EXISTS frame_errors (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id INTEGER NOT NULL,
                    pc_time TEXT NOT NULL,
                    error_type TEXT NOT NULL,
                    message TEXT NOT NULL,
                    raw TEXT NOT NULL,
                    FOREIGN KEY(session_id) REFERENCES sessions(id)
                );
                CREATE INDEX IF NOT EXISTS idx_samples_session_id
                    ON samples(session_id, id);
                CREATE INDEX IF NOT EXISTS idx_errors_session_id
                    ON frame_errors(session_id, id);
                """
            )
            cursor = self.connection.execute(
                "INSERT INTO sessions(started_at, target, csv_path) VALUES (?, ?, ?)",
                (self.now(), target, str(csv_path)),
            )
            self.session_id = int(cursor.lastrowid)
            self.connection.commit()

    @staticmethod
    def now() -> str:
        return datetime.now().astimezone().isoformat(timespec="milliseconds")

    def write(self, sample: dict[str, Any]) -> None:
        values = (
            self.session_id, sample["pc_time"], sample["seq"], sample["rms"],
            sample["peak"], sample["freq"], sample["fault_type"], sample["fault_mode"],
            sample["freeze"], sample["alarm"], sample["event_count"], sample["adc"],
            sample["system_time"], sample["duration"], sample["running"],
            sample["checksum"], sample["missing_before"], sample["raw"],
        )
        with self.lock:
            self.connection.execute(
                """
                INSERT INTO samples(
                    session_id, pc_time, seq, rms, peak, freq, fault_type,
                    fault_mode, freeze_state, alarm, event_count, adc,
                    system_time, duration, running, checksum, missing_before, raw
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                values,
            )
            self.connection.commit()

    def record_error(self, error: FrameError, raw: str) -> None:
        error_type = "checksum" if error.checksum_error else "parse"
        with self.lock:
            self.connection.execute(
                """
                INSERT INTO frame_errors(session_id, pc_time, error_type, message, raw)
                VALUES (?, ?, ?, ?, ?)
                """,
                (self.session_id, self.now(), error_type, str(error), raw),
            )
            self.connection.commit()

    def list_sessions(self) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.connection.execute(
                """
                SELECT s.id, s.started_at, s.ended_at, s.target,
                       COUNT(p.id) AS sample_count,
                       COALESCE(SUM(p.missing_before), 0) AS missing_frames,
                       COALESCE(SUM(CASE WHEN p.fault_type != 0 THEN 1 ELSE 0 END), 0) AS fault_samples,
                       MIN(p.pc_time) AS first_sample_at,
                       MAX(p.pc_time) AS last_sample_at
                FROM sessions s
                LEFT JOIN samples p ON p.session_id = s.id
                GROUP BY s.id
                ORDER BY s.id DESC
                """
            ).fetchall()
        return [dict(row) for row in rows]

    def get_session(self, session_id: int) -> dict[str, Any] | None:
        with self.lock:
            row = self.connection.execute(
                "SELECT * FROM sessions WHERE id = ?", (session_id,)
            ).fetchone()
        return dict(row) if row else None

    @staticmethod
    def sample_from_row(row: sqlite3.Row) -> dict[str, Any]:
        item = dict(row)
        item["freeze"] = item.pop("freeze_state")
        item["db_id"] = item.pop("id")
        return add_physical_values(item)

    def history(self, session_id: int, after: int, limit: int) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.connection.execute(
                """
                SELECT id, pc_time, seq, rms, peak, freq, fault_type, fault_mode,
                       freeze_state, alarm, event_count, adc, system_time, duration,
                       running, checksum, missing_before, raw
                FROM samples
                WHERE session_id = ? AND id > ?
                ORDER BY id
                LIMIT ?
                """,
                (session_id, after, limit),
            ).fetchall()
        return [self.sample_from_row(row) for row in rows]

    def all_samples(self, session_id: int) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        after = 0
        while True:
            page = self.history(session_id, after, 5000)
            records.extend(page)
            if len(page) < 5000:
                return records
            after = page[-1]["db_id"]

    def error_counts(self, session_id: int) -> dict[str, int]:
        with self.lock:
            rows = self.connection.execute(
                """
                SELECT error_type, COUNT(*) AS count
                FROM frame_errors WHERE session_id = ? GROUP BY error_type
                """,
                (session_id,),
            ).fetchall()
        counts = {"checksum": 0, "parse": 0}
        for row in rows:
            counts[row["error_type"]] = row["count"]
        return counts

    def close(self) -> None:
        with self.lock:
            self.connection.execute(
                "UPDATE sessions SET ended_at = ? WHERE id = ?",
                (self.now(), self.session_id),
            )
            self.connection.commit()
            self.connection.close()


FAULT_NAMES = ("正常", "暂降", "暂升", "过频", "欠频", "削顶", "谐波畸变")


def fault_name(value: int) -> str:
    return FAULT_NAMES[value] if 0 <= value < len(FAULT_NAMES) else f"未知({value})"


def seconds_between(start: str, end: str) -> float:
    return max(0.0, (datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds())


def build_report(store: DatabaseStore, session_id: int) -> dict[str, Any] | None:
    session = store.get_session(session_id)
    if session is None:
        return None
    samples = store.all_samples(session_id)
    errors = store.error_counts(session_id)
    report: dict[str, Any] = {
        "session": session,
        "sample_count": len(samples),
        "missing_frames": sum(item["missing_before"] for item in samples),
        "checksum_errors": errors["checksum"],
        "parse_errors": errors["parse"],
        "metrics": {},
        "fault_summary": [],
        "episodes": [],
        "timeline": [],
    }
    if not samples:
        report["elapsed_seconds"] = 0.0
        return report

    report["elapsed_seconds"] = seconds_between(samples[0]["pc_time"], samples[-1]["pc_time"])
    report["first_system_time"] = samples[0]["system_time"]
    report["last_system_time"] = samples[-1]["system_time"]
    for key in ("rms_volts", "peak_volts", "freq", "adc_volts"):
        values = [item[key] for item in samples]
        report["metrics"][key] = {
            "min": min(values),
            "max": max(values),
            "avg": round(sum(values) / len(values), 2),
        }

    active: dict[str, Any] | None = None
    previous: dict[str, Any] | None = None
    episodes: list[dict[str, Any]] = []
    timeline: list[dict[str, Any]] = []

    def add_timeline(sample: dict[str, Any], kind: str, label: str) -> None:
        timeline.append({
            "pc_time": sample["pc_time"],
            "system_time": sample["system_time"],
            "kind": kind,
            "label": label,
            "fault_type": sample["fault_type"],
            "seq": sample["seq"],
        })

    def close_episode(end_sample: dict[str, Any]) -> None:
        nonlocal active
        if active is None:
            return
        active["end_pc_time"] = end_sample["pc_time"]
        active["end_system_time"] = end_sample["system_time"]
        active["elapsed_seconds"] = round(
            seconds_between(active["start_pc_time"], end_sample["pc_time"]), 3
        )
        episodes.append(active)
        active = None

    for sample in samples:
        if previous is None or sample["running"] != previous["running"]:
            add_timeline(sample, "run" if sample["running"] else "pause", "运行" if sample["running"] else "暂停")
        if previous is not None and sample["freeze"] != previous["freeze"]:
            add_timeline(sample, "freeze" if sample["freeze"] else "unfreeze", "波形冻结" if sample["freeze"] else "解除冻结")
        if previous is None or sample["fault_type"] != previous["fault_type"]:
            if previous is not None and previous["fault_type"] != 0:
                close_episode(sample)
                add_timeline(sample, "fault_end", fault_name(previous["fault_type"]) + "结束")
            if sample["fault_type"] != 0:
                active = {
                    "fault_type": sample["fault_type"],
                    "fault_name": fault_name(sample["fault_type"]),
                    "start_pc_time": sample["pc_time"],
                    "start_system_time": sample["system_time"],
                    "max_rms": sample["rms"],
                    "max_peak": sample["peak"],
                    "max_rms_volts": sample["rms_volts"],
                    "max_peak_volts": sample["peak_volts"],
                    "min_freq": sample["freq"],
                    "max_freq": sample["freq"],
                }
                add_timeline(sample, "fault_start", fault_name(sample["fault_type"]) + "开始")
        if active is not None:
            active["max_rms"] = max(active["max_rms"], sample["rms"])
            active["max_peak"] = max(active["max_peak"], sample["peak"])
            active["max_rms_volts"] = max(active["max_rms_volts"], sample["rms_volts"])
            active["max_peak_volts"] = max(active["max_peak_volts"], sample["peak_volts"])
            active["min_freq"] = min(active["min_freq"], sample["freq"])
            active["max_freq"] = max(active["max_freq"], sample["freq"])
        previous = sample

    if active is not None:
        close_episode(samples[-1])

    summary: dict[int, dict[str, Any]] = {}
    for episode in episodes:
        item = summary.setdefault(episode["fault_type"], {
            "fault_type": episode["fault_type"],
            "fault_name": episode["fault_name"],
            "count": 0,
            "elapsed_seconds": 0.0,
        })
        item["count"] += 1
        item["elapsed_seconds"] = round(item["elapsed_seconds"] + episode["elapsed_seconds"], 3)
    report["fault_summary"] = list(summary.values())
    report["episodes"] = episodes
    report["timeline"] = timeline
    return report


class Receiver(threading.Thread):
    def __init__(
        self,
        state: MonitorState,
        recorder: CsvRecorder,
        database: DatabaseStore,
        host: str,
        port: int,
        stop_event: threading.Event,
    ) -> None:
        super().__init__(daemon=True)
        self.state = state
        self.recorder = recorder
        self.database = database
        self.host = host
        self.port = port
        self.stop_event = stop_event
        self.sequence = SequenceTracker()

    def handle_line(self, line: str) -> None:
        try:
            sample = parse_frame(line)
        except FrameError as error:
            self.state.record_error(error)
            self.database.record_error(error, line)
            return
        missing = self.sequence.observe(sample["seq"])
        item = self.state.add_sample(sample, missing)
        self.recorder.write(item)
        self.database.write(item)

    def run(self) -> None:
        while not self.stop_event.is_set():
            self.state.set_status(connection="正在连接")
            try:
                with socket.create_connection((self.host, self.port), timeout=4.0) as connection:
                    connection.settimeout(1.0)
                    self.sequence.reset()
                    self.state.set_status(connection="已连接", last_error="")
                    pending = b""
                    while not self.stop_event.is_set():
                        try:
                            chunk = connection.recv(4096)
                        except socket.timeout:
                            continue
                        if not chunk:
                            raise ConnectionError("远端已断开连接")
                        pending += chunk
                        while b"\n" in pending:
                            raw_line, pending = pending.split(b"\n", 1)
                            self.handle_line(raw_line.decode("ascii", errors="ignore"))
            except (OSError, ConnectionError) as error:
                self.state.set_status(connection="连接中断", last_error=str(error))
                self.stop_event.wait(2.0)
        self.state.set_status(connection="已停止")


class DemoReceiver(threading.Thread):
    def __init__(
        self,
        state: MonitorState,
        recorder: CsvRecorder,
        database: DatabaseStore,
        stop_event: threading.Event,
    ) -> None:
        super().__init__(daemon=True)
        self.state = state
        self.recorder = recorder
        self.database = database
        self.stop_event = stop_event

    def run(self) -> None:
        sequence = 0
        self.state.set_status(connection="演示模式")
        while not self.stop_event.wait(0.5):
            phase = sequence / 14.0
            fault = 1 if 5 <= sequence % 40 < 12 else 0
            fields = {
                "R": 64 + round(3 * math.sin(phase)),
                "P": 90 + round(2 * math.sin(phase * 0.7)),
                "F": 50,
                "T": fault,
                "M": fault,
                "Z": int(fault and sequence % 40 >= 8),
                "A": fault,
                "E": (sequence // 40) % 32,
                "D": 128 + round(65 * math.sin(phase * 2.0)),
                "S": f"{sequence % 10000:04d}",
                "U": min(255, sequence % 12) if fault else 0,
                "G": 0 if 15 <= sequence % 40 < 20 else 1,
                "N": sequence,
            }
            sample = parse_frame(format_frame(fields))
            item = self.state.add_sample(sample, 0)
            self.recorder.write(item)
            self.database.write(item)
            sequence = (sequence + 1) % 1000


def render_report_page(report: dict[str, Any]) -> bytes:
    session = report["session"]
    metrics = report.get("metrics", {})

    def metric_row(label: str, key: str) -> str:
        item = metrics.get(key)
        if not item:
            return f"<tr><td>{label}</td><td colspan='3'>无数据</td></tr>"
        return (
            f"<tr><td>{label}</td><td>{item['min']}</td>"
            f"<td>{item['max']}</td><td>{item['avg']}</td></tr>"
        )

    fault_rows = "".join(
        f"<tr><td>{html.escape(item['fault_name'])}</td><td>{item['count']}</td>"
        f"<td>{item['elapsed_seconds']:.3f}</td></tr>"
        for item in report["fault_summary"]
    ) or "<tr><td colspan='3'>未检测到故障</td></tr>"

    episode_rows = "".join(
        "<tr>"
        f"<td>{html.escape(item['fault_name'])}</td>"
        f"<td>{html.escape(item['start_pc_time'])}</td>"
        f"<td>{html.escape(item['end_pc_time'])}</td>"
        f"<td>{item['elapsed_seconds']:.3f}</td>"
        f"<td>{item['max_rms_volts']:.3f}</td><td>{item['max_peak_volts']:.3f}</td>"
        f"<td>{item['min_freq']}~{item['max_freq']}</td>"
        "</tr>"
        for item in report["episodes"]
    ) or "<tr><td colspan='7'>无故障区段</td></tr>"

    timeline_rows = "".join(
        "<tr>"
        f"<td>{html.escape(item['pc_time'])}</td>"
        f"<td>{html.escape(item['system_time'])}</td>"
        f"<td>{html.escape(item['label'])}</td>"
        f"<td>{item['seq']:03d}</td>"
        "</tr>"
        for item in report["timeline"]
    ) or "<tr><td colspan='4'>无状态变化</td></tr>"

    document = f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>电能质量故障报告 - 会话{session['id']}</title>
<style>
body{{font-family:'Segoe UI','Microsoft YaHei',sans-serif;color:#17202a;margin:28px;font-size:13px}}
header{{display:flex;align-items:center;border-bottom:3px solid #16835f;padding-bottom:12px;margin-bottom:20px}}
h1{{font-size:22px;margin:0}} h2{{font-size:16px;margin:24px 0 8px}}
button{{margin-left:auto;height:32px;border:1px solid #7d8791;background:white;border-radius:4px;padding:0 12px}}
.meta{{display:grid;grid-template-columns:repeat(4,1fr);border:1px solid #ccd3da}}
.meta div{{padding:10px;border-right:1px solid #ccd3da}} .meta div:last-child{{border-right:0}}
.label{{display:block;color:#68737e;font-size:11px;margin-bottom:4px}}
table{{width:100%;border-collapse:collapse}} th,td{{border:1px solid #d8dde3;padding:7px 9px;text-align:left}}
th{{background:#edf0f2}} .summary{{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}}
.summary div{{border-left:4px solid #2767b1;background:#f1f4f6;padding:10px}}
@media print{{button{{display:none}} body{{margin:12mm}}}}
</style></head><body>
<header><h1>电能质量故障报告</h1><button onclick="window.print()">打印 / 保存PDF</button></header>
<div class="meta">
<div><span class="label">会话</span>#{session['id']}</div>
<div><span class="label">开始时间</span>{html.escape(session['started_at'])}</div>
<div><span class="label">结束时间</span>{html.escape(session['ended_at'] or '运行中')}</div>
<div><span class="label">数据源</span>{html.escape(session['target'])}</div>
</div>
<h2>数据完整性</h2>
<div class="summary">
<div><span class="label">有效样本</span>{report['sample_count']}</div>
<div><span class="label">记录时长</span>{report['elapsed_seconds']:.1f} s</div>
<div><span class="label">丢失帧</span>{report['missing_frames']}</div>
<div><span class="label">校验 / 格式错误</span>{report['checksum_errors']} / {report['parse_errors']}</div>
</div>
<h2>测量统计</h2>
<table><thead><tr><th>指标</th><th>最小值</th><th>最大值</th><th>平均值</th></tr></thead><tbody>
{metric_row('RMS电压(V)', 'rms_volts')}{metric_row('Peak电压(V)', 'peak_volts')}{metric_row('频率(Hz)', 'freq')}{metric_row('ADC瞬时电压(V)', 'adc_volts')}
</tbody></table>
<h2>故障汇总</h2>
<table><thead><tr><th>故障类型</th><th>次数</th><th>累计持续时间(s)</th></tr></thead><tbody>{fault_rows}</tbody></table>
<h2>故障区段</h2>
<table><thead><tr><th>类型</th><th>开始</th><th>结束</th><th>时长(s)</th><th>最大RMS(V)</th><th>最大Peak(V)</th><th>频率范围(Hz)</th></tr></thead><tbody>{episode_rows}</tbody></table>
<h2>状态时间轴</h2>
<table><thead><tr><th>电脑时间</th><th>系统时间</th><th>事件</th><th>帧序号</th></tr></thead><tbody>{timeline_rows}</tbody></table>
</body></html>"""
    return document.encode("utf-8")


def make_handler(
    state: MonitorState,
    csv_path: Path,
    static_dir: Path,
    database: DatabaseStore,
):
    class Handler(BaseHTTPRequestHandler):
        def send_bytes(self, data: bytes, content_type: str, status: int = 200) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def send_json(self, value: Any, status: int = 200) -> None:
            self.send_bytes(
                json.dumps(value, ensure_ascii=False).encode("utf-8"),
                "application/json; charset=utf-8",
                status,
            )

        @staticmethod
        def query_int(query: dict[str, list[str]], key: str, default: int) -> int:
            try:
                return int(query.get(key, [str(default)])[0])
            except ValueError:
                return default

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            if parsed.path == "/":
                self.send_bytes((static_dir / "index.html").read_bytes(), "text/html; charset=utf-8")
                return
            if parsed.path == "/api/state":
                query = parse_qs(parsed.query)
                try:
                    after = int(query.get("after", ["0"])[0])
                except ValueError:
                    after = 0
                self.send_json(state.snapshot(after))
                return
            if parsed.path == "/api/sessions":
                self.send_json({
                    "current_session_id": database.session_id,
                    "sessions": database.list_sessions(),
                })
                return
            if parsed.path == "/api/history":
                query = parse_qs(parsed.query)
                session_id = self.query_int(query, "session", database.session_id)
                after = self.query_int(query, "after", 0)
                limit = min(2000, max(1, self.query_int(query, "limit", 1000)))
                if database.get_session(session_id) is None:
                    self.send_json({"error": "会话不存在"}, 404)
                    return
                page = database.history(session_id, after, limit + 1)
                has_more = len(page) > limit
                self.send_json({
                    "session_id": session_id,
                    "samples": page[:limit],
                    "has_more": has_more,
                })
                return
            if parsed.path == "/api/report":
                query = parse_qs(parsed.query)
                session_id = self.query_int(query, "session", database.session_id)
                report = build_report(database, session_id)
                if report is None:
                    self.send_json({"error": "会话不存在"}, 404)
                else:
                    self.send_json(report)
                return
            if parsed.path == "/report":
                query = parse_qs(parsed.query)
                session_id = self.query_int(query, "session", database.session_id)
                report = build_report(database, session_id)
                if report is None:
                    self.send_bytes("会话不存在".encode("utf-8"), "text/plain; charset=utf-8", 404)
                else:
                    self.send_bytes(render_report_page(report), "text/html; charset=utf-8")
                return
            if parsed.path == "/api/csv":
                if not csv_path.exists():
                    self.send_bytes(b"CSV not ready", "text/plain; charset=utf-8", 404)
                    return
                data = csv_path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/csv; charset=utf-8")
                self.send_header("Content-Disposition", f'attachment; filename="{csv_path.name}"')
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_bytes(b"Not found", "text/plain; charset=utf-8", 404)

        def log_message(self, fmt: str, *args: Any) -> None:
            return

    return Handler


def default_csv_path() -> Path:
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    return Path(__file__).resolve().parent / "data" / f"power_quality_{stamp}.csv"


def default_database_path() -> Path:
    return Path(__file__).resolve().parent / "data" / "power_quality.db"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="FPGA电能质量WiFi监控程序")
    parser.add_argument("--fpga-host", default="192.168.4.1", help="FPGA WiFi服务器地址")
    parser.add_argument("--fpga-port", type=int, default=8686, help="FPGA WiFi服务器端口")
    parser.add_argument("--listen", default="127.0.0.1", help="本地监控页面监听地址")
    parser.add_argument("--http-port", type=int, default=8765, help="本地监控页面端口")
    parser.add_argument("--csv", type=Path, default=None, help="CSV输出文件")
    parser.add_argument("--database", type=Path, default=None, help="SQLite数据库文件")
    parser.add_argument("--no-browser", action="store_true", help="不自动打开浏览器")
    parser.add_argument("--demo", action="store_true", help="使用模拟数据测试界面")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    csv_path = (args.csv or default_csv_path()).resolve()
    database_path = (args.database or default_database_path()).resolve()
    target = "演示数据" if args.demo else f"{args.fpga_host}:{args.fpga_port}"
    recorder = CsvRecorder(csv_path)
    database = DatabaseStore(database_path, target, csv_path)
    state = MonitorState(target, csv_path, database_path, database.session_id)
    stop_event = threading.Event()

    if args.demo:
        receiver: threading.Thread = DemoReceiver(state, recorder, database, stop_event)
    else:
        receiver = Receiver(
            state, recorder, database, args.fpga_host, args.fpga_port, stop_event
        )
    receiver.start()

    static_dir = Path(__file__).resolve().parent / "static"
    server = ThreadingHTTPServer(
        (args.listen, args.http_port),
        make_handler(state, csv_path, static_dir, database),
    )
    server.daemon_threads = True
    url = f"http://{args.listen}:{args.http_port}/"
    print(f"监控页面: {url}")
    print(f"CSV文件: {csv_path}")
    print(f"数据库: {database_path} (会话#{database.session_id})")
    print("按Ctrl+C停止。")
    if not args.no_browser:
        threading.Timer(0.7, lambda: webbrowser.open(url)).start()

    try:
        server.serve_forever(poll_interval=0.3)
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        server.shutdown()
        server.server_close()
        receiver.join(timeout=3.0)
        recorder.close()
        database.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
