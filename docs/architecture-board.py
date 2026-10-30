#!/usr/bin/env python3
"""
OpenShift + GitOps COMPONENT BOARD for demo-aigov-rhaiis-rhsummit-2026.

A block/card "board" (not a node-graph) — far more readable than a spider-web
of edges. Three bands:
  1. OpenShift platform (control plane, ingress, nodes)
  2. OLM operators (gitops/operator/)
  3. Argo CD app-of-apps (gitops/apps/) as cards grouped by sync-wave, left→right
Cards are colour-coded by concern. Emits both .svg (source of truth) and a .png
(for the README) via cairosvg.

Regenerate:
    python3 -m venv /tmp/diagvenv && . /tmp/diagvenv/bin/activate
    pip install cairosvg
    python3 docs/architecture-board.py
"""
import html
import cairosvg

# ---- palette (concern -> accent colour) ----------------------------------
C = {
    "platform": "#334155", "identity": "#7c3aed", "secrets": "#0d9488",
    "networking": "#2563eb", "coder": "#e2500e", "aigpu": "#059669",
    "data": "#d97706", "observability": "#db2777", "operator": "#0f172a",
}
CONCERN_LABEL = {
    "platform": "Platform", "identity": "Identity / SSO", "secrets": "Secrets",
    "networking": "Networking / TLS", "coder": "Coder", "aigpu": "AI / GPU",
    "data": "Data", "observability": "Observability",
}

platform = [
    ("kube-apiserver", "control-plane API", "platform"),
    ("OAuth + Console", "GitHub + Keycloak IdPs", "identity"),
    ("Ingress router", "edge Routes (TLS)", "networking"),
    ("Control/worker ×3", "m6i.4xlarge", "platform"),
    ("GPU node", "g6e.12xlarge · 4× L40S", "aigpu"),
]
operators = [
    ("OpenShift GitOps", "Argo CD · latest", "operator"),
    ("cert-manager", "stable-v1", "operator"),
    ("CloudNativePG", "Postgres", "operator"),
    ("Node Feature Disc.", "NFD", "operator"),
    ("NVIDIA GPU Operator", "stable", "operator"),
    ("RHBK", "Keycloak · stable-v22", "operator"),
    ("External Secrets", "stable-v1", "operator"),
]
# (wave label, [ (app, desc, namespace, concern) ... ])
waves = [
    ("wave -2", [("cluster-config", "OAuth/IdPs · cluster-admin CRB · GroupSync", "openshift-gitops", "identity")]),
    ("wave -1", [("sealed-secrets", "Bitnami SealedSecret controller", "sealed-secrets", "secrets"),
                 ("group-sync-operator", "GitHub team → k8s Group", "group-sync-operator", "identity")]),
    ("wave 0", [("cert-manager", "ClusterIssuers (LE + R53 DNS-01)", "cert-manager", "networking"),
                ("external-secrets", "AWS SM store + ExternalSecrets", "external-secrets", "secrets"),
                ("gpu-stack", "NFD + NVIDIA ClusterPolicy", "nvidia-gpu-operator", "aigpu"),
                ("platform-secrets", "SealedSecrets (platform)", "openshift-gitops", "secrets"),
                ("postgres", "CNPG Cluster (Coder + Keycloak)", "coder", "data")]),
    ("wave 1", [("coder", "Coder 2.37.6 · dual IdP", "coder", "coder"),
                ("coder-workspaces", "namespace + RBAC + pull secret", "coder-workspaces", "coder"),
                ("keycloak", "RHBK · realm demo (3 personas)", "keycloak", "identity")]),
    ("wave 2", [("coder-provisioner", "external provisioner", "coder", "coder"),
                ("coder-routing", "OCP Routes + wildcard cert", "coder", "networking"),
                ("rhaiis", "vLLM Llama 3.3 70B INT4 (GPU)", "ocp-ai", "aigpu")]),
    ("wave 3", [("coder-observability", "Grafana / Prom / Loki / AM", "coder-observability", "observability")]),
    ("wave 5", [("coder-agents-config", "chatd providers + models + roles", "coder", "coder")]),
    ("post-sync", [("bridge", "GitLab issue → workspace", "coder", "coder"),
                   ("gitlab-ingress", "edge Route + external cert", "gitlab-ingress", "networking")]),
]

