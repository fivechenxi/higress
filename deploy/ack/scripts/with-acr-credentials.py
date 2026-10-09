#!/usr/bin/env python3
"""Inject operator-local ACR pull credentials without printing their contents."""
import json
import os
import re
import stat
import sys
from pathlib import Path


def credential_environment(env, cwd):
    env = dict(env)
    username = env.get("TF_VAR_tokenvolt_acr_username", "")
    password = env.get("TF_VAR_tokenvolt_acr_password", "")
    if bool(username) != bool(password):
        raise ValueError("Provide both ACR process variables together")
    if username:
        return env
    path = env.get("TOKENVOLT_ACR_CREDENTIAL_FILE", "")
    if not path:
        raise ValueError("Set TOKENVOLT_ACR_CREDENTIAL_FILE or both ACR process variables")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError("ACR credential file must be private and owned by the current user (chmod 600)")
        try:
            credentials = json.load(source)
        except (ValueError, UnicodeError):
            raise ValueError("Invalid ACR credential JSON") from None
    if not isinstance(credentials, dict) or any(
        not isinstance(credentials.get(key), str) or not credentials[key].strip()
        for key in ("registry", "username", "password")
    ):
        raise ValueError("ACR credential JSON requires nonempty registry, username and password strings")
    registry = env.get("TF_VAR_tokenvolt_acr_registry")
    if registry is None:
        matches = re.findall(r'^tokenvolt_acr_registry\s*=\s*"([^"\n]*)"\s*(?:#.*)?$',
                             (Path(cwd) / "terraform.tfvars").read_text(), re.MULTILINE)
        if len(matches) != 1:
            raise ValueError("Require one explicit tokenvolt_acr_registry in OSS-synchronized tfvars")
        registry = matches[0]
    if not registry or credentials["registry"] != registry:
        raise ValueError("Credential registry does not match the deployment registry")
    env["TF_VAR_tokenvolt_acr_username"] = credentials["username"]
    env["TF_VAR_tokenvolt_acr_password"] = credentials["password"]
    return env


def main():
    if len(sys.argv) < 2:
        raise ValueError("usage: with-acr-credentials.py COMMAND [ARG ...]")
    env = credential_environment(os.environ, Path.cwd())
    os.execvpe(sys.argv[1], sys.argv[1:], env)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError):
        sys.exit("ACR credential loading failed; check private file ownership, mode, JSON fields and registry, or provide both process variables")
