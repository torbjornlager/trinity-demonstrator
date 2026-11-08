"""Connection-scoped ACTOR toplevel preview for the owner-only N7 adapter."""

from contextlib import suppress
import json
from queue import Full, Queue
from threading import Event, Lock, Thread
from uuid import uuid4

from wsproto import ConnectionType, WSConnection
from wsproto.events import AcceptConnection, BytesMessage, CloseConnection, Ping, Request, TextMessage
from wsproto.utilities import LocalProtocolError, RemoteProtocolError


PID_BASE = 1_000_000_000
MAX_MESSAGE = 16384
SESSION_COMMANDS = {"call", "next", "stop", "abort", "halt", "respond"}


def serve(handler):
    if (handler.headers.get_all("Content-Length", []) not in ([], ["0"])
            or "Transfer-Encoding" in handler.headers):
        handler.send_error(400)
        return
    wire = WSConnection(ConnectionType.SERVER)
    try:
        wire.initiate_upgrade_connection(
            [(key.encode("ascii"), value.encode("latin-1"))
             for key, value in handler.headers.raw_items()], handler.path)
        if not any(isinstance(event, Request) for event in wire.events()):
            raise ValueError("Missing WebSocket upgrade")
    except (ValueError, LocalProtocolError, RemoteProtocolError):
        handler.send_error(400, "Invalid WebSocket upgrade")
        return

    wire_lock = Lock()

    def send(event):
        with wire_lock:
            handler.connection.sendall(wire.send(event))

    connection = ActorConnection(handler.server.bridge, handler.server.private_settings[1], send)
    handler.connection.settimeout(60)
    try:
        connection.send(AcceptConnection(extra_headers=[(b"cache-control", b"no-store")]))
        chunks, size = [], 0
        while data := handler.rfile.read1(4096):
            with wire_lock:
                wire.receive_data(data)
                events = list(wire.events())
            for event in events:
                if isinstance(event, CloseConnection):
                    connection.send(event.response())
                    return
                if isinstance(event, Ping):
                    connection.send(event.response())
                if isinstance(event, BytesMessage):
                    connection.send(CloseConnection(code=1003, reason="Expected JSON text"))
                    return
                if isinstance(event, TextMessage):
                    size += len(event.data.encode("utf-8"))
                    if size > MAX_MESSAGE:
                        connection.send(CloseConnection(code=1009, reason="Message too large"))
                        return
                    chunks.append(event.data)
                    if event.message_finished:
                        connection.dispatch("".join(chunks))
                        chunks, size = [], 0
    except (OSError, LocalProtocolError, RemoteProtocolError):
        pass
    finally:
        connection.close()


