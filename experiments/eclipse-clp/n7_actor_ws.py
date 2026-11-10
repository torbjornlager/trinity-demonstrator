"""Connection-scoped ACTOR toplevel preview for the owner-only N7 adapter."""

from contextlib import suppress
import json
from queue import Empty, Full, Queue
from socket import create_connection, timeout as SocketTimeout
from ssl import create_default_context
from threading import BoundedSemaphore, Event, Lock, Thread
from time import monotonic
from uuid import uuid4

from wsproto import ConnectionType, WSConnection
from wsproto.events import AcceptConnection, BytesMessage, CloseConnection, Ping, Request, TextMessage
from wsproto.utilities import LocalProtocolError, RemoteProtocolError


MAX_PEER_MESSAGE = 16 * 1024
# The owner shell sends editor snapshots in JSON. SXML's own limit still
# applies separately to each document after the request has been decoded.
MAX_OWNER_MESSAGE = 256 * 1024
SESSION_COMMANDS = {"call", "next", "stop", "abort", "halt", "respond"}
QUERY_COMMANDS = ("toplevel_call", "toplevel_next", "toplevel_respond", "browser_io_reply")


def published_counter(host):
    """Ask the published N3 counter from a short-lived N3 toplevel."""
    goal = (
        "self(Self), counter@'https://n3.elfenbenstornet.se' ! count(Self), "
        "receive({count(Count) -> true}, [timeout(1), on_timeout(fail)])"
    )
    return str(int(peer_toplevel_once(host, goal, 2)["Count"]))


def model_chat(host, params):
    messages = params.get("messages")
    if set(params) != {"messages"} or not isinstance(messages, list) or not 1 <= len(messages) <= 5:
        raise ValueError("invalid_model_messages")
    terms = []
    size = 0
    for index, text in enumerate(messages):
        if not isinstance(text, str) or not text:
            raise ValueError("invalid_model_message")
        size += len(text)
        role = "assistant" if index % 2 else "user"
        terms.append(f"{role}({json.dumps(text, ensure_ascii=False)})")
    if size > 2000 or len(terms) % 2 == 0:
        raise ValueError("invalid_model_conversation")
    goal = "model_chat([" + ",".join(terms) + "],Reply)"
    return peer_toplevel_once(host, goal, 38)["Reply"] + ".\n"


def peer_toplevel_once(host, goal, seconds):
    """Run a fixed demo service goal on a connection-scoped peer toplevel."""
    wire = WSConnection(ConnectionType.CLIENT)
    deadline = monotonic() + seconds
    with create_connection((host, 443), timeout=1) as raw:
        with create_default_context().wrap_socket(raw, server_hostname=host) as connection:
            def send(event):
                connection.settimeout(max(0.001, deadline - monotonic()))
                connection.sendall(wire.send(event))

            def events():
                while monotonic() < deadline:
                    connection.settimeout(max(0.001, deadline - monotonic()))
                    data = connection.recv(4096)
                    if not data:
                        break
                    wire.receive_data(data)
                    for event in wire.events():
                        if isinstance(event, Ping):
                            send(event.response())
                        else:
                            yield event
                raise ValueError("demo_peer_closed")

            def receive():
                chunks = []
                size = 0
                for event in incoming:
                    if not isinstance(event, TextMessage):
                        raise ValueError("invalid_demo_peer_message")
                    size += len(event.data.encode("utf-8"))
                    if size > MAX_PEER_MESSAGE:
                        raise ValueError("demo_peer_message_too_large")
                    chunks.append(event.data)
                    if event.message_finished:
                        return json.loads("".join(chunks))

            incoming = events()
            try:
                send(Request(host=host, target="/ws"))
                if not isinstance(next(incoming), AcceptConnection):
                    raise ValueError("demo_peer_upgrade_failed")
                send(TextMessage(data=json.dumps({"command": "toplevel_spawn", "options": "[session(true)]"})))
                spawned = receive()
                if spawned["type"] != "spawned" or type(spawned.get("pid")) is not int:
                    raise ValueError("demo_peer_spawn_failed")
                pid = spawned["pid"]
                send(TextMessage(data=json.dumps({
                    "command": "toplevel_call", "pid": pid, "goal": goal, "options": "[limit(1)]"
                })))
                answer = receive()
                if answer["type"] != "success" or len(answer["data"]) != 1:
                    raise ValueError("demo_service_unavailable")
                bindings = answer["data"][0]
                if not isinstance(bindings, dict):
                    raise ValueError("invalid_peer_bindings")
                send(CloseConnection(code=1000))
                return bindings
            except (LocalProtocolError, RemoteProtocolError) as error:
                raise ValueError("invalid_demo_peer_protocol") from error


