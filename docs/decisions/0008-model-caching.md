# 0008 — Keeping the llama.cpp model across restarts

Status: Accepted · Date: 2026-11-17

## Context
Requirement 9: restarting the pod must not download the model again.
Requirement 3: app pods should have no outbound access.

## Decision
The model lives on a 2 GiB volume. A separate one-time Job downloads it, and only when needed.
The server pod never has outbound access.

## Details
- Model: Qwen2.5-0.5B-Instruct Q4_K_M. Hugging Face commit and sha256 are pinned in `versions.yml`.
- **When to download**: Ansible hashes the model file on the node. If it is missing or the hash is wrong, Ansible runs
  the Job (label `component=model-fetch`), waits for it to finish or fail, deletes it, and restarts the server.
- **Network**: only pods with the Job's label get DNS and HTTPS (TCP 443) to public IPs. Private ranges
  (RFC1918, 169.254/16, 100.64/10) stay blocked. Any public IP, because Hugging Face's CDN addresses change and
  NetworkPolicy can't match hostnames.
- **Server**: one Deployment, 1 replica, `Recreate`. CPU 1 request / 3 limit (3 threads), memory 768Mi request / 1536Mi limit,
  2 slots × 2048 context. `--no-slots` hides the `/slots` endpoint, `--no-webui` the web UI; no metrics endpoint, so Prometheus doesn't scrape it.
  It mounts the volume read-only. Init container `verify-model` checks the hash and stops on a mismatch (`Init:Error`).
- The Job and the init container reuse the llama.cpp image (it has curl and sha256sum), so there is no second image.
- A healthy re-run only hashes the file (about 2 s) and changes nothing. A deleted volume claim leaves the pod Pending
  until the next provision.
- **Recovery** from a lost or broken model, or a failed download: `make provision TAGS=llm_app`
  ([troubleshooting](../runbooks/troubleshooting.md#model-missing-or-corrupt)).

## Alternatives
| Option | Why not |
|---|---|
| Download in an init container | The server pod needs outbound access; runs on every start |
| Model inside the image | Needs a registry and a build step |
| hostPath folder | Not allowed under `restricted` |
| Annotation or marker file decides when to download (first version, B-045) | Can say "done" while the file is gone; the hash can't |
| Outbound access for the whole pod (first version, B-044) | The server would keep it forever |

## Consequences
- Restarting or deleting the pod reuses the volume; no Job runs. `check_9` tests this.
- `make vm-reset` deletes the volume, so each fresh VM downloads the model once.
- Outbound access exists only while the Job runs.
- Accepted Low risks: anyone who can create pods in `llm` could copy the Job label to get outbound access (today only
  admins and controllers); the pod restart after a download does not wait for the rollout; a failed Job and its logs
  are deleted after 1 hour.
