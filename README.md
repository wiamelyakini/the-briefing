# The Briefing

> A fully automated DevOps pipeline that takes a React application from a `git push` to a live, monitored deployment on Kubernetes — without a single manual step.

---

## Overview

The goal was to build a complete CI/CD platform around a simple React application, treating the infrastructure as the actual deliverable. The interesting constraint: every stage — code quality, security, packaging, deployment, and observability — had to be fully automated, reproducible, and documented as code. The result is a pipeline that enforces quality gates and security scans before any artifact reaches the cluster, with monitoring in place from day one.

The app itself ([The Briefing](https://github.com/wiamelyakini/the-briefing)) is a tech news reader built on the public Hacker News API. It is intentionally simple — the complexity lives in the infrastructure around it.

## Architecture

![Architecture Diagram](docs/architecture.png)

The deploy path runs left to right: a `git push` triggers Jenkins via webhook → Jenkins runs quality and security gates in sequence → a Docker image is built and pushed to Docker Hub → Kubernetes pulls that image and deploys it on Amazon EKS behind a LoadBalancer service. Prometheus scrapes the cluster continuously; Grafana visualises the metrics; Blackbox Exporter probes the public endpoint every 60 seconds.

**Key decisions behind the diagram:**

- **EKS over a self-managed cluster** — managed control plane eliminates etcd maintenance and node certificate rotation at the cost of roughly $70/month for the cluster endpoint. Acceptable for a portfolio project; reconsidered at scale.
- **Jenkins over GitHub Actions** — chosen to demonstrate self-hosted CI administration (plugin management, agent configuration, credential scoping), skills that don't appear in a hosted-runner setup.
- **Two replicas minimum** — a single pod means a rolling update causes brief downtime. Two replicas allow zero-downtime deploys with the default `RollingUpdate` strategy.
- **Terraform for the monitoring server only** — the EKS cluster itself is provisioned manually to keep the scope of this project focused on the pipeline, not cloud account management. Noted as a gap below.

## Design decisions

| Decision | Chosen | Rejected | Reason |
|---|---|---|---|
| Container orchestration | Amazon EKS | ECS, Nomad | Kubernetes is the industry standard; EKS removes control-plane overhead |
| CI runner | Jenkins (self-hosted) | GitHub Actions | Demonstrates agent config, plugin ecosystem, credential management |
| Image registry | Docker Hub | ECR, GHCR | Public visibility for portfolio; ECR would be preferable in production |
| IaC scope | Terraform (monitoring server) | Full Terraform for EKS | Kept scope focused on pipeline skills, not cloud provisioning |
| SAST | SonarQube + Quality Gate | ESLint only | Quality Gate creates a hard pipeline failure, not just a warning |
| Secret storage | Jenkins Credentials Store | `.env` in repo | Credentials never touch the source tree |

## System properties

- **Availability target:** no formal SLA (not production-critical). Two replicas + `RollingUpdate` prevent deploy-time downtime.
- **Scaling:** fixed at 2 replicas. HPA not configured — traffic is negligible, and adding it would require a metrics-server installation on the cluster.
- **Recovery:** no formal RTO/RPO. If a pod crashes, the ReplicaSet controller restarts it automatically (self-healing). If the node fails, EKS reschedules pods on available nodes.
- **Cost (approximate):** EKS cluster ~$70/month, EC2 worker nodes ~$30-60/month depending on instance type, monitoring EC2 instance ~$10-15/month. Total: ~$110-145/month if left running. In practice, torn down between sessions.

## Security posture

**Secrets management**
Jenkins Credentials Store holds Docker Hub credentials and the kubeconfig. Nothing is in the repository. No `.env` file, no hardcoded tokens.

**Scan coverage**

| Scanner | What it checks | Where in pipeline |
|---|---|---|
| SonarQube | Code smells, duplications, coverage, security hotspots | Stage 2 — blocks on Quality Gate failure |
| OWASP Dependency Check | Known CVEs in npm dependencies | Stage 3 — blocks on critical finding |
| Trivy (filesystem) | Vulnerabilities in source + lockfile | Stage 3 — runs alongside OWASP |
| Trivy (image) | Vulnerabilities in the built Docker image | Stage 4 — after build, before push |

**IAM / least privilege**
The EKS node role has the minimum AWS-managed policies required (`AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`). No admin roles attached to nodes.

**Known gaps**
- No network policies between pods (all pods can talk to each other within the cluster)
- No pod security standards enforced (no `PodSecurityAdmission` configuration)
- Docker Hub is public — the image is readable by anyone
- No TLS on the LoadBalancer endpoint (HTTP only)
- Terraform state is local, not remote (S3 + DynamoDB locking not configured)

## Pipeline

| Stage | Tool | Fails the build if... |
|---|---|---|
| Checkout | Jenkins / Git | Repository unreachable |
| Code quality | SonarQube | Quality Gate status is not `OK` |
| Dependency scan | OWASP Dependency Check | Critical CVE found in npm dependencies |
| Filesystem scan | Trivy | High or critical vulnerability in source |
| Docker build | Docker | Build error (missing dep, syntax error in Dockerfile) |
| Image scan | Trivy | High or critical vulnerability in the built image |
| Push | Docker Hub | Auth failure or network error |
| Deploy | Jenkins → `kubectl apply` | `kubectl` returns non-zero exit code |
| Notify | Jenkins Email Extension | Always runs — sends success or failure |

Stages run sequentially. A failure at any gate stops the pipeline immediately; the image is never pushed if a scan fails.

## Observability

**What is monitored**

| Signal | Tool | Why this metric |
|---|---|---|
| Pod CPU and memory | Prometheus + node-exporter | Primary indicator of resource pressure before OOM kill |
| HTTP endpoint availability | Blackbox Exporter | Detects service-level failure that pod health alone misses |
| HTTP response time | Blackbox Exporter | Catches degraded performance before it becomes an outage |
| Pipeline build result | Jenkins + Email | Immediate feedback loop on every push |

Grafana is configured with dashboards covering pod resource usage and endpoint probe results. There are no PagerDuty-style alerts — this is a portfolio project, so dashboards are a visual signal only.

**Alerting philosophy**
Nothing pages anyone. The email notification from Jenkins on build failure is the only active alert. A production setup would add Alertmanager rules on probe failure (i.e., the public URL stops responding).

## Incidents / what broke

### Hook typo broke React's rules of hooks

**Symptom:** `npm start` threw an ESLint error — `React Hook useState is called in function usStory that is neither a React function component nor a custom React Hook function`.

**Root cause:** A custom hook was named `usStory` instead of `useStory`. React's rules of hooks require the `use` prefix — without it, the linter (and at runtime, React itself) cannot identify it as a hook and rejects the `useState` call inside it.

**Fix:** Renamed the function to `useStory` and updated both call sites.

**Prevention:** ESLint with `eslint-plugin-react-hooks` now catches this at lint time before it reaches the browser.

---

### Git history contained traces of the original repository

**Symptom:** After replacing all source files, `git log` still showed commit messages referencing the original project name. GitHub's contributor graph also showed a contributor that should not appear.

**Root cause:** Git history is immutable by default — replacing files does not rewrite past commits. The original author's commits were still present in the DAG.

**Fix:** Created an orphan branch (`git checkout --orphan`), staged all current files as a single commit under the correct author identity, then force-pushed to `main`. This replaces the entire history with one clean commit.

**Prevention:** For any future project built on a fork or clone, history rewrite is now step zero before any work begins.

---

### `git push` rejected after history rewrite on local machine

**Symptom:** After cloning the cleaned repository locally and pulling, Git refused with "refusing to merge unrelated histories", then after attempting a rebase, push was rejected as non-fast-forward.

**Root cause:** The local clone's `main` branch still pointed to the old history. After a force-push to the remote, the local and remote histories diverged completely. `git pull` without `--allow-unrelated-histories` fails; and after rebase, push still requires `--force` because the remote tip changed.

**Fix:** Re-cloned fresh from the remote, which gave a clean working copy with no local history conflicts.

**Prevention:** After any force-push that rewrites history, the correct recovery on other machines is always a fresh clone, not a pull.

## Trade-offs and known limitations

- **EKS not provisioned by Terraform.** The monitoring server is, the cluster is not. With more time: full cluster provisioning in Terraform including VPC, subnets, node groups, and IAM roles.
- **No HPA.** The app scales fine at 2 replicas for demo traffic. A real workload needs Horizontal Pod Autoscaler backed by a metrics-server.
- **Docker Hub instead of ECR.** Public registry is fine for a portfolio project but a production deployment would use a private registry with image signing.
- **Jenkins on a single EC2 instance.** No HA for the CI server itself. If that instance goes down, the pipeline is unavailable.
- **No staging environment.** Code goes from the pipeline directly to the only cluster. A production setup would deploy to staging first and require a manual promotion gate.

## Local development

```bash
git clone https://github.com/wiamelyakini/the-briefing.git
cd the-briefing
npm install
npm start
# Opens at http://localhost:3000
```

No API key required — the app uses the public [Hacker News Firebase API](https://github.com/HackerNews/API).

To build the Docker image locally:

```bash
docker build -t the-briefing .
docker run -p 3000:3000 the-briefing
```

## Repo structure

```
Jenkinsfile              # Main CI/CD pipeline (build → scan → push → deploy)
Dockerfile               # Multi-stage React build
K8S/
  Jenkinsfile            # Kubernetes-specific pipeline variant
  manifest.yml           # Deployment (2 replicas) + LoadBalancer service
Terraform/
  jenkinsfile            # Pipeline for provisioning the monitoring server
  main.tf                # EC2 instance for Prometheus + Grafana
scripts/                 # Tool installation scripts (Trivy, kubectl, etc.)
```

## Roadmap

- [ ] **Terraform the EKS cluster** — highest priority; currently the biggest gap between "demo" and "production-grade IaC"
- [ ] **Add HPA** — requires metrics-server on the cluster; straightforward once the cluster is stable
- [ ] **Private image registry (ECR)** — remove the public Docker Hub dependency
- [ ] **Staging environment** — deploy to a second namespace before promoting to production
- [ ] **Alertmanager rules** — turn Blackbox probe failures into actual alerts, not just dashboard signals
- [ ] **Network policies** — restrict pod-to-pod traffic to only what is necessary

## Author

Wiame EL YAKINI — [GitHub](https://github.com/wiamelyakini) · [LinkedIn](https://www.linkedin.com/in/wiame-el-yakini/)
