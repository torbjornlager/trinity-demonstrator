#!/usr/bin/env python3
"""Serve the ECLiPSe HTTP bridge locally or behind a trusted owner proxy."""

import argparse
from concurrent.futures import Future, TimeoutError as FutureTimeout
from hmac import compare_digest
from http.client import HTTPConnection, HTTPSConnection, HTTPException
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
from itertools import count
import json
from mimetypes import guess_type
import os
from pathlib import Path
import re
from select import select
import signal
import subprocess
import tarfile
from threading import BoundedSemaphore, Condition, Thread
from time import monotonic
from urllib.parse import parse_qs, unquote, urlencode, urlsplit
from uuid import uuid4
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
DEMO_ROUTE = "/examples/APIs/http_example-1.html"
DEMO = HERE.parents[1] / DEMO_ROUTE.lstrip("/")
SHELL_PREFIX = "/n7-shell/"
ROUTES = {
    "/actor_probe": "actor_probe",
    "/toplevel_spawn": "spawn",
    "/toplevel_call": "call",
    "/toplevel_next": "next",
    "/toplevel_poll": "poll",
    "/toplevel_respond": "respond",
    "/toplevel_stop": "stop",
    "/toplevel_abort": "abort",
    "/toplevel_halt": "halt",
}


class PromptReferenceError(ValueError):
    pass


class CapacityError(RuntimeError):
    pass


def private_settings(parser, args):
    supplied = (args.private_origin, args.owner, args.proxy_token_file)
    if all(value is None for value in supplied):
        return None
    if not all(supplied):
        parser.error("private mode requires --private-origin, --owner and --proxy-token-file")
    try:
        origin = urlsplit(args.private_origin)
        port = origin.port
    except ValueError:
        parser.error("--private-origin must be an HTTPS origin without a path")
    if (origin.scheme != "https" or not origin.hostname or origin.username is not None
            or port == 0 or args.private_origin != f"https://{origin.netloc}"
            or any(char.isspace() for char in args.private_origin)):
        parser.error("--private-origin must be an HTTPS origin without a path")
    try:
        token = args.proxy_token_file.read_bytes().strip()
    except OSError:
        parser.error("could not read --proxy-token-file")
    if re.fullmatch(rb"[0-9a-fA-F]{64}", token) is None:
        parser.error("--proxy-token-file must contain a 64-digit hexadecimal token")
    return origin.netloc, args.private_origin, args.owner, token


def peer_url(url):
    if not isinstance(url, str) or len(url) > 2048 or re.search(r"[\s\\\x00-\x1f\x7f]", url):
        raise ValueError("invalid_peer_url")
    parsed = urlsplit(url)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username is not None or parsed.fragment or parsed.port == 0):
        raise ValueError("invalid_peer_url")
    return parsed, (parsed.scheme, parsed.netloc.lower())


def fetch_peer(allowed_peers, request):
    parsed, origin = peer_url(request["url"])
    if origin not in allowed_peers:
        raise ValueError("peer_not_allowed")
    if request["operation"] == "call":
        params = request["params"]
        if (parsed.path not in ("", "/") or parsed.query
                or set(params) != {"goal", "template", "src_text", "offset", "limit", "once"}
                or not all(isinstance(params[key], str) for key in ("goal", "template", "src_text"))
                or type(params["offset"]) is not int or params["offset"] < 0
                or type(params["limit"]) is not int or not 1 <= params["limit"] <= 100
                or not isinstance(params["once"], bool)):
            raise ValueError("invalid_peer_request")
        query = dict(params, goal=f"({params['goal']})", template=f"({params['template']})",
                     format="prolog", once=str(params["once"]).lower())
        if not query["src_text"]:
            del query["src_text"]
        target = "/call?" + urlencode(query)
    elif request["operation"] == "source":
        target = parsed.path or "/"
        if parsed.query:
            target += "?" + parsed.query
    else:
        raise ValueError("invalid_peer_operation")
    if len(target) > 16384:
        raise ValueError("peer_request_too_large")
    connection_type = HTTPSConnection if parsed.scheme == "https" else HTTPConnection
    deadline = monotonic() + 2
    connection = connection_type(parsed.hostname, parsed.port, timeout=1)
    try:
        connection.request("GET", target, headers={"Connection": "close"})
        with connection.getresponse() as response:
            if response.status != 200:
                raise ValueError(f"peer_http_{response.status}")
            data = bytearray()
            while monotonic() < deadline:
                chunk = response.read1(8192)
                if not chunk:
                    return data.decode("utf-8")
                data.extend(chunk)
                if len(data) > 128 * 1024:
                    raise ValueError("peer_response_too_large")
            raise TimeoutError()
    finally:
        connection.close()


