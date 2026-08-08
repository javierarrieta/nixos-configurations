#!/usr/bin/env python3
"""Root-owned iSCSI + TrueNAS lifecycle helper for Coder workspaces on llm01.

Listens on https://0.0.0.0:2377 with mandatory client-certificate verification
and services authenticated lifecycle requests from the Coder provisioner. The
helper owns privileged operations (iscsiadm, mkfs, mount, podman unshare) and
the TrueNAS API credential; the Coder provisioner never receives host-level
mount privileges or the TrueNAS API key.

Security model:
- mTLS identifies the Coder provisioner (the only permitted caller).
- A per-workspace opaque capability, issued by acquire and required by every
  lifecycle call, authorizes state-changing operations. Only a SHA-256 hash is
  stored; comparisons are constant-time and the capability is never logged.
- All subprocesses receive validated argument vectors, never shell strings.
- Workspace identifiers match ^[a-z0-9][a-z0-9-]{0,62}$; sizes are 10-200 GiB.
"""

import hashlib
import json
import os
import re
import secrets
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WORKSPACE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
MIN_SIZE_GB = 10
MAX_SIZE_GB = 200
LEASE_FILENAME = "lease.json"
LOCK_FILENAME = "lock"


class Config:
    """Runtime configuration sourced from the environment (set by systemd)."""

    def __init__(self):
        self.listen = os.environ.get("CODER_HELPER_LISTEN", "0.0.0.0:2377")
        self.truenas_url = os.environ.get(
            "CODER_HELPER_TRUENAS_URL", "https://192.168.0.6"
        )
        self.truenas_api_key_file = os.environ.get(
            "CODER_HELPER_TRUENAS_API_KEY_FILE", "/run/secrets/coder/truenas-api-key"
        )
        self.tls_cert = os.environ.get(
            "CODER_HELPER_TLS_CERT", "/run/secrets/podman/server.crt"
        )
        self.tls_key = os.environ.get(
            "CODER_HELPER_TLS_KEY", "/run/secrets/podman/server.key"
        )
        self.client_ca = os.environ.get(
            "CODER_HELPER_CLIENT_CA", "/run/secrets/podman/client-ca.crt"
        )
        self.state_dir = os.environ.get(
            "CODER_HELPER_STATE_DIR", "/var/lib/coder-iscsi-helper"
        )
        self.workspace_base = os.environ.get(
            "CODER_HELPER_WORKSPACE_BASE", "/srv/coder/workspaces"
        )
        self.dataset_parent = os.environ.get(
            "CODER_HELPER_DATASET_PARENT", "tank/iscsi/k8s"
        )
        self.iqn_basename = os.environ.get(
            "CODER_HELPER_IQN_BASENAME", "iqn.2005-10.org.freenas.ctl"
        )
        self.target_portal = os.environ.get(
            "CODER_HELPER_TARGET_PORTAL", "192.168.0.6:3260"
        )
        self.portal_group = int(os.environ.get("CODER_HELPER_PORTAL_GROUP", "1"))
        self.initiator_group = int(
            os.environ.get("CODER_HELPER_INITIATOR_GROUP", "1")
        )
        self.coder_user = os.environ.get("CODER_HELPER_CODER_USER", "coder")
        self.podman_bin = os.environ.get("CODER_HELPER_PODMAN_BIN", "podman")
        self.container_uid = int(os.environ.get("CODER_HELPER_CONTAINER_UID", "1000"))
        self.container_gid = int(os.environ.get("CODER_HELPER_CONTAINER_GID", "1000"))

    @property
    def truenas_api_key(self):
        with open(self.truenas_api_key_file, "r", encoding="utf-8") as fh:
            return fh.read().strip()

    @property
    def lease_path(self):
        return os.path.join(self.state_dir, LEASE_FILENAME)

    @property
    def lock_path(self):
        return os.path.join(self.state_dir, LOCK_FILENAME)


def validate_workspace(value):
    if not isinstance(value, str) or not WORKSPACE_RE.fullmatch(value):
        raise ValueError("workspace must match ^[a-z0-9][a-z0-9-]{0,62}$")
    return value


