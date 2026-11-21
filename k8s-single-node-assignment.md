# **DevOps Engineer Assignment: Single Node Kubernetes** 

Build a single-node Kubernetes cluster on a local VM, from a clean OS image to a running workload. 

## **How to work** 

- **Use an LLM agent.** We expect you to use Claude Code, Cursor, Codex, or a similar tool. 
- **No cloud account.** Everything should run against a local VM. 

## **Environment** 

- One VM created with Vagrant, Lima, or similar. 
- 4 vCPU, 8 GB RAM, 40 GB disk. 
- Debian 13 (trixie), amd64 or arm64. 

## **Requirements** 

Build the following with Ansible, from a clean VM. 

1. **OS preparation:** everything the node needs to run Kubernetes, with containerd as the container runtime. Pin package versions. 

2. **Kubernetes with kubeadm:** one node that is the control plane and also runs your workloads. 

  3. **Networking:** a CNI of your choice. Application pods accept only the traffic they need. 

4. **Ingress and TLS:** an ingress controller, with certificates from an internal CA that you create, renewed automatically. 

  5. **Storage:** a default StorageClass of your choice. 


6. **Monitoring:** Prometheus and Grafana, with alerts for node health and etcd health. You do not need to deliver alerts anywhere; firing in Alertmanager is enough. 

7. **Backups:** scheduled etcd snapshots, stored outside the cluster. 

8. **Hardening:** 
      - a read-only role for operators, and a kubeconfig for an operator user 
      -  application workloads cannot run as root or with elevated privileges 
      - every request to the Kubernetes API is recorded 

9. **Sample application:** the llama.cpp server with a small model (for example Qwen2.5-0.5BInstruct, GGUF, Q4 quantization), running on CPU, reachable through the ingress over TLS. A pod restart must not download the model again. This request must work from your host: 

```
curl --cacert ca.crt https://llm.local/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello"}]}'
```

## **Deliverables** 

A git repository with your work, including its documentation and the CA certificate. 

## **Questions** 

If something is unclear, you can email us for clarifications. If you have to make assumptions, make them. 

