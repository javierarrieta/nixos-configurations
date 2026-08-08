import hashlib
import json
import os
import re
import secrets
import threading


WORKSPACE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
MIN_SIZE_GB = 10
MAX_SIZE_GB = 200


def validate_workspace(value):
    if not isinstance(value, str) or not WORKSPACE_RE.fullmatch(value):
        raise ValueError("workspace must match ^[a-z0-9][a-z0-9-]{0,62}$")
    return value


def validate_size_gb(value):
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError("size_gb must be an integer")
    if not MIN_SIZE_GB <= value <= MAX_SIZE_GB:
        raise ValueError(f"size_gb must be between {MIN_SIZE_GB} and {MAX_SIZE_GB}")
    return value


class CapabilityStore:
    """Process-local capability store; the service persists its hashes atomically."""

    def __init__(self):
        self._lock = threading.RLock()
        self._active = None

    def acquire(self, workspace):
        validate_workspace(workspace)
        with self._lock:
            if self._active is not None:
                if self._active["workspace"] != workspace:
                    raise RuntimeError("another workspace is active")
                raise RuntimeError("workspace capability is required to reacquire")
            capability = secrets.token_urlsafe(32)
            self._active = {
                "workspace": workspace,
                "hash": self._hash(capability),
            }
            return capability

    def authorize(self, workspace, capability):
        if not isinstance(capability, str) or not capability:
            return False
        with self._lock:
            return bool(
                self._active
                and self._active["workspace"] == workspace
                and secrets.compare_digest(self._active["hash"], self._hash(capability))
            )

    def release(self, workspace, capability):
        if not self.authorize(workspace, capability):
            raise PermissionError("invalid workspace capability")
        with self._lock:
            self._active = None

    def serialized_state(self):
        with self._lock:
            return json.dumps(self._active or {}, sort_keys=True)

    @staticmethod
    def _hash(capability):
        return hashlib.sha256(capability.encode("utf-8")).hexdigest()


def run_server():
    raise RuntimeError(
        "iSCSI backend is not configured; complete the TrueNAS adapter before enabling this service"
    )


if __name__ == "__main__":
    run_server()