def validate_size_gb(value):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("size_gb must be an integer")
    if not MIN_SIZE_GB <= value <= MAX_SIZE_GB:
        raise ValueError(f"size_gb must be between {MIN_SIZE_GB} and {MAX_SIZE_GB}")
    return value


class CapabilityStore:
    """Durable, atomic, root-owned lease store persisting only capability hashes."""

    def __init__(self, config):
        self._config = config
        self._lock = threading.RLock()
        self._state = None

    def _load(self):
        if self._state is not None:
            return self._state
        path = self._config.lease_path
        try:
            with open(path, "r", encoding="utf-8") as fh:
                self._state = json.load(fh) or {}
        except FileNotFoundError:
            self._state = {}
        return self._state

    def _persist(self):
        path = self._config.lease_path
        os.makedirs(self._config.state_dir, exist_ok=True)
        tmp = path + f".tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self._state, fh, sort_keys=True)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)

    def acquire(self, workspace, capability=None):
        """Claim the global lease for `workspace`.

        Returns a fresh capability, or, when the same workspace already holds the
        lease, verifies the presented capability and returns it unchanged
        (idempotent reacquire). Raises RuntimeError on a conflicting lease.
        """
        validate_workspace(workspace)
        with self._lock:
            state = self._load()
            holder = state.get("workspace")
            if holder is not None:
                if holder != workspace:
                    raise RuntimeError(f"another workspace ({holder}) is active")
                if not self._authorize(workspace, capability):
                    raise RuntimeError(
                        "workspace capability is required to reacquire"
                    )
                return capability
            capability = capability or secrets.token_urlsafe(32)
            self._state = {
                "workspace": workspace,
                "hash": self._hash(capability),
            }
            self._persist()
            return capability

    def authorize(self, workspace, capability):
        with self._lock:
            return self._authorize(workspace, capability)

    def _authorize(self, workspace, capability):
        if not isinstance(capability, str) or not capability:
            return False
        state = self._load()
        if not state or state.get("workspace") != workspace:
            return False
        return secrets.compare_digest(state.get("hash", ""), self._hash(capability))

    def release(self, workspace, capability):
        """Release the lease for `workspace`; idempotent when already released."""
        validate_workspace(workspace)
        with self._lock:
            state = self._load()
            if not state:
                return
            if state.get("workspace") != workspace:
                raise PermissionError("invalid workspace capability")
            if not self._authorize(workspace, capability):
                raise PermissionError("invalid workspace capability")
            self._state = {}
            self._persist()

    def clear_stale(self, running_workspaces):
        """Clear a lease whose holder has no running Coder container.

        Fails closed: if the caller cannot determine the running set, the lease
        is left intact. `running_workspaces` must be an iterable of workspace
        names that have a running container.
        """
        with self._lock:
            state = self._load()
            if not state:
                return
            holder = state.get("workspace")
            if holder is not None and holder not in set(running_workspaces):
                self._state = {}
                self._persist()

    def serialized_state(self):
        with self._lock:
            return json.dumps(self._load(), sort_keys=True)

    @staticmethod
    def _hash(capability):
        return hashlib.sha256(capability.encode("utf-8")).hexdigest()