class PeerActor:
    """One peer-owned actor or toplevel and its connection."""

    def __init__(self, endpoint, request, emit):
        self.endpoint, self.request, self.emit = endpoint, request, emit
        self.commands = Queue(maxsize=32)
        self.cancelled = Event()

    def command(self, request):
        try:
            self.commands.put_nowait(request)
        except Full:
            self.cancelled.set()

    def run(self):
        endpoint = self.endpoint
        with create_connection((endpoint.hostname, endpoint.port or
                                (443 if endpoint.scheme == "https" else 80)), timeout=1) as raw:
            if endpoint.scheme == "https":
                with create_default_context().wrap_socket(raw, server_hostname=endpoint.hostname) as stream:
                    return self.run_socket(stream)
            return self.run_socket(raw)

    def run_socket(self, stream):
        wire = WSConnection(ConnectionType.CLIENT)
        endpoint = self.endpoint
        spawn_command = self.request["command"]
        toplevel = spawn_command == "toplevel_spawn"
        deadline = monotonic() + 7
        stream.settimeout(0.1)

        def send(event):
            stream.sendall(wire.send(event))

        def send_json(command):
            send(TextMessage(data=json.dumps(command)))

        if self.cancelled.is_set():
            return "connection_closed"
        send(Request(host=endpoint.netloc, target="/ws"))
        child = None
        stop_deadline = None
        chunks, size = [], 0
        early = []
        reply_targets = set()
        while not self.cancelled.is_set():
            if child is None and monotonic() >= deadline:
                return "spawn_timeout"
            if stop_deadline is not None and monotonic() >= stop_deadline:
                # Closing the connection also retires its actor on the peer.
                return "connection_closed"
            if child is not None:
                for _ in range(32):
                    try:
                        command = self.commands.get_nowait()
                    except Empty:
                        break
                    outgoing = {key: command[key] for key in
                                ("command", "goal", "options", "limit", "message", "reason")
                                if key in command}
                    outgoing["pid"] = child
                    if "browser_from" in command:
                        outgoing["browser_from"] = command["browser_from"]
                        reply_targets.add(command["browser_from"])
                    if toplevel and outgoing.get("reason") == "true":
                        outgoing = {"command": "toplevel_halt", "pid": child}
                    send_json(outgoing)
                    if command["command"] == "exit" and stop_deadline is None:
                        stop_deadline = monotonic() + 2
            try:
                data = stream.recv(4096)
            except SocketTimeout:
                continue
            if not data:
                break
            wire.receive_data(data)
            for event in wire.events():
                if isinstance(event, AcceptConnection):
                    spawn = {"command": spawn_command, "options": self.request["options"]}
                    if toplevel:
                        send_json({"command": "transport_hello", "version": 1, "answer_terms": True})
                    else:
                        spawn["goal"] = self.request["goal"]
                    send_json(spawn)
                elif isinstance(event, Ping):
                    send(event.response())
                elif isinstance(event, CloseConnection):
                    return "connection_closed"
                elif isinstance(event, TextMessage):
                    size += len(event.data.encode("utf-8"))
                    if size > MAX_PEER_MESSAGE:
                        return "invalid_peer_message"
                    chunks.append(event.data)
                    if not event.message_finished:
                        continue
                    reply = json.loads("".join(chunks))
                    chunks, size = [], 0
                    if not isinstance(reply, dict):
                        return "invalid_peer_message"
                    kind = reply.get("type")
                    if toplevel and child is not None and kind in ("success", "failure", "error", "stop", "abort"):
                        if reply.get("pid") == child or (kind == "error" and "pid" not in reply):
                            self.relay_answer(reply)
                        continue
                    if kind == "error":
                        return "peer_rejected"
                    if kind == "actor_message" and child is not None:
                        target, message = reply.get("target"), reply.get("message")
                        if isinstance(target, str) and target in reply_targets and isinstance(message, str):
                            self.emit("message", target=target, data=message)
                    if kind == "spawned" and child is None:
                        child = reply["pid"]
                        if type(child) is not int:
                            return "invalid_peer_pid"
                        self.emit("spawned", child=child)
                        for pending in early:
                            reason = self.relay(child, pending)
                            if reason is not None:
                                return reason
                        early.clear()
                    elif kind in ("output", "down"):
                        if child is None:
                            if len(early) == 32:
                                return "startup_output_limit"
                            early.append(reply)
                        else:
                            reason = self.relay(child, reply)
                            if reason is not None:
                                return reason
        return "connection_closed"

    def relay_answer(self, reply):
        kind = reply["type"]
        if kind == "success":
            data, more = reply.get("term"), reply.get("more")
            if isinstance(data, str) and type(more) is bool:
                self.emit("answer", kind=kind, data=data, more=more)
            else:
                self.emit("answer", kind="error", data="invalid_remote_toplevel_answer")
        elif kind == "error":
            data = reply.get("term", reply.get("data"))
            self.emit("answer", kind=kind, data=data if isinstance(data, str) else "peer_rejected")
        else:
            self.emit("answer", kind=kind)

    def relay(self, child, reply):
        if reply.get("pid") != child:
            return None
        if reply["type"] == "down":
            reason = reply.get("reason")
            return reason if isinstance(reason, str) else "connection_closed"
        if isinstance(reply.get("stdout"), str):
            self.emit("stdout", data=reply["stdout"])
        elif isinstance(reply.get("data"), str):
            self.emit("output", data=reply["data"])
        return None


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
                    if size > MAX_OWNER_MESSAGE:
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
        self.actors = set()
        self.prompts = {}
        self.output = {}
        self.query_waiters = BoundedSemaphore(4)
        self.child_output = Queue(maxsize=64)
        self.closed = Event()
        Thread(target=self.send_child_output, daemon=True).start()

    def enqueue_child_output(self, event):
        message = {"type": event.get("kind", "output"),
                   "pid": event.get("actor_id", event["pid"]),
                   "data": event["data"]}
        if "stdout" in event:
            message["stdout"] = event["stdout"]
        self.enqueue_event(message)

    def enqueue_actor_event(self, event):
        if event["type"] == "down":
            with self.bridge.state_changed:
                self.actors.discard(event["pid"])
        self.enqueue_event(event)

    def enqueue_event(self, event):
        # Keep slow browsers off the bridge reader thread.
        with suppress(Full):
            self.child_output.put_nowait(event)

    def send_child_output(self):
        try:
            while not self.closed.is_set():
                event = self.child_output.get()
                if event is None:
                    return
                self.emit(event)
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
            if request.get("command") in QUERY_COMMANDS:
                if not self.query_waiters.acquire(blocking=False):
                    raise ValueError("Too many pending toplevel queries")
                submitted = Event()
                Thread(target=self.run_query, args=(request, submitted), daemon=True).start()
                # Keep the wire order through submission, while the socket
                # reader stays available for Abort during the query.
                submitted.wait()
            else:
                self.command(request)
        except (KeyError, LookupError, TypeError, ValueError, RuntimeError) as error:
            self.emit_error(request, error)

    def run_query(self, request, submitted):
        try:
            with suppress(OSError, LocalProtocolError):
                try:
                    self.command(request, submitted=submitted)
                except (KeyError, LookupError, TypeError, ValueError, RuntimeError) as error:
                    self.emit_error(request, error)
        finally:
            self.query_waiters.release()
            submitted.set()

    def emit_error(self, request, error):
        reply = {"type": "error", "data": str(error)}
        if isinstance(request, dict):
            reply.update({key: request[key] for key in ("pid", "request_id") if key in request})
        self.emit(reply)

    def command(self, request, *, submitted=None):
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
        if command in ("spawn", "send", "exit"):
            self.actor_command(command, request)
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
                self.relay(self.resume_output(pid, needs_ack, submitted=submitted))
            return
        action = command.removeprefix("toplevel_")
        if action == command or action not in SESSION_COMMANDS:
            raise ValueError("Unsupported ACTOR preview command")
        pid = request["pid"]
        if type(pid) is not int or pid not in self.sessions:
            raise LookupError("Unknown toplevel session for this connection")
        fields = {"pid": pid}
        if action == "call":
            goal = request["goal"]
            if not isinstance(goal, str):
                raise ValueError("Expected a Prolog goal")
            fields.update(goal=goal, browser_options=self.options(request), browser_origin=self.origin)
        elif action == "abort":
            fields["browser_abort"] = True
        elif action == "respond":
            ref = self.prompts.get(pid)
            if ref is None or request.get("prompt_ref") != ref:
                error = {"type": "error", "code": "invalid_prompt_ref", "pid": pid,
                         "data": "Expected the reference from the current prompt"}
                if "request_id" in request:
                    error["request_id"] = request["request_id"]
                self.emit(error)
                return
            value = request["input"]
            if not isinstance(value, str):
                raise ValueError("Expected a Prolog input term")
            fields.update(input=value, prompt_ref=ref)
        reply = self.bridge.request(action, fields, timeout=18 if action in ("call", "next") else 6,
                                    submitted=None if action == "respond" else submitted)
        if reply.get("ws_silent"):
            return
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
            self.relay(self.bridge.request("poll", {"pid": pid}, timeout=18, submitted=submitted))

    @staticmethod
    def options(request):
        options = request.get("options", "[]")
        if not isinstance(options, str):
            raise ValueError("Expected a Prolog option list")
        return options

    def actor_command(self, command, request):
        if command == "spawn":
            goal = request["goal"]
            if not isinstance(goal, str) or not goal.strip():
                raise ValueError("Expected a Prolog goal")
            reply = self.bridge.request("ws_actor_spawn", {"goal": goal, "options": self.options(request)})
            if "request_id" in request:
                reply["request_id"] = request["request_id"]
            if reply["type"] == "spawned":
                pid = reply["pid"]
                with self.bridge.state_changed:
                    self.actors.add(pid)
                    self.bridge.ws_actors[pid] = self.enqueue_actor_event
                self.emit(reply)
                self.bridge.request("ws_actor_start", {"actor": pid})
            else:
                self.emit(reply)
            return
        pid = request["pid"]
        field = "message" if command == "send" else "reason"
        value = request[field] if command == "send" else request.get(field, "kill")
        if not isinstance(value, str):
            raise ValueError(f"Expected a Prolog {field} term")
        with self.bridge.state_changed:
            if command == "send" and pid == "pubsub_service":
                fields = {"owned": list(self.actors), "message": value}
                operation = "ws_actor_pubsub"
            elif type(pid) is int and pid in self.actors:
                fields = {"actor": pid, field: value}
                operation = "ws_actor_" + command
            else:
                raise LookupError("Unknown actor for this connection")
        reply = self.bridge.request(operation, fields)
        if reply["type"] == "error":
            self.emit_error(request, reply["data"])

    def relay(self, event):
        while event["type"] == "output" and not self.io_ack:
            pid = event["pid"]
            needs_ack = event.pop("browser_ack", False)
            self.emit(event)
            event = self.resume_output(pid, needs_ack)
        if event.get("ws_silent"):
            return
        event = dict(event)
        pid = event.get("pid")
        if event["type"] == "prompt":
            self.prompts[pid] = event["prompt_ref"]
        if event["type"] == "output":
            ref = uuid4().hex
            self.output[ref] = (pid, event.pop("browser_ack", False))
            event["data"] = event["data"].removesuffix("\n").removesuffix("\r")
            event = {"type": "io_request", "request_id": ref, "event": event}
        self.emit(event)

    def resume_output(self, pid, needs_ack, *, submitted=None):
        if needs_ack:
            self.bridge.request("browser_ack", {"pid": pid})
        return self.bridge.request("poll", {"pid": pid}, timeout=18, submitted=submitted)

    def close(self):
        self.closed.set()
        with self.bridge.state_changed:
            actors = tuple(self.actors)
            for pid in self.sessions:
                self.bridge.browser_output.pop(pid, None)
        with suppress(Full):
            self.child_output.put_nowait(None)
        for pid in self.sessions:
            with suppress(LookupError, OSError, RuntimeError, ValueError):
                self.bridge.request("halt", {"pid": pid})
        for pid in actors:
            with suppress(LookupError, OSError, RuntimeError, ValueError):
                self.bridge.request("ws_actor_exit", {"actor": pid, "reason": "connection_closed"})
