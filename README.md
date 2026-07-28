# The Briefing

> A fully automated DevOps pipeline that takes a React application from a `git push` to a live, monitored deployment on Kubernetes — without a single manual step.

---

## Overview

The goal was to build a complete CI/CD platform around a simple React application, treating the infrastructure as the actual deliverable. Every stage — code quality, security scanning, packaging, deployment, and observability — is automated, reproducible, and declared as code. The pipeline enforces hard quality and security gates before any artifact reaches the cluster, with monitoring active from the first deployment.

The application is a minimal tech news reader built on the public Hacker News API. It is intentionally simple — the complexity lives in the infrastructure around it.

## Architecture

![Architecture Diagram](docs/architecture.png)

The deploy path runs left to right: a `git push` triggers Jenkins via webhook → Jenkins runs quality and security gates in sequence → a Docker image is built and pushed to Docker Hub → Kubernetes pulls that image and deploys it on Amazon EKS behind a LoadBalancer service. Prometheus scrapes the cluster continuously; Grafana visualises the metrics; Blackbox Exporter probes the public endpoint every 60 seconds.

**Key decisions behind the diagram:**

- **EKS over a self-managed cluster** — managed control plane eliminates etcd maintenance and node certificate rotation, at the cost of ~$70/month for the cluster endpoint.
- **Jenkins over GitHub Actions** — chosen to demonstrate self-hosted CI administration: plugin management, agent configuration, credential scoping — skills that don't appear in a hosted-runner setup.
- **Two replicas minimum** — a single pod means a rolling update causes brief downtime. Two replicas allow zero-downtime deploys with the default `RollingUpdate` strategy.
- **Terraform for infrastructure as code** — the EKS cluster and monitoring server are provisioned via Terraform, keeping infrastructure reproducible and version-controlled alongside the application.

## Design decisions

| Decision | Chosen | Rejected | Reason |
|---|---|---|---|
| Container orchestration | Amazon EKS | ECS, Nomad | Kubernetes is the industry standard; EKS removes control-plane overhead |
| CI runner | Jenkins (self-hosted) | GitHub Actions | Demonstrates agent config, plugin management, credential scoping |
| Image registry | Docker Hub | ECR, GHCR | Public visibility for portfolio; ECR would be preferable in production |
| IaC tool | Terraform | CloudFormation, CDK | Declarative HCL, wide ecosystem support, version-controlled infrastructure |
| SAST | SonarQube + Quality Gate | ESLint only | Quality Gate creates a hard pipeline failure, not just a warning |
| Secret storage | Jenkins Credentials Store | `.env` in repo | Credentials never touch the source tree |

## System properties

- **Availability target:** no formal SLA. Two replicas + `RollingUpdate` prevent deploy-time downtime.
- **Scaling:** fixed at 2 replicas. HPA not configured — traffic is negligible at this scale.
- **Recovery:** no formal RTO/RPO. Pod crashes are handled automatically by the ReplicaSet controller. Node failure triggers EKS rescheduling.
- **Cost (approximate):** EKS cluster ~$70/month, EC2 worker nodes ~$30–60/month, monitoring EC2 ~$10–15/month. Total: ~$110–145/month if left running continuously.

## Security posture

**Secrets management**
Jenkins Credentials Store holds Docker Hub credentials and the kubeconfig. Nothing sensitive is in the repository. No `.env` file, no hardcoded tokens.

**Scan coverage**

| Scanner | What it checks | Where in pipeline |
|---|---|---|
| SonarQube | Code smells, duplications, security hotspots | Stage 4 — blocks on Quality Gate failure |
| OWASP Dependency Check | Known CVEs in npm dependencies | Stage 7 — blocks on critical finding |
| Trivy (filesystem) | Vulnerabilities in source + lockfile | Stage 8 — runs after OWASP |
| Trivy (image) | Vulnerabilities in the built Docker image | Stage 10 — after build, before deploy |

**IAM / least privilege**
EKS node role uses the minimum AWS-managed policies required (`AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`). No admin roles attached to nodes.

**Known gaps**
- No Kubernetes network policies — all pods can communicate within the cluster
- No pod security standards enforced
- Docker Hub image is public
- No TLS on the LoadBalancer endpoint (HTTP only)
- Terraform state is local, not remote (no S3 + DynamoDB locking)

## Pipeline

![Pipeline Stage View](docs/jenkins-pipeline.png)

| Stage | Tool | Duration (avg) | Fails the build if... |
|---|---|---|---|
| Tool Install | Jenkins | 163ms | Plugin or binary missing |
| Clean workspace | Jenkins | 287ms | Disk full |
| Checkout from Git | Git | 4s | Repository unreachable |
| SonarQube Analysis | SonarQube | 19s | Analysis errors |
| Quality Gate | SonarQube | 357ms | Gate status is not `OK` |
| Install Dependencies | npm | 15s | `npm install` fails |
| OWASP FS Scan | OWASP Dependency Check | 3min 4s | Critical CVE in dependencies |
| Trivy FS Scan | Trivy | 3s | High/critical vulnerability in source |
| Docker Build & Push | Docker | 2min 30s | Build error or auth failure |
| Trivy Image Scan | Trivy | 20s | High/critical vuln in image |

