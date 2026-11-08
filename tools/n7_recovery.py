#!/usr/bin/env python3
"""Capture and verify a private recovery bundle for the deployed N7 pilot."""
import argparse
from difflib import SequenceMatcher
from hashlib import sha256
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LABEL = "se.elfenbenstornet.trinity-n7-adapter"
ORIGIN = "https://n7.elfenbenstornet.se"
N3 = "https://n3.elfenbenstornet.se"
ASSETS = (
    "n7-catalog-v1/shared/web/demonstrator.html",
    "n7-catalog-v1/shared/web/vendor/trinity-host.js",
    "n7-catalog-v1/n6/web/demonstrator.html",
    "n7-catalog-v1/n6/web/vendor/trinity-host.js",
    "n7-discovery-v1/discovery-hub.html",
)
SOURCES = (
    "Deployment/compose.eclipse-n7-https.yaml",
    "Deployment/compose.eclipse-n7-recovery.yaml",
    "examples/APIs/http_example-1.html",
    "experiments/eclipse-clp/isotope_http.py",
    "experiments/eclipse-clp/n7_pilot.html",
    "tools/n7_recovery.py",
)


def docker(*args):
    return subprocess.check_output(["docker", *args])


def digest(path):
    h = sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def check_rollback(base, deployed):
    changes = SequenceMatcher(None, base.splitlines(), deployed.splitlines(), autojunk=False)
    insertions = []
    for operation, _, _, start, end in changes.get_opcodes():
        if operation == "equal":
            continue
        if operation != "insert":
            raise ValueError("Rollback input differs from the edge outside N7 insertions")
        insertions.append("\n".join(deployed.splitlines()[start:end]))
    if (len(insertions) != 8 or sum("@n7_catalog {" in item for item in insertions) != 7
            or sum("@n7_discovery_asset {" in item for item in insertions) != 1
            or insertions[-1].strip() != "import /etc/caddy/n7.Caddyfile"):
        raise ValueError("Expected seven N7 catalog additions, one Hub asset and the N7 site import")


def verify_site(edge, oauth, args, template, main, base):
    token = Path(args[args.index("--proxy-token-file") + 1]).read_text().strip()
    environment = json.loads(docker("inspect", "--format", "{{json .Config.Env}}", oauth))
    login = next(line.split("=", 1)[1] for line in environment
                 if line.startswith("OAUTH2_PROXY_GITHUB_USERS="))
    values = {"N7_ORIGIN": ORIGIN, "N7_TLS_DIRECTIVE": "", "N7_GITHUB_LOGIN": login,
              "N7_OWNER_EMAIL": args[args.index("--owner") + 1], "N7_PROXY_TOKEN": token}
    rendered = re.sub(r"\{\$([A-Z0-9_]+)(?::([^}]*))?\}",
                      lambda match: values.get(match[1], match[2]), template)
    live = docker("exec", edge, "cat", "/etc/caddy/n7.Caddyfile").decode()

    def directives(text):
        return [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]

    if not token or token.encode() in main or token.encode() in base or directives(rendered) != directives(live):
        raise ValueError("The templated N7 site differs from the live site or credentials are inline")


def capture(output, edge, oauth, base_path, launch_agent, image):
    args = plistlib.loads(launch_agent.read_bytes())["ProgramArguments"]
    if (args[args.index("--private-origin") + 1] != ORIGIN
            or args[args.index("--pilot-image") + 1] != image
            or args.count("--allow-peer") != 1
            or args[args.index("--allow-peer") + 1] != N3
            or any(x.startswith("--allow-peer=") for x in args)):
        raise ValueError("Expected the live N7 image, origin and N3-only allowlist")
    release_id = docker("image", "inspect", "--format", "{{.Id}}", image).decode().strip()
    engines = [name for name in docker("ps", "--format", "{{.Names}}").decode().splitlines()
               if re.fullmatch(r"trinity-n7-[0-9a-f]+", name)]
    if len(engines) != 1 or docker("inspect", "--format", "{{.Image}}", engines[0]).decode().strip() != release_id:
        raise ValueError("The running N7 engine differs from the release image")
    release_tag = "trinity-eclipse-n7:recovery-" + release_id.split(":")[1][:16]
    edge_image = docker("inspect", "--format", "{{.Config.Image}}", edge).decode().strip()
    edge_image_id = docker("inspect", "--format", "{{.Image}}", edge).decode().strip()
    deployed = docker("exec", edge, "cat", "/etc/caddy/Caddyfile")
    baked_base = docker("run", "--rm", "--network", "none", "--entrypoint", "cat",
                        edge_image_id, "/etc/caddy/Caddyfile")
    base = base_path.read_bytes() if base_path else baked_base
    check_rollback(base.decode(), deployed.decode())
    template = (ROOT / "Deployment/Caddyfile.eclipse-n7").read_text()
    verify_site(edge, oauth, args, template, deployed, base)
    output.mkdir(mode=0o700)
    try:
        (output / "Caddyfile").write_bytes(deployed)
        (output / "Caddyfile.rollback").write_bytes(base)
        (output / "n7.Caddyfile").write_text(template)
        for relative in SOURCES:
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        for relative in ASSETS:
            target = output / "assets" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(docker("exec", edge, "cat", "/config/" + relative))
        # Use a separate tag so loading the archive cannot retag the live image.
        docker("tag", image, release_tag)
        docker("image", "save", "--output", str(output / "engine.tar"), release_tag)
        files = {str(path.relative_to(output)): digest(path)
                 for path in sorted(output.rglob("*")) if path.is_file()}
        manifest = {"image": release_tag, "image_id": release_id, "edge_image": edge_image,
                    "edge_image_id": edge_image_id, "rollback_matches_edge_image": base == baked_base,
                    "origin": ORIGIN, "allowed_peers": [N3], "files": files}
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    except BaseException:
        shutil.rmtree(output)
        raise
    print(f"Captured {len(files)} files in {output}")


