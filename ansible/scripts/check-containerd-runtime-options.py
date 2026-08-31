#!/usr/bin/env python3
"""Fails CI if a containerd_additional_runtimes option is a non-string scalar.

kubespray's config.toml.j2 decides whether to quote a rendered option with
`{% if value | string != "true" and value | string != "false" %}`. Jinja renders
a Python bool as "True"/"False" — capital letter — which matches neither
literal, so a YAML boolean takes the quoting branch and emits
`SystemdCgroup = "True"`: a TOML string into a field containerd declares as a Go
bool. The option is then dropped (the runtime silently gets cgroupfs while
kubelet uses systemd) or containerd rejects the config outright and does not
start. kubespray's own default sidesteps this with ternary('true', 'false').

Nothing else catches it: the YAML is valid, ansible-lint is happy, and the
damage only appears during a cluster.yml run. See ADR-0043.
"""
import glob
import sys

import yaml

failures = []

for path in sorted(glob.glob("inventory/*/host_vars/*.yml") + glob.glob("inventory/*/group_vars/**/*.yml", recursive=True)):
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    if not isinstance(doc, dict):
        continue
    for runtime in doc.get("containerd_additional_runtimes") or []:
        for key, value in (runtime.get("options") or {}).items():
            if not isinstance(value, str):
                failures.append(
                    f"{path}: runtime '{runtime.get('name')}' option {key}: "
                    f"{value!r} is a {type(value).__name__}, must be a quoted string "
                    f'(use "{str(value).lower()}")'
                )

if failures:
    print("::error::containerd runtime options must be quoted strings — see ADR-0043.")
    print("\n".join(failures))
    sys.exit(1)

print("OK: all containerd_additional_runtimes options are strings.")
