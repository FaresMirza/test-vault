#!/bin/bash
set -e

# Step 1: Apply the plugin ConfigMap
kubectl apply -f argocd-sops-plugin.yaml

# Step 2: Patch argocd-repo-server to add sidecar
kubectl patch deployment argocd-repo-server -n argocd --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "cmp-plugin",
      "configMap": {"name": "cmp-plugin"}
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "custom-tools",
      "emptyDir": {}
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "cmp-tmp",
      "emptyDir": {}
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/initContainers/-",
    "value": {
      "name": "download-tools",
      "image": "alpine:3.18",
      "command": ["sh", "-c"],
      "args": ["wget -O /custom-tools/sops https://github.com/getsops/sops/releases/download/v3.8.1/sops-v3.8.1.linux.amd64 && chmod +x /custom-tools/sops"],
      "volumeMounts": [{
        "mountPath": "/custom-tools",
        "name": "custom-tools"
      }]
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/-",
    "value": {
      "name": "sops-plugin",
      "command": ["/var/run/argocd/argocd-cmp-server"],
      "image": "quay.io/argoproj/argocd:latest",
      "env": [
        {"name": "VAULT_ADDR", "value": "http://vault.default.svc.cluster.local:8200"},
        {"name": "VAULT_TOKEN", "value": "root"}
      ],
      "securityContext": {
        "runAsNonRoot": true,
        "runAsUser": 999
      },
      "volumeMounts": [
        {"mountPath": "/var/run/argocd", "name": "var-files"},
        {"mountPath": "/home/argocd/cmp-server/plugins", "name": "plugins"},
        {"mountPath": "/home/argocd/cmp-server/config/plugin.yaml", "subPath": "plugin.yaml", "name": "cmp-plugin"},
        {"mountPath": "/usr/local/bin/sops", "subPath": "sops", "name": "custom-tools"},
        {"mountPath": "/tmp", "name": "cmp-tmp"}
      ]
    }
  }
]'

echo "✅ Plugin installed! Waiting for repo-server to restart..."
kubectl rollout status deployment argocd-repo-server -n argocd --timeout=120s

echo "✅ Done! Check with: kubectl get pods -n argocd | grep repo-server"