def verify(bundle):
    manifest = json.loads((bundle / "manifest.json").read_text())
    actual = {str(path.relative_to(bundle)): digest(path)
              for path in bundle.rglob("*") if path.is_file() and path != bundle / "manifest.json"}
    if actual != manifest["files"] or manifest["origin"] != ORIGIN or manifest["allowed_peers"] != [N3]:
        raise ValueError("Recovery bundle failed integrity verification")
    return manifest


def load_image(bundle, manifest):
    docker("image", "load", "--input", str(bundle / "engine.tar"))
    identity = docker("image", "inspect", "--format", "{{.Id}}", manifest["image"]).decode().strip()
    if identity != manifest["image_id"]:
        raise ValueError("Loaded engine differs from the recorded image")
    return manifest["image"]


def adapter_command(bundle, manifest, port, owner, token_file, *, origin=None, peers=None):
    argv = [sys.executable, str(bundle / "experiments/eclipse-clp/isotope_http.py"),
            "--pilot-image", manifest["image"], "--port", str(port),
            "--private-origin", origin or manifest["origin"], "--owner", owner,
            "--proxy-token-file", str(token_file)]
    for peer in manifest["allowed_peers"] if peers is None else peers:
        argv.extend(["--allow-peer", peer])
    return argv


def launch_plist(bundle, manifest, args):
    config = {
        "Label": LABEL, "ProgramArguments": adapter_command(bundle, manifest, args.port, args.owner, args.token_file),
        "WorkingDirectory": str(bundle), "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 5,
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
        "StandardOutPath": str(args.log), "StandardErrorPath": str(args.log),
    }
    with open(args.output, "xb", opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
        plistlib.dump(config, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    stage = sub.add_parser("capture")
    stage.add_argument("--output", type=Path, required=True)
    stage.add_argument("--rollback-caddyfile", type=Path)
    stage.add_argument("--edge", default="deployment-caddy-1")
    stage.add_argument("--oauth", default="trinity-n7-https-oauth2_n7-1")
    stage.add_argument("--image", default="trinity-eclipse-n7:local")
    stage.add_argument("--launch-agent", type=Path,
                       default=Path.home() / "Library/LaunchAgents" / (LABEL + ".plist"))
    for action in ("verify", "load", "launch-plist"):
        command = sub.add_parser(action)
        command.add_argument("bundle", type=Path)
        if action == "launch-plist":
            command.add_argument("--output", type=Path, required=True)
            command.add_argument("--owner", required=True)
            command.add_argument("--token-file", type=lambda v: Path(v).resolve(), required=True)
            command.add_argument("--log", type=lambda v: Path(v).resolve(), required=True)
            command.add_argument("--port", type=int, default=18087)
    args = parser.parse_args()
    if args.action == "capture":
        capture(args.output, args.edge, args.oauth, args.rollback_caddyfile, args.launch_agent, args.image)
        return
    bundle = args.bundle.resolve()
    manifest = verify(bundle)
    if args.action == "load":
        print(load_image(bundle, manifest))
    elif args.action == "launch-plist":
        launch_plist(bundle, manifest, args)
    else:
        print(f"Verified {len(manifest['files'])} recovery files")


if __name__ == "__main__":
    main()
