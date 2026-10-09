#!/usr/bin/env python3
"""Inject operator-local ACR pull credentials without printing their contents."""
import json
import os
import re
import shlex
import stat
import sys
from pathlib import Path


def registry_in_file(path, required=False):
    if not path.is_file():
        if required:
            raise ValueError("Variable file is missing")
        return None
    if path.name.endswith(".json"):
        contents = json.loads(path.read_text())
        if not isinstance(contents, dict):
            raise ValueError("Variable JSON must be an object")
        registry = contents.get("tokenvolt_acr_registry")
        if registry is not None and not isinstance(registry, str):
            raise ValueError("tokenvolt_acr_registry must be a string")
        return registry
    contents = path.read_text()
    matches = re.findall(r'^[ \t]*tokenvolt_acr_registry[ \t]*=[ \t]*"([^"\n]*)"[ \t]*(?:(?:#|//).*)?$',
                         contents, re.MULTILINE)
    if len(matches) > 1:
        raise ValueError("Multiple tokenvolt_acr_registry values in the variable file")
    if not matches and re.search(r'^\s*tokenvolt_acr_registry\s*=', contents, re.MULTILINE):
        raise ValueError("tokenvolt_acr_registry must be one literal string")
    return matches[0] if matches else None


def effective_registry(env, cwd, command_args=()):
    cwd = Path(cwd)
    registry = env.get("TF_VAR_tokenvolt_acr_registry")
    for path in (cwd / "terraform.tfvars", cwd / "terraform.tfvars.json",
                 *sorted((*cwd.glob("*.auto.tfvars"), *cwd.glob("*.auto.tfvars.json")))):
        value = registry_in_file(path)
        if value is not None:
            registry = value
    command = next((arg for arg in command_args if not arg.startswith("-")), "")
    options = [*shlex.split(env.get("TF_CLI_ARGS", "")),
               *shlex.split(env.get("TF_CLI_ARGS_" + command, "")), *command_args]
    for index, option in enumerate(options):
        if option in ("-var", "-var-file"):
            if index + 1 >= len(options):
                raise ValueError("Variable option needs a value")
            value = options[index + 1]
        elif option.startswith("-var=") or option.startswith("-var-file="):
            value = option.split("=", 1)[1]
        else:
            continue
        if option.startswith("-var-file"):
            path = Path(value)
            candidate = registry_in_file(path if path.is_absolute() else cwd / path, required=True)
            if candidate is not None:
                registry = candidate
        elif value.startswith("tokenvolt_acr_registry="):
            registry = value.split("=", 1)[1]
    return registry


def credential_environment(env, cwd, command_args=()):
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
    registry = effective_registry(env, cwd, command_args)
    if not registry or credentials["registry"] != registry:
        raise ValueError("Credential registry does not match the deployment registry")
    env["TF_VAR_tokenvolt_acr_username"] = credentials["username"]
    env["TF_VAR_tokenvolt_acr_password"] = credentials["password"]
    return env


def main():
    if len(sys.argv) < 2:
        raise ValueError("usage: with-acr-credentials.py COMMAND [ARG ...]")
    env = credential_environment(os.environ, Path.cwd(), sys.argv[2:])
    os.execvpe(sys.argv[1], sys.argv[1:], env)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, UnicodeError):
        sys.exit("ACR credential loading failed; check private file ownership, mode, JSON fields and registry, or provide both process variables")