# ---- layout constants -----------------------------------------------------
W = 1740
MARGIN = 22
COLW, COLGAP = 200, 12
PANEL_PAD = 16

def esc(s):
    return html.escape(str(s))

def wrap(text, maxchars):
    words, lines, cur = text.split(), [], ""
    for w in words:
        if len(cur) + len(w) + (1 if cur else 0) <= maxchars:
            cur = (cur + " " + w) if cur else w
        else:
            lines.append(cur); cur = w
    if cur:
        lines.append(cur)
    return lines[:2]

svg = []
def add(s): svg.append(s)

def rrect(x, y, w, h, rx, fill, stroke="none", sw=1, extra=""):
    add(f'<rect x="{x:.0f}" y="{y:.0f}" width="{w:.0f}" height="{h:.0f}" rx="{rx}" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="{sw}" {extra}/>')

def text(x, y, s, size=12, fill="#0f172a", weight="normal", anchor="start", family="Helvetica, Arial, sans-serif"):
    add(f'<text x="{x:.0f}" y="{y:.0f}" font-family="{family}" font-size="{size}" '
        f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{esc(s)}</text>')

def chip(x, y, w, title, sub, accent, h=46):
    rrect(x, y, w, h, 8, "#ffffff", "#e2e8f0", 1)
    rrect(x, y, 5, h, 8, accent)
    text(x + 12, y + 19, title, 12, "#0f172a", "bold")
    text(x + 12, y + 35, sub, 10, "#64748b")

def card(x, y, w, app, desc, ns, concern):
    accent = C[concern]
    dl = wrap(desc, 30)
    h = 26 + len(dl) * 13 + 20
    rrect(x, y, w, h, 8, "#ffffff", "#e8edf3", 1)
    rrect(x, y, 5, h, 8, accent)
    text(x + 12, y + 18, app, 12.5, "#0f172a", "bold")
    yy = y + 32
    for ln in dl:
        text(x + 12, yy, ln, 9.8, "#51607a"); yy += 13
    # namespace pill
    pill_w = 8 + len(ns) * 5.4
    rrect(x + 12, yy - 1, pill_w, 14, 7, accent + "22", accent + "55", 1)
    text(x + 12 + pill_w / 2, yy + 9, ns, 8.5, accent, "bold", "middle")
    return h

# ---- compute heights ------------------------------------------------------
# precompute wave column heights
def card_h(desc):
    return 26 + len(wrap(desc, 30)) * 13 + 20

col_heights = []
for _, apps in waves:
    hh = 30  # wave header
    for _, desc, _, _ in apps:
        hh += card_h(desc) + 10
    col_heights.append(hh)
panelC_body = max(col_heights) + 10

y = MARGIN
# title
title_h = 34
# band A
bandA_h = PANEL_PAD + 26 + 46 + PANEL_PAD
# band B
bandB_h = PANEL_PAD + 26 + 46 + PANEL_PAD
# panel C
bandC_h = PANEL_PAD + 26 + panelC_body + PANEL_PAD
# legend
legend_h = 44
H = MARGIN + title_h + 12 + bandA_h + 12 + bandB_h + 12 + bandC_h + 12 + legend_h + MARGIN

add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H:.0f}" viewBox="0 0 {W} {H:.0f}">')
rrect(0, 0, W, H, 0, "#f7f8fa")
# title
text(MARGIN, y + 24, "OpenShift Platform + Argo CD App-of-Apps — Component Board", 20, "#0f172a", "bold")
text(W - MARGIN, y + 24, "demo-aigov-rhaiis-rhsummit-2026  ·  gitops/", 11, "#94a3b8", "normal", "end")
y += title_h + 12

