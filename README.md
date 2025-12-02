# SOPS + Vault + ArgoCD GitOps Setup

> ⚠️ **Important**: Replace all placeholder values (`<YOUR_TOKEN_HERE>`, `your-ngrok-url.ngrok-free.dev`) with your actual values. Never commit real tokens to Git!

Complete guide for setting up encrypted secrets management using SOPS, HashiCorp Vault, and ArgoCD in a Kubernetes cluster.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Setup Steps](#setup-steps)
  - [1. Install Vault (Production Mode)](#1-install-vault-production-mode)
  - [2. Initialize and Unseal Vault](#2-initialize-and-unseal-vault)
  - [3. Configure Vault for SOPS](#3-configure-vault-for-sops)
  - [4. Expose Vault with ngrok](#4-expose-vault-with-ngrok)
  - [5. Install ArgoCD with SOPS Support](#5-install-argocd-with-sops-support)
  - [6. Create Helm Chart with Encrypted Secrets](#6-create-helm-chart-with-encrypted-secrets)
  - [7. Deploy Application via ArgoCD](#7-deploy-application-via-argocd)
- [Developer Workflow](#developer-workflow)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)
- [Important Files](#important-files)

---

## 🎯 Overview

This setup enables:
- ✅ **Encrypted secrets in Git** - Store secrets safely in version control using SOPS
- ✅ **Vault Transit encryption** - Centralized key management with HashiCorp Vault
- ✅ **GitOps with ArgoCD** - Automatic decryption and deployment
- ✅ **External developer access** - Developers can encrypt/decrypt from anywhere via ngrok
- ✅ **Production-ready Vault** - High availability with Raft storage (not dev mode!)
- ✅ **Limited permissions** - Developers only get SOPS encrypt/decrypt access

---

## 🏗️ Architecture

```
┌─────────────┐
│  Developer  │
│   (laptop)  │
└──────┬──────┘
       │ vault login + sops -e/-d
       ↓
┌─────────────────────────────────────────┐
│          ngrok Public Tunnel            │
│ https://your-unique-url.ngrok-free.dev  │
└──────────────┬──────────────────────────┘
               ↓
┌──────────────────────────────────────────┐
│         Kind Cluster (cka-cluster)       │
│                                          │
│  ┌────────────┐      ┌────────────┐     │
│  │   Vault    │◄─────┤   ngrok    │     │
│  │  (3 pods)  │      │   (pod)    │     │
│  │  HA+Raft   │      └────────────┘     │
│  └─────┬──────┘                         │
│        │ Transit Engine: sops-key       │
│        ↓                                 │
│  ┌────────────┐                         │
│  │  ArgoCD    │                         │
│  │ repo-server│────► Decrypts secrets   │
│  │ (SOPS +    │      during sync        │
│  │ helm-secrets)                        │
│  └─────┬──────┘                         │
│        ↓                                 │
│  ┌────────────┐                         │
│  │  Demo App  │                         │
│  │  (nginx)   │                         │
│  └────────────┘                         │
└──────────────────────────────────────────┘
```

---

## 📦 Prerequisites

**Local Tools:**
```bash
brew install helm kubectl kind sops vault
```

**Cluster:**
```bash
kind create cluster --name cka-cluster
```

**Helm Repositories:**
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

---

## 🚀 Setup Steps

### 1. Install Vault (Production Mode)

Create `vault-prod-values.yaml`:
```yaml
global:
  enabled: true
  tlsDisable: true

injector:
  enabled: false

server:
  dev:
    enabled: false  # Production mode!
  
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true
        
        listener "tcp" {
          tls_disable = 1
          address = "[::]:8200"
          cluster_address = "[::]:8201"
        }
        
        storage "raft" {
          path = "/vault/data"
        }
        
        service_registration "kubernetes" {}

  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: null
    accessMode: ReadWriteOnce

  auditStorage:
    enabled: true
    size: 10Gi
```

Install Vault:
```bash
kubectl create namespace vault
helm install vault hashicorp/vault -n vault -f vault-prod-values.yaml
```

---

### 2. Initialize and Unseal Vault

**Initialize Vault:**
```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > vault-init.json
```

⚠️ **CRITICAL:** Keep `vault-init.json` safe! Contains unseal keys and root token.

**Unseal vault-0:**
```bash
# Extract keys from vault-init.json
KEY1="<key-from-vault-init.json>"
KEY2="<key-from-vault-init.json>"
KEY3="<key-from-vault-init.json>"

kubectl exec -n vault vault-0 -- vault operator unseal $KEY1
kubectl exec -n vault vault-0 -- vault operator unseal $KEY2
kubectl exec -n vault vault-0 -- vault operator unseal $KEY3
```

**Join and unseal vault-2:**
```bash
kubectl exec -n vault vault-2 -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -n vault vault-2 -- vault operator unseal $KEY1
kubectl exec -n vault vault-2 -- vault operator unseal $KEY2
```

Verify:
```bash
kubectl get pods -n vault
# vault-0  1/1  Running
# vault-2  1/1  Running
```

---

### 3. Configure Vault for SOPS

**Login to Vault:**
```bash
export VAULT_ADDR=https://your-ngrok-url.ngrok-free.dev
vault login <ROOT_TOKEN>  # Root token from vault-init.json
```

**Enable Transit engine:**
```bash
vault secrets enable transit
vault write -f transit/keys/sops-key
```

**Create SOPS policy:**
```bash
vault policy write sops-policy - <<EOF
path "transit/decrypt/sops-key" {
  capabilities = ["update"]
}

path "transit/encrypt/sops-key" {
  capabilities = ["update"]
}
EOF
```

**Enable userpass authentication:**
```bash
vault auth enable userpass

# Create developer users
vault write auth/userpass/users/developer1 \
  password="dev1-password-123" \
  policies="sops-policy"

vault write auth/userpass/users/developer2 \
  password="dev2-password-456" \
  policies="sops-policy"
```

**Create dedicated token for ArgoCD:**
```bash
vault token create -policy=sops-policy -ttl=768h -display-name=argocd-prod
# Save the token output and use it in values-minimal.yaml
```

---

### 4. Expose Vault with ngrok

Create `ngrok-deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ngrok
  namespace: vault
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ngrok
  template:
    metadata:
      labels:
        app: ngrok
    spec:
      containers:
      - name: ngrok
        image: ngrok/ngrok:latest
        args:
        - http
        - vault:8200
        - --log=stdout
        env:
        - name: NGROK_AUTHTOKEN
          valueFrom:
            secretKeyRef:
              name: ngrok-token
              key: token
---
apiVersion: v1
kind: Secret
metadata:
  name: ngrok-token
  namespace: vault
stringData:
  token: "YOUR_NGROK_TOKEN"
```

Deploy:
```bash
kubectl apply -f ngrok-deployment.yaml

# Get public URL
kubectl logs -n vault -l app=ngrok | grep "url="
# url=https://your-unique-url.ngrok-free.dev
```

---

### 5. Install ArgoCD with SOPS Support

Create `helmfile.yaml`:
```yaml
repositories:
  - name: argo
    url: https://argoproj.github.io/argo-helm

releases:
  - name: argocd
    namespace: argocd
    chart: argo/argo-cd
    version: 7.3.9
    values:
      - values-minimal.yaml
```

Create `values-minimal.yaml`:
```yaml
configs:
  cm:
    create: true
    helm.valuesFileSchemes: >-
      ref+sops,
      secrets,
      https

repoServer:
  env:
    - name: HELM_PLUGINS
      value: /custom-tools/helm-plugins/
    - name: HELM_SECRETS_BACKEND
      value: sops
    - name: HELM_SECRETS_SOPS_PATH
      value: /custom-tools/sops
    - name: HELM_SECRETS_HELM_PATH
      value: /usr/local/bin/helm
    - name: VAULT_ADDR
      value: https://your-ngrok-url.ngrok-free.dev
    - name: VAULT_TOKEN
      value: <YOUR_ARGOCD_TOKEN_HERE>

  initContainers:
    - name: download-tools
      image: alpine:latest
      command: [sh, -ec]
      env:
        - name: HELM_SECRETS_VERSION
          value: "4.6.0"
        - name: SOPS_VERSION
          value: "3.8.1"
      args:
        - |
          mkdir -p /custom-tools/helm-plugins
          
          echo "Installing helm-secrets..."
          wget -qO- https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/helm-secrets.tar.gz | tar -C /custom-tools/helm-plugins -xzf-
          
          echo "Installing SOPS..."
          wget -qO /custom-tools/sops https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64
          
          chmod +x /custom-tools/sops
      volumeMounts:
        - mountPath: /custom-tools
          name: custom-tools

  volumes:
    - name: custom-tools
      emptyDir: {}

  volumeMounts:
    - mountPath: /custom-tools
      name: custom-tools
```

Install ArgoCD:
```bash
kubectl create namespace argocd
helmfile sync

# Get admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

---

### 6. Create Helm Chart with Encrypted Secrets

**Create chart structure:**
```bash
mkdir -p templates
```

**Create `Chart.yaml`:**
```yaml
apiVersion: v2
name: sops-demo
version: 1.0.0
description: Demo app with SOPS encrypted secrets
```

**Create `.sops.yaml`:**
```yaml
creation_rules:
  - path_regex: secrets\.yaml$
    hc_vault_transit_uri: "https://your-ngrok-url.ngrok-free.dev/v1/transit/keys/sops-key"
```

**Create plaintext secrets file:**
```yaml
# secrets.yaml (before encryption)
secrets:
  username: admin
  password: "123456"
```

**Encrypt secrets:**
```bash
sops -e -i secrets.yaml
```

**Create `templates/secret.yaml`:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: demo-secret
type: Opaque
stringData:
  username: {{ .Values.secrets.username }}
  password: {{ .Values.secrets.password }}
```

**Create `templates/deployment.yaml`:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo
  template:
    metadata:
      labels:
        app: demo
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        env:
        - name: USERNAME
          valueFrom:
            secretKeyRef:
              name: demo-secret
              key: username
        - name: PASSWORD
          valueFrom:
            secretKeyRef:
              name: demo-secret
              key: password
```

**Create `templates/service.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-service
spec:
  selector:
    app: demo
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
```

---

### 7. Deploy Application via ArgoCD

**Create `application.yaml`:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: sops-demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/FaresMirza/test-vault
    targetRevision: main
    path: .
    helm:
      valueFiles:
        - secrets://secrets.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Deploy:**
```bash
kubectl apply -f application.yaml

# Watch sync status
kubectl get application -n argocd -w
```

**Verify:**
```bash
# Check secret was decrypted correctly
kubectl get secret demo-secret -o jsonpath='{.data.username}' | base64 -d
# Output: admin

kubectl get secret demo-secret -o jsonpath='{.data.password}' | base64 -d
# Output: 123456

# Check app is running
kubectl get pods -n default
```

---

## 👨‍💻 Developer Workflow

### First Time Setup

```bash
# Install tools
brew install sops vault

# Login to Vault
vault login -method=userpass \
  -address=https://your-ngrok-url.ngrok-free.dev \
  username=developer1 \
  password=dev1-password-123

# Token saved to ~/.vault-token (valid for 30 days)
```

### Daily Operations

**Decrypt secrets:**
```bash
sops -d secrets.yaml
```

**Edit secrets:**
```bash
sops secrets.yaml
# Opens in $EDITOR with decrypted content
# Save and exit - automatically re-encrypts
```

**Encrypt new secrets:**
```bash
# Create plaintext file
cat > new-secrets.yaml <<EOF
secrets:
  api_key: "super-secret-key"
EOF

# Encrypt
sops -e -i new-secrets.yaml
```

**Add to Git:**
```bash
git add secrets.yaml
git commit -m "Update secrets"
git push

# ArgoCD automatically syncs and deploys!
```

---

## 🔒 Security Best Practices

### 1. Protect vault-init.json

```bash
# Encrypt it
gpg -c vault-init.json

# Store in password manager
# Print and put in physical safe
# Split keys among team members (Shamir's Secret Sharing)
```

### 2. Rotate Tokens Regularly

```bash
# ArgoCD token expires in 32 days
# Before expiration, create new token:
vault token create -policy=sops-policy -ttl=768h -display-name=argocd-prod

# Update values-minimal.yaml with new token
# Run: helm upgrade argocd argo/argo-cd -n argocd -f values-minimal.yaml
```

### 3. Use Production-Grade ngrok

- Current: Free tier with dynamic URLs
- Production: Paid plan with static domain
- Alternative: Deploy Vault on cloud VM with real domain + TLS

### 4. Enable Audit Logging

```yaml
# In vault-prod-values.yaml
server:
  auditStorage:
    enabled: true
```

### 5. Implement Auto-Unseal

```yaml
# For AWS KMS:
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "your-kms-key"
}
```

---

## 🔧 Troubleshooting

### Vault Pod Not Ready After Restart

**Problem:** Pod shows 0/1 Running
```bash
kubectl get pods -n vault
# vault-0  0/1  Running
```

**Solution:** Unseal the pod
```bash
kubectl exec -n vault vault-0 -- vault operator unseal <KEY1>
kubectl exec -n vault vault-0 -- vault operator unseal <KEY2>
kubectl exec -n vault vault-0 -- vault operator unseal <KEY3>
```

### ArgoCD Can't Decrypt Secrets

**Problem:** Application sync fails with "failed to decrypt"

**Solution:** Check Vault token
```bash
# Test token
export VAULT_ADDR=https://your-ngrok-url.ngrok-free.dev
export VAULT_TOKEN=<token-from-values-minimal.yaml>
vault token lookup

# If expired, create new token and update values-minimal.yaml
```

### Developer Can't Encrypt/Decrypt

**Problem:** `sops -d secrets.yaml` fails with "permission denied"

**Solution:** Re-login to Vault
```bash
vault login -method=userpass \
  -address=https://your-ngrok-url.ngrok-free.dev \
  username=developer1
```

### Secrets Not Found in Git

**Problem:** `.gitignore` blocking encrypted files

**Solution:** Ensure `.gitignore` allows encrypted files
```bash
# .gitignore
# ❌ DON'T: *.yaml
# ✅ DO: secrets-unencrypted.yaml
```

---

## 📁 Important Files

| File | Purpose | Sensitive? |
|------|---------|-----------|
| `vault-init.json` | Unseal keys + root token | ⚠️ **CRITICAL** - Keep secure! Never commit! |
| `values-minimal.yaml` | ArgoCD config with Vault token | ⚠️ Contains token - use placeholders in Git |
| `vault-prod-values.yaml` | Vault Helm values | ✅ Safe to commit |
| `.sops.yaml` | SOPS configuration | ✅ Safe to commit (with placeholder URLs) |
| `secrets.yaml` | **Encrypted** secrets | ✅ Safe to commit |
| `Chart.yaml` | Helm chart metadata | ✅ Safe to commit |
| `templates/*.yaml` | Kubernetes manifests | ✅ Safe to commit |
| `application.yaml` | ArgoCD Application | ✅ Safe to commit |

---

## 🎓 Key Concepts

### SOPS (Secrets OPerationS)
- Encrypts YAML/JSON files while keeping structure readable
- Only values are encrypted, keys remain plaintext
- Supports multiple backends: Vault, age, AWS KMS, GCP KMS, Azure KeyVault

### Vault Transit Engine
- Encryption-as-a-Service
- Never stores data, only encryption keys
- Provides encrypt/decrypt API endpoints

### helm-secrets Plugin
- Integrates SOPS with Helm
- Auto-decrypts during `helm install/upgrade`
- Uses `secrets://` protocol in ArgoCD

### ArgoCD repoServer
- Component that processes Git repositories
- Custom initContainer installs SOPS + helm-secrets
- Uses Vault token to decrypt during sync

---

## 🚨 Emergency Recovery

### Vault Completely Lost

If Vault is deleted and you have no backups:

**Option 1: Recover from plaintext backup**
```bash
# If you saved decrypted backup:
sops -e secrets-backup.yaml > secrets.yaml
```

**Option 2: Redeploy Vault and re-encrypt**
```bash
# Deploy new Vault
helm install vault hashicorp/vault -n vault -f vault-prod-values.yaml

# Initialize, unseal, configure
# ... (see steps 2-3) ...

# Re-encrypt all secrets
for file in secrets*.yaml; do
  sops -e "$file" > "${file}.new"
done
```

**Option 3: Switch encryption backend**
```bash
# Use age instead
age-keygen -o keys.txt

# Update .sops.yaml
creation_rules:
  - path_regex: secrets\.yaml$
    age: <your-public-key>
```

### ngrok URL Changed

```bash
# Update .sops.yaml
hc_vault_transit_uri: "https://NEW-URL.ngrok-free.dev/v1/transit/keys/sops-key"

# Update values-minimal.yaml
- name: VAULT_ADDR
  value: https://NEW-URL.ngrok-free.dev

# Re-encrypt secrets
sops updatekeys secrets.yaml

# Upgrade ArgoCD
helm upgrade argocd argo/argo-cd -n argocd -f values-minimal.yaml
```

---

## 📚 Additional Resources

- [SOPS Documentation](https://github.com/getsops/sops)
- [Vault Transit Engine](https://developer.hashicorp.com/vault/docs/secrets/transit)
- [helm-secrets Plugin](https://github.com/jkroepke/helm-secrets)
- [ArgoCD Secret Management](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/)

---

## ✅ What We Achieved

- ✅ Production Vault with HA (3 replicas, Raft storage)
- ✅ No root token in production (using limited sops-policy token)
- ✅ Encrypted secrets safely stored in Git
- ✅ ArgoCD automatically decrypts and deploys
- ✅ Developers can encrypt/decrypt from anywhere (ngrok)
- ✅ Limited permissions (developers only get SOPS access)
- ✅ Token rotation support (32-day TTL, renewable)
- ✅ Complete disaster recovery documentation

**This is production-ready** (with proper ngrok domain + auto-unseal)! 🎉
