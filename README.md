# MemVerge.ai PoC on AWS with K3s, GPU Workers, and Helm

Welcome to the **MemVerge.ai Proof of Concept (PoC)** CloudFormation deployment for AWS! This solution provisions a lightweight Kubernetes (K3s) cluster using CloudFormation with GPU-enabled worker nodes, installs core infrastructure components (cert-manager, Helm), and sets up **MemVerge.ai** via Helm charts.

---

## 📘 Overview
This project provides an AWS-native way to deploy MemVerge.ai using CloudFormation scripts. It:
- Creates a VPC-based infrastructure with EC2 instances for control plane and GPU-enabled worker nodes.
- Deploys K3s as a lightweight Kubernetes cluster.
- Uses EC2 Auto Scaling Groups and Launch Templates for repeatable deployments.
- Installs MemVerge.ai from GitHub's Helm OCI Registry.

> ✅ Supports downloading bootstrap scripts from either AWS S3 **or** a public GitHub repository.

---

## 🧰 Prerequisites
Before deploying this CloudFormation stack, ensure you have:

### 1. AWS Account Setup
- An AWS account with sufficient IAM privileges to create EC2, IAM roles, Auto Scaling, and VPC resources.
- AWS CLI installed locally (optional for automation).

### 2. Precreated Resources
- **VPC ID** and **Subnet ID** (use existing or create a new one).
- A valid **EC2 Key Pair** (for optional SSH access).
- **Hosted Zone** in Route 53 (for subdomain DNS mapping).

### 3. Artifacts
- Scripts are stored either in:
  - **GitHub**: public repository (e.g. `https://github.com/my-org/memverge-ai-poc`)
  - **AWS S3**: e.g. `s3://memverge-ai-poc-userdata-script-amd/`

### 4. MemVerge.ai GitHub Token
- You’ll need a **GitHub personal access token** to pull Helm charts from `ghcr.io/memverge/charts/mmai`.

---

## 🚀 Quick Start

### 1. Upload or Clone the Repository
Clone this repo or upload the files to your S3 bucket:
```bash
git clone https://github.com/my-org/memverge-ai-poc.git
```

### 2. Open AWS CloudFormation Console
Go to the AWS Management Console → **CloudFormation** → **Create Stack** → With new resources (standard).

### 3. Upload or Link the `master.yaml`
- Use the local file (`master.yaml`) or link to the GitHub raw version.

### 4. Fill In Parameters
| Parameter | Description |
|----------|-------------|
| VPCID | Your existing VPC ID |
| SubnetID | Public subnet for launching EC2 instances |
| KeyPairName | EC2 Key Pair for SSH access |
| AMIControlPlane | Ubuntu AMI ID for Control Plane (e.g. Ubuntu 22.04) |
| AMIWorkerNode | Ubuntu AMI ID with GPU support (e.g. NVIDIA A10 compatible) |
| InstanceTypeControlPlane | e.g. `m5.2xlarge` |
| InstanceTypeWorker | e.g. `g5.4xlarge` |
| WorkerNodeCount | e.g. `1` or more |
| ControlPlaneCount | e.g. `1` or `3` |
| MemVergeVersion | Helm chart version (e.g. `0.3.0`) |
| SubDomain | Subdomain prefix (e.g. `demo1` → `demo1.memvergelab.com`) |
| MemVergeGitHubToken | GitHub token for Helm registry |
| ScriptSource | Select 'S3' or 'GitHub' to choose where bootstrap scripts are downloaded from |
| ScriptS3Bucket | (If using S3) Name of the bucket containing your shell scripts |
| GitHubRepo | (If using GitHub) Owner/repo format (e.g., my-org/my-repo) [MODIFY HERE] |
| GitHubBranch | GitHub branch containing the scripts (e.g., `main`) [MODIFY HERE] |

---

## 🛠️ Step-by-Step Guide

### Step 1: Launch the Stack
Deploy the stack using CloudFormation. Stack creation typically takes 5–10 minutes.

### Step 2: Validate Control Plane
Once the stack is complete:
- Go to EC2 Console → Instances.
- SSH into one of the control plane nodes (optional).
- Verify nodes with:
  ```bash
  kubectl get nodes
  ```
  You should see 1 control plane + N worker nodes all marked as `Ready`.

### Step 3: (Optional) Run `install-mmai.sh`
If the MemVerge.ai install was separated:
```bash
scp install-mmai.sh ubuntu@<control-plane-ip>:/tmp/
ssh ubuntu@<control-plane-ip> "chmod +x /tmp/install-mmai.sh && MEMVERGE_GITHUB_TOKEN=xxx /tmp/install-mmai.sh"
```

### Step 4: Access the Dashboard
- Navigate to: `https://<SubDomain>.memvergelab.com`
- Login with:
  - Username: `admin`
  - Password: `admin` (change after login)

---

## 🧹 Cleanup Instructions
To remove all resources:

### Option 1: CloudFormation Console
- Go to **CloudFormation → Stacks → Select your stack → Delete**

### Option 2: AWS CLI
```bash
aws cloudformation delete-stack --stack-name memverge-ai-stack
```

> 🧨 This removes all EC2, IAM, ALB, and Auto Scaling resources. Ensure backups if needed.

---

## 🧩 File Structure
```bash
scripts/
├── controlplane.sh       # Initializes K3s server
├── worker.sh             # Initializes K3s agents
├── install-mmai.sh       # Installs MemVerge.ai using Helm
master.yaml               # CloudFormation template
README.md                 # This file
```

---

## 🛠️ Troubleshooting
| Issue | Solution |
|-------|----------|
| Nodes stuck in `NotReady` | Check `k3s` logs in control plane via `journalctl -u k3s` |
| MemVerge chart fails | Confirm GitHub token is valid & has `read:packages` scope |
| Workers can’t reach control plane | Ensure Security Groups allow TCP 6443 |
| Timeout waiting for nodes | Make sure AMIs are compatible and have internet access |

---

## 🔒 Security Notes
- This demo uses wide-open security groups for simplicity. Restrict IPs in production.
- Store GitHub tokens in AWS Secrets Manager for long-term use.

---

## 🙌 Contributing
Feel free to fork and PR improvements or submit issues.

---

## 📝 License
MIT License

---

## 📬 Questions?
Contact `support@memverge.ai` or visit [https://memverge.com](https://memverge.com).

---

Thank you for trying MemVerge.ai on AWS! 🚀