class TrueNASClient:
    """Minimal TrueNAS API v2.0 client for zvol/target/extent management."""

    def __init__(self, config):
        self._config = config

    def _request(self, method, path, payload=None):
        url = self._config.truenas_url + path
        body = json.dumps(payload).encode("utf-8") if payload is not None else None
        headers = {
            "Authorization": f"Bearer {self._config.truenas_api_key}",
            "Content-Type": "application/json",
        }
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
                raw = resp.read()
                if not raw:
                    return None
                return json.loads(raw)
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            detail = raw.decode("utf-8", "replace")
            raise RuntimeError(f"TrueNAS {method} {path} -> {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"TrueNAS {method} {path} unreachable: {exc}") from exc

    def dataset(self, name):
        # TrueNAS identifies datasets by their full path (parent/name).
        full = f"{self._config.dataset_parent}/{name}"
        enc = urllib.request.quote(full, safe="")
        return self._request("GET", f"/api/v2.0/pool/dataset?id={enc}")

    def create_zvol(self, name, size_gb):
        parent = self._config.dataset_parent
        full = f"{parent}/{name}"
        payload = {
            "name": full,
            "type": "VOLUME",
            "volsize": size_gb * 1024 * 1024 * 1024,
            "sparse": False,
        }
        return self._request("POST", "/api/v2.0/pool/dataset", payload)

    def delete_zvol(self, name):
        full = f"{self._config.dataset_parent}/{name}"
        enc = urllib.request.quote(full, safe="")
        return self._request("DELETE", f"/api/v2.0/pool/dataset/id/{enc}")

    def targets(self, name=None):
        q = f"?name={urllib.request.quote(name, safe='')}" if name else ""
        return self._request("GET", f"/api/v2.0/iscsi/target{q}")

    def create_target(self, name):
        payload = {
            "name": name,
            "groups": [
                {
                    "portal": self._config.portal_group,
                    "initiator": self._config.initiator_group,
                    "authmethod": "NONE",
                    "auth": None,
                }
            ],
        }
        return self._request("POST", "/api/v2.0/iscsi/target", payload)

    def delete_target(self, target_id):
        return self._request("DELETE", f"/api/v2.0/iscsi/target/id/{target_id}")

    def extents(self, name=None):
        q = f"?name={urllib.request.quote(name, safe='')}" if name else ""
        return self._request("GET", f"/api/v2.0/iscsi/extent{q}")

    def create_extent(self, name):
        disk = f"zvol/{self._config.dataset_parent}/{name}"
        payload = {
            "name": name,
            "type": "DISK",
            "disk": disk,
            "blocksize": 512,
            "insecure_tpc": True,
            "xen": False,
            "rpm": "SSD",
            "ro": False,
            "enabled": True,
        }
        return self._request("POST", "/api/v2.0/iscsi/extent", payload)

    def delete_extent(self, extent_id):
        return self._request("DELETE", f"/api/v2.0/iscsi/extent/id/{extent_id}")

    def target_extents(self, target_id):
        return self._request(
            "GET", f"/api/v2.0/iscsi/targetextent?target={target_id}"
        )

    def create_target_extent(self, target_id, extent_id, lunid=0):
        payload = {"target": target_id, "extent": extent_id, "lunid": lunid}
        return self._request("POST", "/api/v2.0/iscsi/targetextent", payload)

    def delete_target_extent(self, association_id):
        return self._request(
            "DELETE", f"/api/v2.0/iscsi/targetextent/id/{association_id}"
        )


class ISCSIActions:
    """Privileged iSCSI/filesystem actions, all via argument vectors."""

    def __init__(self, config):
        self._config = config

    def _run(self, argv, timeout=120, check=True):
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        if check and proc.returncode != 0:
            raise RuntimeError(
                f"{' '.join(argv[:3])}... failed ({proc.returncode}): "
                f"{proc.stderr.strip() or proc.stdout.strip()}"
            )
        return proc

    def discovery(self):
        self._run(
            [
                "iscsiadm",
                "-m",
                "discovery",
                "-t",
                "sendtargets",
                "-p",
                self._config.target_portal,
            ]
        )

    def login(self, iqn):
        proc = self._run(
            ["iscsiadm", "-m", "node", "-T", iqn, "-p", self._config.target_portal, "--login"],
            check=False,
        )
        if proc.returncode != 0 and "already exists" not in proc.stdout + proc.stderr:
            raise RuntimeError(
                f"iscsiadm login failed ({proc.returncode}): {proc.stderr.strip()}"
            )

    def logout(self, iqn):
        proc = self._run(
            ["iscsiadm", "-m", "node", "-T", iqn, "-p", self._config.target_portal, "--logout"],
            check=False,
        )
        if proc.returncode != 0 and "No matching sessions" not in proc.stdout + proc.stderr:
            raise RuntimeError(
                f"iscsiadm logout failed ({proc.returncode}): {proc.stderr.strip()}"
            )

    def device_path(self, iqn, wait=30):
        by_path = (
            f"/dev/disk/by-path/ip-{self._config.target_portal}-iscsi-{iqn}-lun-0"
        )
        deadline = time.time() + wait
        while time.time() < deadline:
            if os.path.exists(by_path):
                return os.path.realpath(by_path)
            time.sleep(1)
        raise RuntimeError(f"iSCSI device for {iqn} did not appear")

    def filesystem_type(self, device):
        proc = self._run(["blkid", "-o", "value", "-s", "TYPE", device], check=False)
        if proc.returncode != 0:
            return None
        return proc.stdout.strip() or None

    def format_ext4(self, device, label):
        self._run(["mkfs.ext4", "-F", "-L", label, device], timeout=300)

    def mount(self, device, mountpoint):
        os.makedirs(mountpoint, exist_ok=True)
        self._run(["mount", device, mountpoint])

    def unmount(self, mountpoint):
        proc = self._run(["umount", mountpoint], check=False)
        if proc.returncode != 0 and "not mounted" not in proc.stderr:
            raise RuntimeError(f"umount {mountpoint} failed: {proc.stderr.strip()}")

    def is_mounted(self, mountpoint):
        proc = self._run(["mountpoint", "-q", mountpoint], check=False)
        return proc.returncode == 0

    def _run_as_coder(self, argv, timeout=120):
        """Run argv as the coder user from a coder-accessible working dir."""
        full = [
            "setpriv",
            "--reuid",
            self._config.coder_user,
            "--regid",
            self._config.coder_user,
            "--clear-groups",
            "--init-groups",
            "env",
            f"HOME=/home/{self._config.coder_user}",
            *argv,
        ]
        cwd = f"/home/{self._config.coder_user}"
        proc = subprocess.run(
            full,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            cwd=cwd,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"{' '.join(argv[:3])}... failed ({proc.returncode}): "
                f"{proc.stderr.strip() or proc.stdout.strip()}"
            )
        return proc

    def chown_in_namespace(self, mountpoint):
        """chown 1000:1000 inside the coder user's rootless namespace.

        Runs as the `coder` user so /etc/subuid and /etc/subgid map the
        container uid/gid to the correct subordinate host ids. Never assumes
        container uid 1000 equals host uid 1000.
        """
        self._run_as_coder(
            [
                self._config.podman_bin,
                "unshare",
                "chown",
                f"{self._config.container_uid}:{self._config.container_gid}",
                mountpoint,
            ],
            timeout=300,
        )

    def running_coder_workspaces(self):
        """List workspace names with a running Coder-owned container."""
        proc = subprocess.run(
            [
                "setpriv",
                "--reuid",
                self._config.coder_user,
                "--regid",
                self._config.coder_user,
                "--clear-groups",
                "--init-groups",
                "env",
                f"HOME=/home/{self._config.coder_user}",
                self._config.podman_bin,
                "ps",
                "--filter",
                "name=coder-",
                "--format",
                "{{.Names}}",
            ],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
            cwd=f"/home/{self._config.coder_user}",
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"podman ps (as coder) failed ({proc.returncode}): {proc.stderr.strip()}"
            )
        names = []
        for line in proc.stdout.splitlines():
            name = line.strip()
            if name.startswith("coder-"):
                names.append(name[len("coder-") :])
        return names


class WorkspaceManager:
    """End-to-end lifecycle operations over TrueNAS + iSCSI."""

    def __init__(self, config):
        self._config = config
        self._truenas = TrueNASClient(config)
        self._iscsi = ISCSIActions(config)
        self._op_lock = threading.RLock()

    # The workspace name is bound per-request; use a bound context.
    def bind(self, workspace):
        return _BoundWorkspace(self._config, self._truenas, self._iscsi, self._op_lock, workspace)


class _BoundWorkspace:
    def __init__(self, config, truenas, iscsi, op_lock, workspace):
        self._config = config
        self._truenas = truenas
        self._iscsi = iscsi
        self._op_lock = op_lock
        self.workspace = validate_workspace(workspace)

    @property
    def iqn(self):
        return f"{self._config.iqn_basename}:{self.workspace}"

    @property
    def target_name(self):
        return self.workspace

    @property
    def mountpoint(self):
        return os.path.join(self._config.workspace_base, f"coder-{self.workspace}")

    @property
    def fs_label(self):
        # ext4 labels are limited to 16 chars; prefix keeps them identifiable.
        safe = self.workspace.replace("-", "_")[:9]
        return f"coder_{safe}"

    def provision(self, size_gb):
        validate_size_gb(size_gb)
        with self._op_lock:
            self._reconcile_truenas(size_gb)
            self._iscsi.discovery()
            self._iscsi.login(self.iqn)
            device = self._iscsi.device_path(self.iqn)
            fstype = self._iscsi.filesystem_type(device)
            if fstype is None:
                self._iscsi.format_ext4(device, self.fs_label)
            elif fstype != "ext4":
                raise RuntimeError(
                    f"refusing to mount unknown filesystem {fstype} on {device}"
                )
            if not self._iscsi.is_mounted(self.mountpoint):
                self._iscsi.mount(device, self.mountpoint)
            self._iscsi.chown_in_namespace(self.mountpoint)
            return {"device": device, "mountpoint": self.mountpoint}

    def attach(self):
        with self._op_lock:
            self._iscsi.discovery()
            self._iscsi.login(self.iqn)
            device = self._iscsi.device_path(self.iqn)
            fstype = self._iscsi.filesystem_type(device)
            if fstype is not None and fstype != "ext4":
                raise RuntimeError(
                    f"refusing to mount unknown filesystem {fstype} on {device}"
                )
            if not self._iscsi.is_mounted(self.mountpoint):
                self._iscsi.mount(device, self.mountpoint)
            self._iscsi.chown_in_namespace(self.mountpoint)
            return {"device": device, "mountpoint": self.mountpoint}

    def detach(self):
        with self._op_lock:
            if self._iscsi.is_mounted(self.mountpoint):
                self._iscsi.unmount(self.mountpoint)
            self._iscsi.logout(self.iqn)
            return {"ok": True}

    def destroy(self):
        with self._op_lock:
            self.detach()
            targets = self._truenas.targets(self.target_name)
            for target in targets:
                t_id = target["id"]
                for assoc in self._truenas.target_extents(t_id):
                    self._truenas.delete_target_extent(assoc["id"])
            for extent in self._truenas.extents(self.target_name):
                self._truenas.delete_extent(extent["id"])
            for target in targets:
                self._truenas.delete_target(target["id"])
            existing = self._truenas.dataset(self.workspace)
            if existing:
                self._truenas.delete_zvol(self.workspace)
            return {"ok": True}

    def _reconcile_truenas(self, size_gb):
        existing = self._truenas.dataset(self.workspace)
        if not existing:
            self._truenas.create_zvol(self.workspace, size_gb)
        targets = self._truenas.targets(self.target_name)
        if not targets:
            self._truenas.create_target(self.target_name)
            targets = self._truenas.targets(self.target_name)
        if not targets:
            raise RuntimeError("target creation did not produce a target")
        target_id = targets[0]["id"]
        extents = self._truenas.extents(self.target_name)
        if not extents:
            self._truenas.create_extent(self.target_name)
            extents = self._truenas.extents(self.target_name)
        if not extents:
            raise RuntimeError("extent creation did not produce an extent")
        extent_id = extents[0]["id"]
        associations = self._truenas.target_extents(target_id)
        if not any(a["extent"] == extent_id for a in associations):
            self._truenas.create_target_extent(target_id, extent_id)


class LeaseLock:
    """Inter-process mutual exclusion for lease serialization."""

    def __init__(self, config):
        self._config = config

    def __enter__(self):
        self._fd = os.open(
            self._config.lock_path, os.O_RDWR | os.O_CREAT, 0o600
        )
        while True:
            try:
                os.lockf(self._fd, os.F_LOCK, 0)
                return self
            except BlockingIOError:
                time.sleep(0.1)

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            os.lockf(self._fd, os.F_UNLCK, 0)
        finally:
            os.close(self._fd)


def make_ssl_context(config):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=config.tls_cert, keyfile=config.tls_key)
    ctx.load_verify_locations(cafile=config.client_ca)
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


class HelperHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # Never log capability values or request bodies.
        super().log_message(fmt, *args)

    @property
    def manager(self):
        return self.server.manager

    @property
    def capability_store(self):
        return self.server.capability_store

    @property
    def config(self):
        return self.server.config

    def _capability(self):
        return self.headers.get("X-Coder-Capability", "")

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, message):
        self._json(code, {"ok": False, "error": message})

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            raise ValueError("request body must be JSON")

    def _dispatch(self, method, path, body):
        parts = [p for p in path.split("/") if p]
        if len(parts) < 2 or parts[0] != "v1":
            self._error(404, "unknown path")
            return
        kind = parts[1]
        if kind == "lease" and len(parts) == 4:
            workspace = parts[2]
            action = parts[3]
            try:
                workspace = validate_workspace(workspace)
            except ValueError as exc:
                self._error(400, str(exc))
                return
            if method == "POST" and action == "acquire":
                self._acquire(workspace)
                return
            if method == "POST" and action == "release":
                self._release(workspace)
                return
            self._error(404, "unknown lease action")
            return
        if kind == "workspaces" and len(parts) in (3, 4):
            workspace = parts[2]
            action = parts[3] if len(parts) == 4 else None
            try:
                workspace = validate_workspace(workspace)
            except ValueError as exc:
                self._error(400, str(exc))
                return
            if not self.capability_store.authorize(workspace, self._capability()):
                self._error(403, "missing or invalid workspace capability")
                return
            bound = self.manager.bind(workspace)
            try:
                if method == "POST" and action == "provision":
                    size_gb = validate_size_gb(body.get("size_gb"))
                    result = bound.provision(size_gb)
                    self._json(200, {"ok": True, **result})
                    return
                if method == "POST" and action == "attach":
                    result = bound.attach()
                    self._json(200, {"ok": True, **result})
                    return
                if method == "POST" and action == "detach":
                    result = bound.detach()
                    self._json(200, {"ok": True, **result})
                    return
                if method == "DELETE" and action is None:
                    result = bound.destroy()
                    self.capability_store.release(workspace, self._capability())
                    self._json(200, {"ok": True, **result})
                    return
            except (ValueError, RuntimeError) as exc:
                self._error(500, str(exc))
                return
            self._error(404, "unknown workspace action")
            return
        self._error(404, "unknown path")

    def _acquire(self, workspace):
        try:
            capability = self.capability_store.acquire(
                workspace, self._capability() or None
            )
        except RuntimeError as exc:
            self._error(409, str(exc))
            return
        self._json(200, {"ok": True, "capability": capability})

    def _release(self, workspace):
        try:
            self.capability_store.release(workspace, self._capability())
        except PermissionError as exc:
            self._error(403, str(exc))
            return
        self._json(200, {"ok": True})

    def do_POST(self):
        try:
            body = self._read_body()
        except ValueError as exc:
            self._error(400, str(exc))
            return
        self._dispatch("POST", self.path, body)

    def do_DELETE(self):
        self._dispatch("DELETE", self.path, {})


def reconcile_stale_leases(config, store):
    """Clear leases whose holder has no running container; fail closed."""
    iscsi = ISCSIActions(config)
    try:
        running = iscsi.running_coder_workspaces()
    except RuntimeError:
        return
    store.clear_stale(running)


def run_server():
    config = Config()
    os.makedirs(config.state_dir, exist_ok=True)
    store = CapabilityStore(config)
    manager = WorkspaceManager(config)
    reconcile_stale_leases(config, store)

    ctx = make_ssl_context(config)
    handler = type(
        "Handler",
        (HelperHandler,),
        {},
    )
    server = ThreadingHTTPServer(("0.0.0.0", int(config.listen.rsplit(":", 1)[1])), handler)
    server.config = config
    server.capability_store = store
    server.manager = manager
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    print(
        f"coder-iscsi-helper listening on {config.listen} (mTLS required)",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    run_server()