def bundled_chart_source(shell_assets):
    if shell_assets is None:
        raise ValueError("shell_assets_required")
    chart_path = shell_assets / "examples/statecharts/20 jev-deployment-assistant.xml"
    root = ET.parse(chart_path).getroot()
    if (root.tag != "statechart" or root.get("version") != "0.2"
            or set(root.attrib) != {"version", "initial"}):
        raise ValueError("unsupported_chart")
    datamodel = root.find("datamodel")
    states = root.findall("state")
    state_ids = {state.get("id") for state in states}
    initial = root.get("initial")
    if (datamodel is None or datamodel.attrib or len(datamodel)
            or len(root.findall("datamodel")) != 1
            or len(state_ids) != len(states) or initial not in state_ids
            or any(not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z_0-9]*", name)
                   for name in state_ids)
            or any(element.tag not in {"datamodel", "state"} for element in root)):
        raise ValueError("unsupported_chart")
    clauses = [datamodel.text or "", f"n7_chart_initial({initial})."]
    for state in states:
        name = state.get("id")
        if set(state.attrib) != {"id"}:
            raise ValueError("unsupported_chart_state")
        for transition in state:
            target = transition.get("to", name)
            event = transition.get("on")
            guard = transition.get("if", "true")
            action = (transition.text or "").strip() or "true"
            if (transition.tag != "go" or target not in state_ids or not event or len(transition)
                    or set(transition.attrib) - {"on", "to", "if"}):
                raise ValueError("unsupported_chart_transition")
            clauses.append(
                f"n7_chart_step({name}, N7Event, {target}) :- "
                f"N7Event = ({event}), once(({guard})), !, ({action})."
            )
    return "\n".join(clauses)


def json_byte_escape(match):
    escape = match[0]
    if len(escape) != 4:
        return escape
    byte = int(escape[1:], 8)
    if byte < 128:
        return f"\\u{byte:04x}".encode("ascii")
    return bytes([byte])


def unicode_binding_text(text):
    def decode(match):
        escapes = match[0]
        if len(escapes) == 2:
            return escapes
        raw = bytes(int(escapes[i + 1:i + 4], 8) for i in range(0, len(escapes), 4))
        return "".join(
            char if char.isprintable() else "".join(
                f"\\{byte:03o}" for byte in char.encode("utf-8", "surrogateescape")
            )
            for char in raw.decode("utf-8", "surrogateescape")
        )

    # Consume ordinary escapes as a unit, including a literal backslash.
    return re.sub(r"(?:\\[23][0-7]{2})+|\\.", decode, text)


