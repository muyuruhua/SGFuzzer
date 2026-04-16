#!/usr/bin/env python3

import argparse
import csv
import json
import os
import signal
import shlex
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Iterable, List, Optional, Sequence, Set, Tuple

RTSP_DELIM = b"\r\n\r\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Replay corpus inputs and compute external observable RTSP state nodes/edges."
    )
    parser.add_argument("corpus_dir", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--parser-bin", type=Path, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--corpus-format", choices=["auto", "raw", "tlv"], default="auto")
    parser.add_argument("--trim", choices=["none", "triple", "consecutive"], default="triple")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--socket-timeout", type=float, default=0.5)
    parser.add_argument("--inter-message-delay", type=float, default=0.05)
    parser.add_argument("--startup-delay", type=float, default=0.15)
    parser.add_argument("--server-cmd", default="")
    parser.add_argument("--server-ready-timeout", type=float, default=1.5)
    parser.add_argument("--server-timeout", type=float, default=3.0)
    parser.add_argument("--server-kill-delay", type=float, default=1.0)
    parser.add_argument("--input-timeout", type=float, default=4.0)
    parser.add_argument("--run-start-epoch", type=int, default=0)
    return parser.parse_args()


def iter_corpus_files(corpus_dir: Path, limit: int) -> List[Path]:
    files = sorted(
        (path for path in corpus_dir.iterdir() if path.is_file()),
        key=lambda path: (path.stat().st_mtime, path.name),
    )
    if limit > 0:
        return files[:limit]
    return files


def looks_like_tlv(data: bytes) -> bool:
    offset = 0
    seen = 0
    total = len(data)
    while offset + 4 <= total:
        size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        if size == 0 or offset + size > total:
            return False
        offset += size
        seen += 1
    return seen > 0 and offset == total


def load_messages(path: Path, corpus_format: str) -> List[bytes]:
    data = path.read_bytes()
    resolved = corpus_format
    if resolved == "auto":
        resolved = "tlv" if looks_like_tlv(data) else "raw"
    if resolved == "tlv":
        return parse_tlv_messages(data)
    return parse_raw_messages(data)


def parse_tlv_messages(data: bytes) -> List[bytes]:
    messages = []  # type: List[bytes]
    offset = 0
    while offset + 4 <= len(data):
        size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        if size == 0 or offset + size > len(data):
            raise ValueError("invalid TLV corpus entry")
        messages.append(data[offset : offset + size])
        offset += size
    if offset != len(data):
        raise ValueError("trailing bytes in TLV corpus entry")
    return messages


def parse_raw_messages(data: bytes) -> List[bytes]:
    if RTSP_DELIM not in data:
        return [data]
    messages = []  # type: List[bytes]
    parts = data.split(RTSP_DELIM)
    for part in parts:
        if not part:
            continue
        messages.append(part + RTSP_DELIM)
    return messages or [data]


def remaining_time(deadline: Optional[float], default_value: float) -> float:
    if deadline is None:
        return default_value
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("per-input timeout exceeded")
    return min(default_value, remaining)


def start_server(command: str, startup_delay: float):
    if not command:
        return None
    process = subprocess.Popen(
        ["bash", "-lc", command],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )
    time.sleep(startup_delay)
    return process


def wait_for_server_ready(
    host: str,
    port: int,
    process,
    ready_timeout: float,
) -> None:
    deadline = time.monotonic() + max(ready_timeout, 0.1)
    last_error = "server not reachable"
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise RuntimeError("server exited early with code {}".format(process.returncode))
        try:
            with socket.create_connection((host, port), timeout=0.2):
                return
        except OSError as exc:
            last_error = str(exc)
            time.sleep(0.05)
    raise TimeoutError("server did not become ready: {}".format(last_error))


def stop_server(process, kill_delay: float) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGUSR1)
        process.wait(timeout=kill_delay)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=kill_delay)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=kill_delay)
    except ProcessLookupError:
        return


def replay_messages(
    host: str,
    port: int,
    messages: Sequence[bytes],
    socket_timeout: float,
    inter_message_delay: float,
    deadline: Optional[float],
) -> bytes:
    responses = bytearray()
    connect_timeout = max(remaining_time(deadline, max(socket_timeout, 0.1)), 0.05)
    with socket.create_connection((host, port), timeout=connect_timeout) as sock:
        sock.settimeout(max(remaining_time(deadline, socket_timeout), 0.05))
        for message in messages:
            if not message:
                continue
            sock.settimeout(max(remaining_time(deadline, socket_timeout), 0.05))
            sock.sendall(message)
            time.sleep(min(inter_message_delay, remaining_time(deadline, inter_message_delay)))
            responses.extend(drain_socket(sock, socket_timeout, deadline))
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        responses.extend(drain_socket(sock, socket_timeout, deadline))
    return bytes(responses)