Total pipeline duration: ~6 min 44s. OWASP and Docker Build account for ~85% of that time.

On success, Jenkins emails a build report with the Trivy scan output (`trivyfs.txt`, `trivyimage.txt`) attached.

![Build success](docs/jenkins-build-success.png)

## Observability

![SonarQube Quality Gate](docs/sonarqube-quality-gate.png)

**What is monitored**

| Signal | Tool | Why this metric |
|---|---|---|
| Pod CPU and memory | Prometheus + node-exporter | Primary indicator of resource pressure before OOM kill |
| HTTP endpoint availability | Blackbox Exporter | Detects service-level failure that pod health alone misses |
| HTTP response time | Blackbox Exporter | Catches degraded performance before it becomes an outage |
| Code quality gate | SonarQube | Enforces 0 new bugs, 0 new vulnerabilities on every push |
| Pipeline result | Jenkins Email Extension | Immediate feedback loop on every push |

**SonarQube results on latest analysis**

| Metric | Result |
|---|---|
| Quality Gate | Passed — all conditions met |
| New Bugs | 0 |
| New Vulnerabilities | 0 |
| New Security Hotspots | 0 |
| New Code Smells | 0 |
| Added Technical Debt | 0 |

**Alerting philosophy**
The Jenkins email notification on build failure is the only active alert. A production setup would add Alertmanager rules on probe failure (public URL stops responding for >2 consecutive checks).

## Incidents

### Container running as root

SonarQube flagged the Dockerfile — `node:alpine` runs as root by default, and I hadn't added a `USER` directive. It showed up as a security hotspot, not a build blocker, but still worth fixing.

The risk: if a dependency gets exploited, the attacker lands inside the container as root. Added a dedicated non-root user and transferred ownership of the app directory before switching:

```dockerfile
RUN addgroup -S appgroup && adduser -S appuser -G appgroup \
    && chown -R appuser:appgroup /app
USER appuser
```

Verified — container now runs as `appuser`.

---

### Terraform EC2 — public IP left to subnet default

SonarQube caught that the EC2 resource block in `Terraform/main.tf` didn't explicitly set `associate_public_ip_address`. Depending on the subnet configuration, the instance could end up with a public IP without it being intentional.

In practice it was behind a security group with restricted inbound ports, so not exposed — but relying on subnet defaults in infrastructure code is sloppy. Fixed by setting `associate_public_ip_address = false` explicitly in the resource block.

---

## Trade-offs and known limitations

- **Docker Hub instead of ECR.** Fine for portfolio visibility; a production setup uses a private registry with image signing.
- **Jenkins on a single EC2 instance.** No HA for the CI server itself.

## Local development

```bash
git clone https://github.com/wiamelyakini/the-briefing.git
cd the-briefing
npm install
npm start
# Opens at http://localhost:3000
```

No API key required — uses the public [Hacker News Firebase API](https://github.com/HackerNews/API).

```bash
# Docker
docker build -t the-briefing .
docker run -p 3000:3000 the-briefing
```

## Repo structure

```
Jenkinsfile              # Main CI/CD pipeline (build → scan → push → deploy)
Dockerfile               # React production build (non-root user, explicit COPY)
K8S/
  manifest.yml           # Production deployment (2–6 replicas) + LoadBalancer service
  staging.yml            # Staging deployment (1 replica, namespace: staging)
  hpa.yml                # HorizontalPodAutoscaler (min 2, max 6, 60% CPU threshold)
Terraform/
  jenkinsfile            # Infrastructure provisioning pipeline
  main.tf                # EKS cluster + EC2 instance for Prometheus + Grafana
scripts/                 # Tool installation scripts (Trivy, kubectl, etc.)
```

## Roadmap

- [x] **Non-root user in Dockerfile** — fixed, verified with `docker run whoami`
- [x] **Explicit public IP control in Terraform** — closed the EC2 exposure hotspot
- [x] **HPA** — deployed, auto-scaled from 2 to 6 replicas under load
- [x] **Staging environment** — staging namespace with manual promotion gate before production
- [ ] **Private image registry (ECR)** — remove the public Docker Hub dependency
- [ ] **Alertmanager rules** — turn Blackbox probe failures into real alerts, not just dashboard signals

## Author

Wiame EL YAKINI — [GitHub](https://github.com/wiamelyakini) · [LinkedIn](https://www.linkedin.com/in/wiame-el-yakini/)