class Bridge:
    def __init__(self, process, on_failure=None, allowed_peers=(), shell_assets=None):
        self.process = process
        self.on_failure = on_failure
        self.allowed_peers = allowed_peers
        self.shell_assets = shell_assets
        self.egress_slots = BoundedSemaphore(4)
        if on_failure is not None:
            os.set_blocking(process.stdin.fileno(), False)
        self.sessions = {}
        self.prompt_modes = {}
        self.state_changed = Condition()
        self.request_ids = count(1)
        self.pending = {}
        self.browser_output = {}
        self.busy = {}
        self.poll_deadlines = {}
        self.read_error = None

    def read_reply(self):
        limit = 512 * 1024 if self.on_failure is not None else -1
        line = self.process.stdout.readline(limit + 1 if limit > 0 else -1)
        if not line:
            raise RuntimeError("ECLiPSe bridge closed its output")
        if 0 < limit < len(line.encode("utf-8")):
            raise RuntimeError("ECLiPSe reply exceeded the pilot size limit")
        try:
            return json.loads(line)
        except json.JSONDecodeError as error:
            # json_write/3 quotes UTF-8 bytes with Prolog octal escapes.
            # Match complete escapes so a quoted backslash stays literal.
            encoded = re.sub(rb"\\(?:[0-3][0-7]{2}|.)", json_byte_escape, line.encode("utf-8"))
            try:
                return json.loads(encoded)
            except (json.JSONDecodeError, UnicodeDecodeError):
                raise RuntimeError("Invalid JSON from the ECLiPSe bridge") from error

    def request(self, command, fields, *, expired_at=None, timeout=6):
        deadline = monotonic() + timeout if self.on_failure is not None else None
        try:
            return self.dispatch(command, fields, deadline, expired_at)
        except (TimeoutError, FutureTimeout):
            self.fail("ECLiPSe backend exceeded the request deadline")
            raise self.read_error from None
        except BrokenPipeError:
            self.fail("ECLiPSe backend closed its request pipe")
            raise self.read_error from None

    def dispatch(self, command, fields, deadline, expired_at):
        with self.state_changed:
            if expired_at is not None:
                pid = fields["pid"]
                if self.poll_deadlines.get(pid) != expired_at or self.busy.get(pid):
                    return None
            while True:
                if self.read_error is not None:
                    raise self.read_error
                request = self.prepare(command, fields)
                pid = request.get("pid")
                active = self.busy.get(pid, set())
                reply_pending = "respond" in active and command in ("respond", "abort", "halt")
                control_pending = command == "respond" and ("abort" in active or "halt" in active)
                competing_controls = ((command == "abort" and "halt" in active) or
                                      (command == "halt" and "abort" in active))
                correlated_reply = (reply_pending or control_pending) and self.prompt_modes[pid] is True
                if not (competing_controls or correlated_reply):
                    break
                # Recheck the session after the pending reply or control request.
                # Waiting releases the bridge lock.
                if not self.state_changed.wait(self.remaining(deadline)):
                    raise TimeoutError()
            if active and not (command in ("abort", "halt") and active <= {"call", "next", "poll"}):
                raise ValueError("Another request is pending for this session")
            request_id = next(self.request_ids)
            request["request_id"] = request_id
            result = Future()
            if deadline is not None and command in ("spawn", "stateless"):
                queued = sum(item["command"] == command for item, _ in self.pending.values())
                if command == "spawn" and len(self.sessions) + queued >= 4:
                    raise CapacityError("N7 has reached its four-session limit")
                if command == "stateless" and queued >= 2:
                    raise CapacityError("N7 has reached its two-call stateless limit")
            self.write_request(request, deadline)
            self.pending[request_id] = (request, result)
            if pid is not None:
                self.busy.setdefault(pid, set()).add(command)
        return result.result(timeout=self.remaining(deadline))

    @staticmethod
    def remaining(deadline):
        return None if deadline is None else max(0, deadline - monotonic())

    def write_request(self, request, deadline):
        line = json.dumps(request, ensure_ascii=False) + "\n"
        if deadline is None:
            self.process.stdin.write(line)
            self.process.stdin.flush()
            return
        fd = self.process.stdin.fileno()
        remaining = memoryview(line.encode("utf-8"))
        while remaining:
            if not select([], [fd], [], self.remaining(deadline))[1]:
                raise TimeoutError()
            try:
                remaining = remaining[os.write(fd, remaining):]
            except BlockingIOError:
                continue

    def fail(self, message):
        with self.state_changed:
            if self.read_error is not None:
                return
            self.read_error = RuntimeError(message)
            for _, result in self.pending.values():
                result.set_exception(self.read_error)
            self.pending.clear()
            self.state_changed.notify_all()
        if self.on_failure is not None:
            self.on_failure()

    def read_responses(self):
        try:
            while True:
                reply = self.read_reply()
                event = reply.get("event", reply) if reply["type"] == "stateless" else reply
                if event["type"] == "success":
                    for row in event["data"]:
                        for name, value in row.items():
                            row[name] = unicode_binding_text(value)
                if reply.get("type") == "egress":
                    if self.egress_slots.acquire(blocking=False):
                        Thread(target=self.run_egress, args=(reply,), daemon=True).start()
                    else:
                        self.finish_egress(reply, "error", "peer_capacity")
                    continue
                if reply.get("type") == "browser_child_output":
                    with self.state_changed:
                        deliver = self.browser_output.get(reply["pid"])
                    if deliver is not None:
                        deliver(reply)
                    continue
                with self.state_changed:
                    request_id = reply.pop("request_id")
                    request, result = self.pending[request_id]
                    self.complete(request, reply)
                    del self.pending[request_id]
                    result.set_result(reply)
                    self.state_changed.notify_all()
        except (OSError, RuntimeError, KeyError, ValueError) as error:
            self.fail(f"ECLiPSe transport failed: {error}")

    def run_egress(self, request):
        try:
            try:
                if request["operation"] == "demo_chart":
                    body = bundled_chart_source(self.shell_assets)
                else:
                    body = fetch_peer(self.allowed_peers, request)
                status = "ok"
            except (ValueError, KeyError, TypeError, OSError, HTTPException, ET.ParseError):
                status, body = "error", "peer_request_failed"
            self.finish_egress(request, status, body)
        finally:
            self.egress_slots.release()

    def finish_egress(self, request, status, body):
        try:
            with self.state_changed:
                if self.read_error is None:
                    self.write_request(
                        {"command": "egress_result", "request_id": request["egress_id"],
                         "pid": request["actor_id"], "status": status, "body": body},
                        monotonic() + 1 if self.on_failure is not None else None,
                    )
        except (OSError, KeyError):
            self.fail("Could not deliver the ECLiPSe peer response")

    def retire_unpolled_queries(self):
        while True:
            with self.state_changed:
                if self.read_error is not None:
                    return
                deadline, pid = min(((deadline, pid) for pid, deadline in self.poll_deadlines.items()
                                     if pid not in self.busy), default=(None, None))
                if deadline is None or deadline > monotonic():
                    self.state_changed.wait(self.remaining(deadline))
                    continue
            try:
                reply = self.request("halt", {"pid": pid}, expired_at=deadline)
            except (OSError, RuntimeError) as error:
                self.fail(f"Could not retire an unpolled N7 query: {error}")
                return
            if reply is not None and reply["type"] != "halted":
                self.fail("Could not retire an unpolled N7 query")
                return

    def complete(self, request, reply):
        command = request["command"]
        if command == "actor_probe":
            return
        pid = request.get("pid")
        if pid is not None:
            self.busy[pid].remove(command)
            if not self.busy[pid]:
                del self.busy[pid]
        kind = reply["type"]
        retired = reply.pop("retired", False)
        if kind == "spawned":
            self.sessions[reply["pid"]] = ("idle", None)
            self.prompt_modes[reply["pid"]] = request.get("prompt_correlation")
        elif kind == "halted" or retired:
            self.sessions.pop(pid, None)
            self.prompt_modes.pop(pid, None)
        elif pid not in self.sessions:
            return
        elif kind == "prompt":
            self.sessions[request["pid"]] = ("prompt", reply["prompt_ref"])
            mode = self.prompt_modes[pid]
            if mode is False:
                del reply["prompt_ref"]
            elif mode is True:
                reply["prompt_ref"] = str(reply["prompt_ref"])
        elif kind in ("output", "responded"):
            self.sessions[request["pid"]] = ("poll", None)
        elif command in ("call", "next", "poll"):
            state = "next" if kind == "success" and reply["more"] else "idle"
            self.sessions[request["pid"]] = (state, None)
        elif kind in ("stop", "abort"):
            self.sessions[request["pid"]] = ("idle", None)
        if self.on_failure is not None and pid is not None:
            if kind in ("output", "responded"):
                self.poll_deadlines[pid] = monotonic() + 10
            elif self.sessions.get(pid) != ("poll", None):
                self.poll_deadlines.pop(pid, None)

    def prepare(self, command, fields):
        if command == "stateless":
            return stateless_request(fields)
        if command == "actor_probe":
            if "pid" in fields:
                raise ValueError("Actor probe addresses its resident echo service")
            return dict(fields, command=command)
        if command == "spawn":
            options = dict(fields)
            browser = options.pop("browser_options", None)
            mode = options.pop("prompt_correlation", None)
            source = options.pop("src_text", "")
            if "prompt_correlation" in fields and not isinstance(mode, bool):
                raise ValueError("Expected prompt_correlation to be a boolean")
            if not isinstance(source, str):
                raise ValueError("Expected src_text to be a string")
            if options != {"options": "[session(true)]"}:
                raise ValueError("Expected spawn options [session(true)]")
            request = {"command": command}
            if browser is not None:
                request["browser_options"] = browser
            if mode is not None:
                request["prompt_correlation"] = mode
            if source:
                request["src_text"] = source
            return request

        pid = int(fields["pid"])
        if pid not in self.sessions:
            raise LookupError("Unknown toplevel session")
        if fields.get("format", "json") != "json":
            raise ValueError("Expected format=json")
        state, prompt_ref = self.sessions[pid]
        if command == "respond":
            mode = self.prompt_modes[pid]
            expected = None if mode is False else str(prompt_ref)
            if state != "prompt" or fields.get("prompt_ref") != expected:
                raise PromptReferenceError("Expected the reference from the current prompt")
        required_state = {
            "call": "idle", "next": "next", "stop": "next",
            "poll": "poll", "respond": "prompt", "browser_ack": "poll",
        }.get(command)
        if required_state is not None and state != required_state:
            raise ValueError(f"Cannot {command} while the session is in state {state}")

        request = {"command": command, "pid": pid}
        if command == "call":
            # JSON answers use named goal bindings, as in the SWI node.
            goal = fields["goal"]
            limit = int(fields.get("limit", "1"))
            if not goal.strip() or not 1 <= limit <= 100:
                raise ValueError("Expected a goal and a limit from 1 to 100")
            request.update(goal=goal, limit=limit)
            if "browser_options" in fields:
                request.update(browser_options=fields["browser_options"],
                               browser_origin=fields["browser_origin"])
        elif command == "respond":
            value = fields["input"].strip()
            if value.endswith("."):
                value = value[:-1].rstrip()
            if not value:
                raise ValueError("Expected a Prolog term")
            request.update(input=value, prompt_ref=prompt_ref)
        return request


