#!/usr/bin/env python3
"""
AWS architecture diagram for demo-aigov-rhaiis-rhsummit-2026.

Renders docs/images/architecture-aws.png using the `diagrams` library
(mingrammer/diagrams) — the same engine behind the AWS Diagram MCP Server
(awslabs.aws-diagram-mcp-server) — so AWS components use the official AWS
architecture icon set.

Regenerate:
    python3 -m venv /tmp/diagvenv && . /tmp/diagvenv/bin/activate
    pip install diagrams            # needs system graphviz (`dot`)
    python3 docs/architecture-diagram.py
"""
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.network import (
    Route53, ElbNetworkLoadBalancer, InternetGateway, NATGateway,
    VPC, PublicSubnet, PrivateSubnet,
)
from diagrams.aws.compute import EC2
from diagrams.aws.ml import Bedrock
from diagrams.aws.security import (
    SecretsManager, IdentityAndAccessManagementIamRole as IAMRole,
    Guardduty, Inspector,
)
from diagrams.aws.management import SystemsManager
from diagrams.aws.general import Users
from diagrams.k8s.compute import Deploy, Pod
from diagrams.onprem.gitops import Argocd
from diagrams.onprem.vcs import Gitlab
from diagrams.onprem.container import Docker
from diagrams.onprem.ci import GithubActions

graph_attr = {
    "fontsize": "22",
    "labelloc": "t",
    "bgcolor": "white",
    "pad": "0.6",
    "nodesep": "0.55",
    "ranksep": "0.85",
    "splines": "spline",
}
node_attr = {"fontsize": "12"}
edge_irsa = {"color": "darkgreen", "style": "dashed", "fontcolor": "darkgreen"}

with Diagram(
    "RH Summit 2026 — Coder + Red Hat AI-Governance Demo (AWS 342934376218 / us-east-1)",
    filename="docs/images/architecture-aws",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    node_attr=node_attr,
):
    users = Users("Booth users\n+ in-cluster webhooks")

    with Cluster("GitHub (SaaS)"):
        gha = GithubActions("GH Actions\nbuild-images / bridge /\npush-templates → ghcr.io")

    with Cluster("AWS Cloud — account 342934376218 · us-east-1"):
        dns = Route53("Route 53\n*.rhsummit.coderdemo.io")

        with Cluster("Shared IAM / STS"):
            oidc = IAMRole("IRSA roles\n(STS OIDC provider)")

        # AWS managed services consumed via IRSA / instance profile
        with Cluster("AWS managed services"):
            bedrock = Bedrock("Bedrock\n(Claude Sonnet/Opus)")
            sm = SecretsManager("Secrets Manager\nrhsummit/keycloak/demo-realm")
            with Cluster("Account security posture"):
                gd = Guardduty("GuardDuty")
                insp = Inspector("Inspector")
                ssm = SystemsManager("SSM\n(Session Mgr / Patch)")

        with Cluster("VPC 10.0.0.0/16"):
            with Cluster("Public subnets"):
                igw = InternetGateway("Internet Gateway")
                nat = NATGateway("NAT Gateway")
                nlb = ElbNetworkLoadBalancer("Router NLB\n(OpenShift edge)")

            with Cluster("Private subnets (multi-AZ)"):

                with Cluster("OpenShift 4.21 cluster (IPI, STS)"):
                    nodes = [
                        EC2("control/worker ×3\nm6i.4xlarge"),
                        EC2("GPU node\ng6e.12xlarge · 4× L40S"),
                    ]

                    with Cluster("Platform / GitOps"):
                        argo = Argocd("Argo CD\napp-of-apps")
                        eso = Pod("External Secrets\nOperator")
                        certm = Pod("cert-manager")
                        keycloak = Deploy("Keycloak (RHBK)\nrealm: demo")

                    with Cluster("Coder platform"):
                        coder = Deploy("Coder 2.37.6")
                        gateway = Pod("AI Gateway\n/api/v2/aibridge")
                        bridge = Pod("issue→workspace\nbridge")
                        ws = Pod("workspaces\n(agents)")

                    with Cluster("Sovereign LLM (GPU)"):
                        rhaiis = Pod("RHAIIS vLLM\nLlama 3.3 70B INT4")

                    with Cluster("Data / Observability"):
                        cnpg = Pod("CNPG Postgres\n(Coder + Keycloak)")
                        graf = Pod("Grafana / Prom / Loki")

                with Cluster("GitLab CE (EC2 m7a.2xlarge · 10.0.20.10)"):
                    gitlab = Gitlab("GitLab + Omnibus")
                    registry = Docker("container registry")

        # ---- edges ----
        users >> Edge(label="HTTPS") >> dns >> nlb
        nlb >> Edge(label="edge Routes") >> [coder, keycloak]
        nlb >> Edge(label="edge Route") >> gitlab
        nat >> igw

        # IRSA / instance-profile access to AWS services (dashed green)
        gateway >> Edge(label="IRSA", **edge_irsa) >> bedrock
        eso >> Edge(label="IRSA", **edge_irsa) >> sm
        certm >> Edge(label="DNS-01 IRSA", **edge_irsa) >> dns
        gitlab >> Edge(label="instance profile", **edge_irsa) >> sm
        gitlab >> Edge(style="dotted", color="gray") >> ssm
        oidc >> Edge(style="dotted", color="darkgreen") >> [bedrock, sm]

        # in-cluster LLM + app flows
        gateway >> Edge(label="sovereign") >> rhaiis
        coder >> gateway
        coder >> ws
        bridge >> Edge(label="spawns") >> ws
        gitlab >> Edge(label="webhook") >> bridge
        [coder, keycloak, cnpg] >> Edge(style="invis")  # layout hint
        keycloak >> Edge(label="OIDC", style="dashed", color="purple") >> coder
        keycloak >> Edge(label="OIDC", style="dashed", color="purple") >> gitlab
        coder >> Edge(color="gray") >> cnpg
        keycloak >> Edge(color="gray") >> cnpg
        gitlab >> registry

    # supply chain
    gha >> Edge(label="images", style="dotted") >> argo