# ---- Band A: platform -----------------------------------------------------
rrect(MARGIN, y, W - 2 * MARGIN, bandA_h, 12, "#ffffff", "#dbe2ea", 1.5)
text(MARGIN + PANEL_PAD, y + 22, "OpenShift 4.21 platform  ·  IPI on AWS  ·  STS / IRSA", 13, "#0f172a", "bold")
n = len(platform); cw = (W - 2 * MARGIN - 2 * PANEL_PAD - (n - 1) * 12) / n
for i, (t, s, concern) in enumerate(platform):
    chip(MARGIN + PANEL_PAD + i * (cw + 12), y + 32, cw, t, s, C[concern])
y += bandA_h + 12

# ---- Band B: operators ----------------------------------------------------
rrect(MARGIN, y, W - 2 * MARGIN, bandB_h, 12, "#ffffff", "#dbe2ea", 1.5)
text(MARGIN + PANEL_PAD, y + 22, "OLM operators  ·  gitops/operator/  (installed at bootstrap, before Argo CD apps)", 13, "#0f172a", "bold")
n = len(operators); cw = (W - 2 * MARGIN - 2 * PANEL_PAD - (n - 1) * 12) / n
for i, (t, s, concern) in enumerate(operators):
    chip(MARGIN + PANEL_PAD + i * (cw + 12), y + 32, cw, t, s, C[concern])
y += bandB_h + 12

# ---- Band C: argo app-of-apps by wave ------------------------------------
rrect(MARGIN, y, W - 2 * MARGIN, bandC_h, 12, "#ffffff", "#dbe2ea", 1.5)
text(MARGIN + PANEL_PAD, y + 22, "Argo CD app-of-apps  ·  gitops/apps/  —  applied in sync-wave order", 13, "#0f172a", "bold")
# direction hint (left = earliest wave, right = latest)
text(W - MARGIN - PANEL_PAD, y + 22, "applied earliest (left)  →  latest (right)", 11, "#2563eb", "bold", "end")
cy0 = y + 34
x = MARGIN + PANEL_PAD
for seq, ((wlabel, apps), chh) in enumerate(zip(waves, col_heights), start=1):
    # wave header: left-to-right sequence badge + wave value (clear − minus sign)
    rrect(x, cy0, COLW, 24, 7, "#eef2f7", "#d7dee8", 1)
    add(f'<circle cx="{x + 16:.0f}" cy="{cy0 + 12:.0f}" r="8.5" fill="#334155"/>')
    text(x + 16, cy0 + 15.5, str(seq), 10, "#ffffff", "bold", "middle")
    text(x + 32, cy0 + 16, wlabel.replace("-", "\u2212"), 11.5, "#334155", "bold", "start")
    yy = cy0 + 32
    for app, desc, ns, concern in apps:
        h = card(x, yy, COLW, app, desc, ns, concern)
        yy += h + 10
    x += COLW + COLGAP
y += bandC_h + 12

# ---- legend ---------------------------------------------------------------
rrect(MARGIN, y, W - 2 * MARGIN, legend_h, 10, "#ffffff", "#dbe2ea", 1.5)
text(MARGIN + PANEL_PAD, y + 27, "Legend:", 11, "#0f172a", "bold")
lx = MARGIN + PANEL_PAD + 64
for concern, label in CONCERN_LABEL.items():
    rrect(lx, y + 16, 14, 14, 3, C[concern])
    text(lx + 20, y + 27, label, 10.5, "#334155")
    lx += 40 + len(label) * 6.6

add("</svg>")
svg_doc = "\n".join(svg)

open("docs/images/architecture-board.svg", "w").write(svg_doc)
cairosvg.svg2png(bytestring=svg_doc.encode(), write_to="docs/images/architecture-board.png", scale=2.0)
print(f"wrote docs/images/architecture-board.svg and .png  (canvas {W}x{int(H)})")