def drain_socket(sock: socket.socket, socket_timeout: float, deadline: Optional[float]) -> bytes:
    chunks = bytearray()
    while True:
        try:
            sock.settimeout(max(remaining_time(deadline, socket_timeout), 0.05))
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        except TimeoutError:
            break
        except OSError:
            break
        if not chunk:
            break
        chunks.extend(chunk)
    return bytes(chunks)


def parse_states(parser_bin: Path, trim_mode: str, response_bytes: bytes):
    proc = subprocess.run(
        [str(parser_bin), "--format", "json", "--trim", trim_mode, "-"],
        input=response_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", errors="replace") or "parser failed")
    return json.loads(proc.stdout.decode("utf-8"))


def edges_from_states(states: Sequence[int]) -> Set[Tuple[int, int]]:
    return set(zip(states, states[1:]))


def write_csv(path: Path, header: Sequence[str], rows: Iterable[Sequence[object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        for row in rows:
            writer.writerow(row)


def compute_elapsed_seconds(run_start_epoch: int, timestamp: int) -> int:
    if run_start_epoch <= 0:
        return 0
    if timestamp < run_start_epoch:
        return 0
    return int(timestamp - run_start_epoch)


def observe_corpus(args: argparse.Namespace) -> None:
    corpus_files = iter_corpus_files(args.corpus_dir, args.limit)
    if not corpus_files:
        raise SystemExit("no input files found in {}".format(args.corpus_dir))

    parser_bin = args.parser_bin.resolve()
    if not parser_bin.is_file():
        raise SystemExit("parser binary not found: {}".format(parser_bin))

    cumulative_nodes = set()  # type: Set[int]
    cumulative_edges = set()  # type: Set[Tuple[int, int]]
    per_input_rows = []  # type: List[List[object]]
    over_time_rows = []  # type: List[List[object]]

    for corpus_file in corpus_files:
        server = None
        response_bytes = b""
        error_text = ""
        deadline = time.monotonic() + max(args.input_timeout, 0.1)
        try:
            messages = load_messages(corpus_file, args.corpus_format)
            server = start_server(args.server_cmd, args.startup_delay)
            wait_for_server_ready(args.host, args.port, server, args.server_ready_timeout)
            response_bytes = replay_messages(
                args.host,
                args.port,
                messages,
                args.socket_timeout,
                args.inter_message_delay,
                deadline,
            )
            parsed = parse_states(parser_bin, args.trim, response_bytes)
            states = [int(value) for value in parsed.get("states", [])]
            sequence = str(parsed.get("sequence", ""))
        except Exception as exc:
            states = [0]
            sequence = "0"
            error_text = str(exc)
        finally:
            stop_server(server, args.server_kill_delay)

        nodes = set(states)
        edges = edges_from_states(states)
        new_nodes = nodes - cumulative_nodes
        new_edges = edges - cumulative_edges
        cumulative_nodes.update(nodes)
        cumulative_edges.update(edges)
        timestamp = int(corpus_file.stat().st_mtime)
        elapsed_seconds = compute_elapsed_seconds(args.run_start_epoch, timestamp)

        per_input_rows.append(
            [
                timestamp,
            elapsed_seconds,
                corpus_file.name,
                len(response_bytes),
                sequence,
                len(states),
                len(new_nodes),
                len(new_edges),
                len(cumulative_nodes),
                len(cumulative_edges),
                error_text,
            ]
        )
        over_time_rows.append([timestamp, elapsed_seconds, len(cumulative_nodes), len(cumulative_edges)])

    write_csv(
        args.output_dir / "per_input_states.csv",
        [
            "Time",
            "elapsed_seconds",
            "Input",
            "ResponseBytes",
            "StateSequence",
            "StateCount",
            "NewNodes",
            "NewEdges",
            "CumulativeObsNodes",
            "CumulativeObsEdges",
            "Error",
        ],
        per_input_rows,
    )
    write_csv(
        args.output_dir / "state_over_time.csv",
        ["Time", "elapsed_seconds", "obs_nodes", "obs_edges"],
        over_time_rows,
    )


def main() -> int:
    args = parse_args()
    observe_corpus(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
