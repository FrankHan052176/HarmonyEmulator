#!/usr/bin/env python3
"""Merges HMOS7QEMU private developer PKI root/signing certs into HarmonyOS 7 appverify trust store."""
import json
import os
import sys

donor, out, root_cer = sys.argv[1], sys.argv[2], sys.argv[3]
O = "C=CN, O=HMOS7QEMU, OU=HMOS7QEMU"
root_pem = open(root_cer).read()
if not root_pem.endswith("\n"):
    root_pem += "\n"

roots = json.load(open(os.path.join(donor, "trusted_root_ca.json")))
roots[f"{O}, CN=HMOS7QEMU Root CA"] = root_pem

sources = json.load(open(os.path.join(donor, "trusted_apps_sources.json")))
names = {s["name"] for s in sources["trust-app-source"]}
if "hmos7qemu dev" not in names:
    sources["trust-app-source"].append({
        "name": "hmos7qemu dev",
        "app-signing-cert": f"{O}, CN=HMOS7QEMU Application Release",
        "profile-signing-certificate": f"{O}, CN=HMOS7QEMU Profile Release",
        "issuer-ca": f"{O}, CN=HMOS7QEMU Signing CA",
        "root-ca": f"{O}, CN=HMOS7QEMU Root CA",
        "max-certs-path": 3,
        "critialcal-cert-extension": [],
    })

os.makedirs(out, exist_ok=True)
json.dump(roots, open(os.path.join(out, "trusted_root_ca.json"), "w"), indent=4, ensure_ascii=False)
json.dump(sources, open(os.path.join(out, "trusted_apps_sources.json"), "w"), indent=4, ensure_ascii=False)
print("trust: %d roots, %d sources" % (len(roots), len(sources["trust-app-source"])))
