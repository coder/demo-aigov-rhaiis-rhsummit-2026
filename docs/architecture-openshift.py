#!/usr/bin/env python3
"""
OpenShift platform + GitOps (Argo CD app-of-apps) component diagram for
demo-aigov-rhaiis-rhsummit-2026.

Companion to architecture-diagram.py (the AWS infrastructure view). This view
shows the OpenShift platform (control plane, ingress, nodes), the OLM operators
(gitops/operator/), and every Argo CD Application (gitops/apps/) grouped by
sync-wave — including Coder and its satellites.

Rendered with the `diagrams` library (engine behind the AWS Diagram MCP Server).
Regenerate:
    python3 -m venv /tmp/diagvenv && . /tmp/diagvenv/bin/activate
    pip install diagrams            # needs system graphviz (`dot`)
    python3 docs/architecture-openshift.py
"""
from diagrams import Diagram, Cluster, Edge
from diagrams.onprem.gitops import Argocd
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.database import Postgresql
from diagrams.onprem.network import Nginx
from diagrams.k8s.infra import Master, Node
from diagrams.k8s.others import CRD
from diagrams.k8s.compute import Deploy, Pod, Job
from diagrams.k8s.group import NS
from diagrams.k8s.rbac import ClusterRole, Group
from diagrams.k8s.podconfig import Secret
from diagrams.k8s.network import Ingress

graph_attr = {
    "fontsize": "22", "labelloc": "t", "bgcolor": "white",
    "pad": "0.6", "nodesep": "0.45", "ranksep": "0.9", "splines": "spline",
}
node_attr = {"fontsize": "11"}
dep = {"style": "dotted", "color": "gray40", "fontcolor": "gray40"}       # app → operator it needs
flow = {"color": "#2563eb", "fontcolor": "#2563eb", "penwidth": "2"}      # sync-wave ordering

with Diagram(
    "OpenShift Platform + Argo CD App-of-Apps — Operators & Applications (gitops/)",
    filename="docs/images/architecture-openshift",
    outformat="png", show=False, direction="LR",
    graph_attr=graph_attr, node_attr=node_attr,
):
    with Cluster("OpenShift 4.21 (IPI on AWS · STS / IRSA)"):

        with Cluster("Control plane & platform"):
            api = Master("kube-apiserver")
            oauth = ClusterRole("OAuth + Console\n(GitHub + Keycloak IdPs)")
            router = Nginx("Ingress router\n(edge Routes)")
            n1 = Node("control/worker ×3\nm6i.4xlarge")
            n2 = Node("GPU node\ng6e.12xlarge · L40S")

        with Cluster("OLM operators (gitops/operator/)"):
            op_gitops = Argocd("OpenShift GitOps\n(Argo CD)")
            op_cm = CRD("cert-manager")
            op_cnpg = Postgresql("CloudNativePG")
            op_nfd = CRD("Node Feature\nDiscovery")
            op_gpu = CRD("NVIDIA GPU\nOperator")
            op_rhbk = CRD("RHBK\n(Keycloak)")
            op_eso = CRD("External Secrets\nOperator")

        with Cluster("Argo CD — app-of-apps (gitops/apps/), by sync-wave"):
            root = Argocd("root\nApplication")

            with Cluster("wave -2"):
                a_cfg = ClusterRole("cluster-config\nOAuth/IdPs · admin CRB")
            with Cluster("wave -1"):
                a_sealed = Secret("sealed-secrets")
                a_gsync = Group("group-sync-operator")
            with Cluster("wave 0"):
                a_cm = CRD("cert-manager\nClusterIssuers")
                a_eso = Secret("external-secrets\nstore + ExternalSecrets")
                a_gpu = Pod("gpu-stack\nNFD + NVIDIA ClusterPolicy")
                a_psec = Secret("platform-secrets")
                a_pg = Postgresql("postgres\nCNPG Cluster")
            with Cluster("wave 1"):
                a_coder = Deploy("coder 2.37.6")
                a_cws = NS("coder-workspaces")
                a_kc = Deploy("keycloak (RHBK)\nrealm: demo")
            with Cluster("wave 2"):
                a_prov = Deploy("coder-provisioner")
                a_route = Ingress("coder-routing\nRoutes + cert")
                a_rhaiis = Pod("rhaiis\nvLLM Llama 70B (GPU)")
            with Cluster("wave 3"):
                a_obs = Grafana("coder-observability\nGrafana / Prom / Loki")
            with Cluster("wave 5"):
                a_agents = Job("coder-agents-config\nchatd providers + models")
            with Cluster("post-sync (hooks / unwaved)"):
                a_bridge = Deploy("bridge\nGitLab issue → workspace")
                a_glingress = Ingress("gitlab-ingress\nedge Route + ext cert")

    # GitOps operator serves Argo CD; Argo root drives the app-of-apps
    op_gitops >> Edge(color="#2563eb") >> root

    # sync-wave ordering (one representative per wave)
    root >> Edge(label="wave -2", **flow) >> a_cfg
    a_cfg >> Edge(label="-1", **flow) >> a_sealed
    a_sealed >> Edge(label="0", **flow) >> a_cm
    a_cm >> Edge(label="1", **flow) >> a_coder
    a_coder >> Edge(label="2", **flow) >> a_prov
    a_prov >> Edge(label="3", **flow) >> a_obs
    a_obs >> Edge(label="5", **flow) >> a_agents

    # app → operator CRDs it depends on
    a_cm >> Edge(label="uses", **dep) >> op_cm
    a_eso >> Edge(**dep) >> op_eso
    a_pg >> Edge(**dep) >> op_cnpg
    a_kc >> Edge(**dep) >> op_rhbk
    a_gpu >> Edge(**dep) >> op_nfd
    a_gpu >> Edge(**dep) >> op_gpu
    a_rhaiis >> Edge(label="schedules on", **dep) >> n2

    # a few app relationships that complete the picture
    a_coder >> Edge(**dep) >> a_pg
    a_kc >> Edge(**dep) >> a_pg
    a_coder >> Edge(**dep) >> a_route
    a_bridge >> Edge(**dep) >> a_coder
    router >> Edge(**dep) >> [a_route, a_glingress]