class ActorConnection:
    def __init__(self, bridge, origin, send):
        self.bridge, self.origin, self.send = bridge, origin, send
        self.io_ack = False
        self.sessions = set()
        self.prompts = {}
        self.output = {}
        self.child_output = Queue(maxsize=64)
        self.closed = Event()
        Thread(target=self.send_child_output, daemon=True).start()

    def enqueue_child_output(self, event):
        # Keep slow browsers off the bridge reader thread.
        with suppress(Full):
            self.child_output.put_nowait(event)

    def send_child_output(self):
        try:
            while not self.closed.is_set():
                event = self.child_output.get()
                if event is None:
                    return
                self.emit({"type": "output", "pid": PID_BASE + event["pid"], "data": event["data"]})
        except (OSError, LocalProtocolError):
            pass

    def emit(self, event):
        self.send(TextMessage(data=json.dumps(event)))

    def dispatch(self, text):
        request = None
        try:
            request = json.loads(text)
            if not isinstance(request, dict):
                raise ValueError("Expected a JSON command object")
            self.command(request)
        except (KeyError, LookupError, TypeError, ValueError, RuntimeError) as error:
            reply = {"type": "error", "data": str(error)}
            if isinstance(request, dict):
                reply.update({key: request[key] for key in ("pid", "request_id") if key in request})
            self.emit(reply)

    def command(self, request):
        command = request["command"]
        if not isinstance(command, str):
            raise ValueError("Expected a command name")
        if command == "transport_hello":
            if request.get("version", 1) != 1:
                raise ValueError("Unsupported ACTOR transport version")
            self.io_ack = request.get("io_ack") is True
            self.emit({"type": "transport_welcome", "version": 1,
                       "protocol": "web_prolog_browser_actor", "browser_pids": True, "io_ack": True})
            return
        if command == "toplevel_spawn":
            fields = {"options": "[session(true)]", "prompt_correlation": True,
                      "browser_options": self.options(request)}
            if "src_text" in request:
                fields["src_text"] = request["src_text"]
            reply = self.bridge.request("spawn", fields)
            if reply["type"] == "spawned":
                self.sessions.add(reply["pid"])
                with self.bridge.state_changed:
                    self.bridge.browser_output[reply["pid"]] = self.enqueue_child_output
            if "request_id" in request:
                reply["request_id"] = request["request_id"]
            self.relay(reply)
            return
        if command == "browser_io_reply":
            pid, needs_ack = self.output.pop(request["request_id"])
            if request.get("status") != "ok":
                self.relay(self.bridge.request("abort", {"pid": pid}))
            else:
                self.relay(self.resume_output(pid, needs_ack))
            return
        action = command.removeprefix("toplevel_")
        if action == command or action not in SESSION_COMMANDS:
            raise ValueError("Unsupported ACTOR preview command")
        wire_pid = request["pid"]
        if type(wire_pid) is not int or wire_pid - PID_BASE not in self.sessions:
            raise LookupError("Unknown toplevel session for this connection")
        pid = wire_pid - PID_BASE
        fields = {"pid": pid}
        if action == "call":
            goal = request["goal"]
            if not isinstance(goal, str):
                raise ValueError("Expected a Prolog goal")
            fields.update(goal=goal, browser_options=self.options(request), browser_origin=self.origin)
        elif action == "respond":
            ref = self.prompts[pid]
            if "prompt_ref" in request and request["prompt_ref"] != ref:
                raise ValueError("Expected the reference from the current prompt")
            value = request["input"]
            if not isinstance(value, str):
                raise ValueError("Expected a Prolog input term")
            fields.update(input=value, prompt_ref=ref)
        reply = self.bridge.request(action, fields)
        if reply["type"] in ("abort", "halted", "responded"):
            self.prompts.pop(pid, None)
        if reply["type"] in ("abort", "halted"):
            self.output = {key: value for key, value in self.output.items() if value[0] != pid}
        if reply["type"] == "halted":
            self.sessions.discard(pid)
            with self.bridge.state_changed:
                self.bridge.browser_output.pop(pid, None)
        self.relay(reply)
        if reply["type"] == "responded":
            self.relay(self.bridge.request("poll", {"pid": pid}))

    @staticmethod
    def options(request):
        options = request.get("options", "[]")
        if not isinstance(options, str):
            raise ValueError("Expected a Prolog option list")
        return options

    def relay(self, event):
        while event["type"] == "output" and not self.io_ack:
            pid = event["pid"]
            needs_ack = event.pop("browser_ack", False)
            self.emit(dict(event, pid=PID_BASE + pid))
            event = self.resume_output(pid, needs_ack)
        event = dict(event)
        pid = event.get("pid")
        if pid is not None:
            event["pid"] = PID_BASE + pid
        if event["type"] == "prompt":
            self.prompts[pid] = event["prompt_ref"]
        if event["type"] == "output":
            ref = uuid4().hex
            self.output[ref] = (pid, event.pop("browser_ack", False))
            event["data"] = event["data"].removesuffix("\n").removesuffix("\r")
            event = {"type": "io_request", "request_id": ref, "event": event}
        self.emit(event)

    def resume_output(self, pid, needs_ack):
        if needs_ack:
            self.bridge.request("browser_ack", {"pid": pid})
        return self.bridge.request("poll", {"pid": pid})

    def close(self):
        with self.bridge.state_changed:
            for pid in self.sessions:
                self.bridge.browser_output.pop(pid, None)
        self.closed.set()
        with suppress(Full):
            self.child_output.put_nowait(None)
        for pid in self.sessions:
            with suppress(LookupError, OSError, RuntimeError, ValueError):
                self.bridge.request("halt", {"pid": pid})
