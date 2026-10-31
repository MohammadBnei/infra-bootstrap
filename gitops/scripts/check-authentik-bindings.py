#!/usr/bin/env python3
"""Fail when an authentik Application has no valid policy binding.

With core_default_app_access=false an unbound application denies everyone; if
that flag ever reverts (a Postgres restore does it silently, see
docs/runbook-authentik-identity.md) the same application admits everyone who
ever enrolled (Wird, mountain). Either way the binding is load-bearing.

A binding counts only if it is enabled, not negated, and its group, user or policy resolves.
`!Find` returns None on a miss instead of failing, and the policy engine skips
the resulting NULL-group row, so a binding that exists is not enough.

  check-authentik-bindings.py [FILE...]   committed blueprints (static parse);
                                          default gitops/bootstrap/authentik-blueprint-*.yaml
  check-authentik-bindings.py --live      the running authentik, read-only, via
                                          `$KUBECTL -n authentik exec ... ak shell`
                                          (KUBECTL defaults to kubectl; e.g. "ssh k9s kubectl")

Static mode treats a `!Find` group/policy as resolved only if a committed
blueprint declares it; a `!Find` user is trusted (users are runtime state).
Apps created outside blueprints (restores, provisioners) only show in --live.

It also fails when the `visitors` group (game visitors, enrolled from GitHub
or Google by anyone) is bound to anything but the `ukubi-world` application:
that group must reach no other app (mountain plan/18, owner decision 1).

ponytail: any resolved policy counts, as a group does. A policy that admits
everyone (e.g. the PKCE guards, outside /authorize) would pass alone; require a
group/user binding here if an app ever relies on a policy-only binding. The
visitors rule reads group bindings only: an expression policy naming the group
would pass unseen.
"""
import glob
import os
import shlex
import subprocess
import sys

APP = "authentik_core.application"
BINDING = "authentik_policies.policybinding"
VISITORS, VISITORS_APP = "visitors", "ukubi-world"


class Tag(tuple):
    """A blueprint YAML tag (!Find, !KeyOf, ...) as (name, value)."""


def load_blueprints(path):
    import yaml

    class Loader(yaml.SafeLoader):
        pass

    def tag(loader, suffix, node):
        if isinstance(node, yaml.SequenceNode):
            return Tag((suffix, loader.construct_sequence(node, deep=True)))
        return Tag((suffix, loader.construct_scalar(node)))

    Loader.add_multi_constructor("!", tag)
    with open(path) as f:
        docs = list(yaml.safe_load_all(f))
    for doc in docs:
        if not doc:
            continue
        # ConfigMap data, or an InfisicalSecret's rendered template.
        data = doc.get("data") or (
            doc.get("spec", {}).get("managedSecretReference", {}).get("template", {}).get("data")
        ) or {}
        for key, body in data.items():
            if key.endswith(".yaml"):
                bp = yaml.load(body, Loader=Loader)
                if isinstance(bp, dict) and "entries" in bp:
                    yield f"{path}:{key}", bp["entries"] or []


def static(paths):
    entries = [(src, e) for p in paths for src, es in load_blueprints(p) for e in es]
    declared = set()  # (model, field, value) any blueprint creates
    apps = {}  # slug -> source
    for src, e in entries:
        ids = {**(e.get("attrs") or {}), **(e.get("identifiers") or {})}
        for field in ("name", "slug"):
            if isinstance(ids.get(field), str):
                declared.add((e.get("model"), field, ids[field]))
        if e.get("model") == APP:
            apps[ids["slug"]] = src

    def local_ids(src):
        return {e["id"]: e for s, e in entries if s == src and "id" in e}

    def resolves(ref, src):
        if not isinstance(ref, Tag):
            return ref is not None
        name, val = ref
        if name == "KeyOf":
            return val in local_ids(src)  # raises at apply time otherwise
        if name == "Find":
            model, (field, value) = val[0], val[1]
            return model == "authentik_core.user" or (model, field, value) in declared
        return False

    def target_slug(ref, src):
        name, val = ref
        if name == "Find" and val[0] == APP:
            return val[1][1]
        if name == "KeyOf":
            e = local_ids(src).get(val, {})
            if e.get("model") == APP:
                return {**e.get("attrs", {}), **e.get("identifiers", {})}.get("slug")
        return None

    def group_name(ref, src):
        if not isinstance(ref, Tag):
            return None
        name, val = ref
        if name == "Find" and val[0] == "authentik_core.group":
            return val[1][1]
        if name == "KeyOf":
            e = local_ids(src).get(val, {})
            return {**e.get("attrs", {}), **e.get("identifiers", {})}.get("name")
        return None

    bound, leaks = set(), {}
    for src, e in entries:
        ids = {**(e.get("attrs") or {}), **(e.get("identifiers") or {})}
        if e.get("model") == BINDING and group_name(ids.get("group"), src) == VISITORS:
            slug = target_slug(ids["target"], src)
            if slug != VISITORS_APP:
                leaks[slug or "a non-application target"] = src
    for src, e in entries:
        attrs = e.get("attrs") or {}
        if e.get("model") != BINDING or attrs.get("enabled") is False or attrs.get("negate") is True:
            continue
        ids = {**(e.get("attrs") or {}), **(e.get("identifiers") or {})}
        slug = target_slug(ids["target"], src)
        if slug and any(resolves(ids.get(k), src) for k in ("group", "user", "policy")):
            bound.add(slug)
    return {slug: src for slug, src in apps.items() if slug not in bound}, len(apps), leaks


LIVE = """
from django.db.models import Q
from authentik.core.models import Application
from authentik.policies.models import PolicyBinding
valid = Q(group__isnull=False) | Q(user__isnull=False) | Q(policy__isnull=False)
for a in Application.objects.order_by("slug"):
    ok = PolicyBinding.objects.filter(valid, target=a, enabled=True, negate=False).exists()
    print("GATE", "ok" if ok else "UNBOUND", a.slug)
for b in PolicyBinding.objects.filter(group__name="%s").exclude(target__application__slug="%s"):
    print("LEAK", getattr(getattr(b.target, "application", None), "slug", None) or b.target_id)
""" % (VISITORS, VISITORS_APP)


def live():
    cmd = shlex.split(os.environ.get("KUBECTL", "kubectl")) + [
        "-n", "authentik", "exec", "-i", "deploy/platform-authentik-worker", "--", "ak", "shell"]
    out = subprocess.run(cmd, input=LIVE, capture_output=True, text=True, check=True).stdout
    rows = [line.split()[1:] for line in out.splitlines() if line.startswith("GATE ")]
    if not rows:
        sys.exit(f"no result from authentik:\n{out}")
    leaks = {line.split()[1]: "live" for line in out.splitlines() if line.startswith("LEAK ")}
    return {slug: "live" for state, slug in rows if state == "UNBOUND"}, len(rows), leaks


def main(argv):
    if argv[:1] == ["--live"]:
        unbound, n, leaks = live()
    else:
        unbound, n, leaks = static(argv or sorted(glob.glob("gitops/bootstrap/authentik-blueprint-*.yaml")))
    for slug, src in sorted(unbound.items()):
        print(f"::error::authentik application '{slug}' has no valid policy binding ({src})")
    for slug, src in sorted(leaks.items()):
        print(f"::error::group '{VISITORS}' is bound to {slug} ({src}); it may reach '{VISITORS_APP}' only")
    if unbound or leaks:
        return 1
    print(f"OK: all {n} authentik applications carry a valid policy binding.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