def stateless_request(fields):
    output_format = fields.get("format")
    if output_format not in ("prolog", "json"):
        raise ValueError("Expected format=prolog or format=json")
    if fields.keys() - {"format", "goal", "template", "offset", "limit", "once", "src_text"}:
        raise ValueError("Unsupported stateless query parameter")
    goal = fields["goal"]
    template = fields.get("template", goal)
    offset = int(fields.get("offset", "0"))
    limit = int(fields.get("limit", "100"))
    once = fields.get("once", "false")
    if not goal.strip() or not template.strip() or offset < 0 or not 1 <= limit <= 100:
        raise ValueError("Expected a goal, a template, a non-negative offset and a limit from 1 to 100")
    if once not in ("true", "false"):
        raise ValueError("Expected once=true or once=false")
    return dict(command="stateless", goal=goal, template=template, format=output_format,
                src_text=fields.get("src_text", ""),
                offset=offset, limit=limit, once=once == "true")


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def admit_request(self, *, executes=False):
        private = self.server.private_settings
        if private is None:
            host = f"127.0.0.1:{self.server.server_port}"
            origin = f"http://{host}"
        else:
            host, origin, owner, token = private
        if (self.headers.get_all("Host") != [host]
                or self.headers.get_all("Origin", [origin]) != [origin]):
            self.send_error(404)
            return False
        if private is not None:
            credentials = self.headers.get_all("X-Web-Prolog-Proxy-Token", [])
            if (len(credentials) != 1 or not compare_digest(credentials[0].encode("latin-1"), token)
                    or self.headers.get_all("X-Web-Prolog-User") != [owner]):
                self.send_error(403)
                return False
            fetch_site = self.headers.get_all("Sec-Fetch-Site", [])
            if executes and (fetch_site not in ([], ["same-origin"])
                             or ("Origin" not in self.headers and not fetch_site)):
                self.send_error(403)
                return False
        return True

    def end_headers(self):
        if self.server.private_settings is not None:
            self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        path = urlsplit(self.path)
        if path.path == "/node_info" and self.server.private_settings is not None:
            self.serve_node_info()
            return
        websocket = path.path == "/ws" and getattr(self.server, "actor_ws", None)
        if not self.admit_request(executes=path.path == "/call" or bool(websocket)):
            return
        if websocket:
            if self.headers.get_all("Origin") != [self.server.private_settings[1]]:
                self.send_error(403)
                return
            self.close_connection = True
            websocket(self)
        elif path.path == "/call":
            self.serve_stateless(path.query)
        elif path.path in ("/", "/demonstrator") and self.server.private_settings is not None:
            self.reply(200, "text/html; charset=utf-8", (HERE / "n7_pilot.html").read_bytes())
        elif path.path == SHELL_PREFIX + "session.json" and self.server.shell_assets is not None:
            self.reply(200, "application/json", b'{"principal_id":"owner","principal_execution":true}')
        elif path.path.startswith(SHELL_PREFIX) and self.server.shell_assets is not None:
            self.serve_shell_asset(path.path)
        elif self.path == DEMO_ROUTE:
            self.reply(200, "text/html; charset=utf-8", DEMO.read_bytes())
        else:
            self.send_error(404)

    def serve_shell_asset(self, path):
        root = self.server.shell_assets
        relative = unquote(path[len(SHELL_PREFIX):]) or "index.html"
        try:
            asset = (root / relative).resolve()
            if not asset.is_relative_to(root) or not asset.is_file():
                self.send_error(404)
                return
            body = asset.read_bytes()
        except (OSError, RuntimeError, ValueError):
            self.send_error(404)
            return
        content_type = ("text/plain; charset=utf-8" if relative == "shared-db.pl"
                        else guess_type(asset)[0] or "application/octet-stream")
        self.reply(200, content_type, body)

    def serve_node_info(self):
        host, origin, _, _ = self.server.private_settings
        if self.headers.get_all("Host") != [host]:
            self.send_error(404)
            return
        bridge = self.server.bridge
        if (not self.server.runtime_version or bridge.read_error is not None
                or bridge.process.poll() is not None):
            self.send_error(503)
            return
        info = {
            "self_url": origin,
            "implementation": "ECLiPSe CLP",
            "version": self.server.runtime_version,
            "profile": getattr(self.server, "advertised_profile", "isotope"),
            "auth": "private",
            "services": [],
            "provides": [],
        }
        if self.server.shell_assets is not None:
            info["http_session_options"] = ["src_text", "prompt_correlation"]
        self.reply(200, "application/json; charset=utf-8", json.dumps(info).encode())

    def serve_stateless(self, query):
        try:
            if len(query) > 16384:
                raise ValueError("Query is too large")
            parameters = parse_qs(query, keep_blank_values=True)
            if any(len(values) != 1 for values in parameters.values()):
                raise ValueError("Duplicate query parameter")
            fields = {name: values[0] for name, values in parameters.items()}
            reply = self.server.bridge.request("stateless", fields)
            if reply["type"] != "stateless":
                raise RuntimeError(reply)
            if fields["format"] == "json":
                if not isinstance(reply.get("event"), dict):
                    raise RuntimeError("ECLiPSe returned no JSON answer")
                content_type = "application/json"
                body = json.dumps(reply["event"])
            else:
                content_type = "text/plain"
                body = reply["body"]
        except (KeyError, ValueError) as error:
            self.send_error(400, str(error))
        except CapacityError as error:
            self.send_error(429, str(error))
        except (OSError, RuntimeError) as error:
            self.send_error(502, str(error))
        else:
            self.reply(200, f"{content_type}; charset=utf-8", body.encode())

    def do_POST(self):
        if not self.admit_request(executes=True):
            return
        command = ROUTES.get(self.path)
        if command is None or (command == "actor_probe" and self.server.private_settings is not None):
            self.send_error(404)
            return
        try:
            fields = self.read_fields(command)
            response = self.server.bridge.request(command, fields)
            status = 404 if response.get("code") == "session_lost" else 200
        except KeyError as error:
            status, response = 400, {"type": "error", "data": f"Missing field {error}"}
        except LookupError as error:
            status, response = 404, {"type": "error", "code": "session_lost", "data": str(error)}
        except PromptReferenceError as error:
            status, response = 400, {"type": "error", "code": "invalid_prompt_ref", "data": str(error)}
        except ValueError as error:
            status, response = 400, {"type": "error", "data": str(error)}
        except CapacityError as error:
            status, response = 429, {"type": "error", "code": "capacity", "data": str(error)}
        except (OSError, RuntimeError) as error:
            status, response = 502, {"type": "error", "data": str(error)}
        self.reply(status, "application/json", json.dumps(response).encode())

    def read_fields(self, command):
        size = int(self.headers.get("Content-Length", "0"))
        if not 0 < size <= 16384:
            raise ValueError("Expected a request body of at most 16384 bytes")
        body = self.rfile.read(size).decode("utf-8")
        content_type = self.headers.get_content_type()
        if command in ("spawn", "actor_probe") and content_type == "application/json":
            fields = json.loads(body)
            if isinstance(fields, dict) and (command != "spawn" or "browser_options" not in fields):
                return fields
        elif command not in ("spawn", "actor_probe") and content_type == "application/x-www-form-urlencoded":
            fields = parse_qs(body, keep_blank_values=True)
            if "browser_options" not in fields and all(len(values) == 1 for values in fields.values()):
                return {key: values[0] for key, values in fields.items()}
        raise ValueError("Unexpected request body")

    def reply(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Eclipse-Bridge", "parallel-sessions")
        self.end_headers()
        self.wfile.write(body)


class PilotServer(ThreadingHTTPServer):
    def __init__(self, address, handler):
        self.slots = BoundedSemaphore(16)
        super().__init__(address, handler)

    def process_request(self, request, client_address):
        if self.slots.acquire(blocking=False):
            try:
                super().process_request(request, client_address)
            except Exception:
                self.slots.release()
                raise
        else:
            try:
                request.settimeout(0.1)
                request.sendall(b"HTTP/1.0 503 Service Unavailable\r\nCache-Control: no-store\r\n"
                                b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
            finally:
                self.shutdown_request(request)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def bridge_archive():
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name in ("actors.ecl", "solution_buffer.ecl", "toplevel_actors.ecl",
                     "isotope_bridge.ecl", "isotope_rpc.ecl", "stateless_rpc.ecl",
                     "server_behaviours.ecl", "demo_services.ecl", "n5_shared_db.ecl",
                     "n5_actor_compat.sed"):
            archive.add(HERE / name, arcname=name)
        for name in ("shared_db_common.pl", "shared_db_actor_common.pl",
                     "shared_db_n4.pl", "shared_db_linda.pl"):
            archive.add(HERE.parents[1] / "Deployment" / name, arcname=name)
        archive.add(HERE.parents[1] / "examples/services/linda_space.pl", arcname="linda_space.pl")
    return buffer.getvalue()


def development_engine(parser, runtime_dir):
    runtime = runtime_dir.resolve()
    runtime_lib = "/eclipse/lib/aarch64_linux"
    if not (runtime / "lib/aarch64_linux/eclipse.exe").is_file():
        parser.error("runtime_dir must contain lib/aarch64_linux/eclipse.exe")

    archive = bridge_archive()
    command = [
        "docker", "run", "--rm", "-i", "--platform", "linux/arm64",
        "--network", "none",
        "--mount", f"type=bind,source={runtime},target=/eclipse,readonly",
        "-e", "ECLIPSEDIR=/eclipse", "-e", f"LD_LIBRARY_PATH={runtime_lib}",
        "-e", f"BRIDGE_ARCHIVE_SIZE={len(archive)}",
        "debian:bookworm-slim", "sh", "-ec",
        # Read exactly the archive prefix and leave stdin open for JSON.
        'mkdir /tmp/src; '
        'dd bs="$BRIDGE_ARCHIVE_SIZE" count=1 iflag=fullblock status=none '
        '| tar -xf - -C /tmp/src; '
        'cd /tmp/src; '
        'sed -f n5_actor_compat.sed shared_db_actor_common.pl > shared_db_actor_eclipse.pl; '
        "sed -n '/^linda_local_address(/p' shared_db_linda.pl > shared_db_linda_address.pl; "
        'exec "$LD_LIBRARY_PATH/eclipse.exe" -D /eclipse -b isotope_bridge.ecl '
        '-e isotope_bridge:run',
    ]
    return command, archive


def pilot_engine(image, name):
    return ["docker", "run", "--rm", "-i", "--pull=never", "--platform", "linux/arm64",
            "--name", name, "--network", "none", "--read-only",
            "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777",
            "--user", "65532:65532", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
            "--cpus", "0.75", "--memory", "384m", "--memory-swap", "384m", "--pids-limit", "64",
            "--ulimit", "core=0:0", "--log-driver", "none", image]


def remove_engine(name):
    try:
        subprocess.run(["docker", "rm", "-f", name], timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime_dir", nargs="?", type=Path, help="extracted Linux ARM64 ECLiPSe runtime")
    parser.add_argument("--pilot-image", help="local N7 engine image to run with pilot limits")
    parser.add_argument("--port", type=int, default=8088)
    parser.add_argument("--private-origin", help="public HTTPS origin forwarded by the owner proxy")
    parser.add_argument("--owner", help="exact owner identity supplied by the trusted proxy")
    parser.add_argument("--proxy-token-file", type=Path, help="file holding the private proxy token")
    parser.add_argument("--allow-peer", action="append", default=[], metavar="ORIGIN",
                        help="allow stateless RPC and source fetches to this exact HTTP(S) origin")
    parser.add_argument("--shell-assets", type=Path,
                        help="serve a prepared same-origin static demonstrator at /n7-shell/")
    parser.add_argument("--actor-ws", action="store_true", help="enable the private ACTOR WebSocket preview")
    parser.add_argument("--advertise-actor", action="store_true", help="advertise the enabled WebSocket transport as ACTOR")
    args = parser.parse_args()
    if args.advertise_actor and not args.actor_ws:
        parser.error("--advertise-actor requires --actor-ws")
    private = private_settings(parser, args)
    actor_ws = None
    if args.actor_ws:
        if private is None or not args.pilot_image:
            parser.error("--actor-ws requires a private packaged pilot")
        try:
            from n7_actor_ws import serve as actor_ws
        except ImportError as error:
            parser.error(f"--actor-ws requires the N7 WebSocket dependencies: {error}")
    shell_assets = args.shell_assets.resolve() if args.shell_assets is not None else None
    if shell_assets is not None and (private is None or not (shell_assets / "index.html").is_file()):
        parser.error("--shell-assets requires a private adapter and a packaged index.html")
    allowed_peers = set()
    for value in args.allow_peer:
        try:
            parsed, origin = peer_url(value)
            if parsed.path not in ("", "/") or parsed.query:
                raise ValueError()
        except ValueError:
            parser.error("--allow-peer expects an HTTP(S) origin")
        allowed_peers.add(origin)
    if bool(args.runtime_dir) == bool(args.pilot_image):
        parser.error("supply either runtime_dir or --pilot-image")
    stop_backend = None
    server_type = ThreadingHTTPServer
    if args.pilot_image:
        if private is None:
            parser.error("--pilot-image requires private proxy settings")
        name = "trinity-n7-" + uuid4().hex
        command, archive = pilot_engine(args.pilot_image, name), None

        def stop_backend():
            remove_engine(name)

        server_type = PilotServer

        def shutdown(signum, frame):
            raise KeyboardInterrupt

        signal.signal(signal.SIGTERM, shutdown)
    else:
        command, archive = development_engine(parser, args.runtime_dir)

    with server_type(("127.0.0.1", args.port), Handler) as server:
        server.private_settings = private
        server.actor_ws = actor_ws
        server.advertised_profile = "actor" if args.advertise_actor else "isotope"
        server.shell_assets = shell_assets
        with subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, encoding="utf-8",
        ) as process:
            # A failed pilot must release its listening port so its supervisor
            # can bring up a fresh backend instead of serving a dead bridge.
            on_failure = server.shutdown if stop_backend is not None else None
            server.bridge = Bridge(process, on_failure, allowed_peers, shell_assets)
            try:
                if archive is not None:
                    process.stdin.buffer.write(archive)
                    process.stdin.buffer.flush()
                ready = server.bridge.read_reply()
                if ready.get("type") != "ready":
                    raise RuntimeError("Unexpected ECLiPSe startup reply")
                version = ready.get("version")
                server.runtime_version = version if isinstance(version, str) else None
                reader = Thread(target=server.bridge.read_responses, daemon=True)
                reader.start()
                if stop_backend is not None:
                    Thread(target=server.bridge.retire_unpolled_queries, daemon=True).start()
                print(f"ECLiPSe bridge with independent HTTP sessions on port {server.server_port}")
                if private is None:
                    print(f"http://127.0.0.1:{server.server_port}{DEMO_ROUTE}", flush=True)
                else:
                    print(f"Private proxy origin {private[1]}", flush=True)
                server.serve_forever()
                if server.bridge.read_error is not None:
                    raise SystemExit(str(server.bridge.read_error))
            except KeyboardInterrupt:
                pass
            except (OSError, RuntimeError) as error:
                raise SystemExit(f"Could not start the ECLiPSe bridge: {error}") from None
            finally:
                try:
                    process.stdin.close()
                except BrokenPipeError:
                    pass
                if stop_backend is not None:
                    stop_backend()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()


if __name__ == "__main__":
    main()
