# AGENTS.md — Kubernetes-App

An AppStore app repository: one OpenStack VM with k3s per team, with one SSH pod per student
inside it. The platform obligations (variables `users`/`image_name`, outputs
`user_accounts`/`team_vms`/`teams_summary`, provider profile `openstack`) match
`template-app/AGENTS.md`. Usage details are in `README.md`.

## Invariants

* **Dual-stack, IPv6 first.** Never pick addresses via `all_fixed_ips[0]`; use
  `local.fixed_ip_v4/v6` instead. Security-group rules exist twice, once per ethertype.
* **No changes to `user_data` that would affect the VM.** `lifecycle.ignore_changes = [user_data]`
  protects student home directories. New students are added via `labctl add-student`, not via
  Terraform.
* **Logic lives in the image, data lives in cloud-init.** Scripts (`labctl`, provisioning) live
  under `packer/files/` and are installed into the image. `user-data.yaml.tpl` holds only
  configuration.
* **Students must never reach the metadata service, the API, the node, or the campus/OpenStack
  network** (`local.campus_cidr_v4/v6`, also the security group source). This holds in every mode.
  Two namespace labels switch the rest, initial values from `allow_pod_communication` /
  `allow_internet`:
  * `kubernetes-app/peer-access=open|isolated`: the additive policy `student-peer-access` opens
    student↔student traffic only.
  * `kubernetes-app/internet=allowed|blocked`: `student-isolation` has an `ipBlock` egress rule
    (with all the blocks above in `except`) only when allowed; otherwise egress is DNS only.

  The namespace labels, not `lab.env`, are the source of truth after first boot. Any change to these
  policies must be covered in `tests/labctl.sh`.
* **Ports are never reassigned.** `terraform_data.port_registry` (`ignore_changes = [input]`) keeps
  the first-seen order per team; new students are appended. Never sort ports by the current roster.
* **Resources are guaranteed** (request = limit, `pod_cpu`/`pod_memory_mb`/`pod_disk_gb`).
  `local.reserved` must match the `kube-reserved`/`system-reserved` kubelet args in
  `user-data.yaml.tpl`; the capacity precondition on the VM uses `modules/capacity`.
* **Readiness contract.** The first-boot script must end with exactly one serial-console line
  `APPSTORE-READY` or `APPSTORE-FAILED: <reason>`. The output `readiness_checks` tells the worker
  which instances to poll; its `timeout_seconds` must stay above the sum of the waits in
  `kubernetes-app-provision.sh`.
* **Usernames are DNS labels** (`^[a-z]([a-z0-9-]{0,28}[a-z0-9])?$`) and must match between
  `main.tf` and `labctl`.
* `LAB_IMAGE` (`labctl`, `main.tf`) and `student_image` (Packer) must use the same name and tag.
* Never commit secrets: `clouds.yaml`, `terraform.tfvars`, `*.kubeconfig`, Terraform state.

## Verification

Terraform, shellcheck, and Python only run inside the sandbox (root `CLAUDE.md`):

```bash
python3 agentic-harness/sandbox.py bash Kubernetes-App/check.sh
```

`packer build`, `terraform apply`, and any command against OpenStack are run by the developer
themself.

## Context for backend/frontend agents

Two features are planned on top of this app: (1) letting a teacher download the admin kubeconfig
from the frontend, and (2) exposing `labctl` operations (reassign/reset/passwd/add-student/
remove-student/list) as buttons in the frontend. Neither exists yet on the backend or frontend
side — this section is the context needed to plan that work; it does not prescribe how to build it.

**What already exists and where:**

* The Terraform output `kubeconfigs` (`terraform/outputs.tf`) is a map `team → kubeconfig string`,
  marked `sensitive = true`. It is the standard `kubectl` admin config — a static cluster-admin
  bearer token plus the cluster CA, scoped to that team's single-VM k3s cluster. There is currently
  no backend code path that reads this output at all (confirmed: no `kubeconfig` occurrences
  anywhere under `backend/app`), and no frontend UI for it either.
* `user_accounts` and `team_vms` (same file) are already piped through the existing platform
  pipeline: `Task.outputs` stores the full raw Terraform outputs as JSON after a successful
  deploy; `GET /{deployment_id}/my-access` (backend) extracts just the calling user's own account
  for the member/student role, while the owner/teacher role can read the full `outputs` blob via
  the deployment detail endpoint. `kubeconfigs` is not part of either path today.
* `labctl` (`packer/files/labctl`) is a bash script baked into the VM image. It is **not** reachable
  over the network today — it only runs either locally against a kubeconfig
  (`KUBECONFIG=... labctl ...`) or over SSH on the VM itself (`sudo labctl ...`, requires
  `key_pair_name` to have been set at deploy time). There is no HTTP/RPC surface for it, and no
  reusable library form of its logic — the Kubernetes API calls it makes (create/patch/delete
  Deployment, Service, Secret, PVC, NetworkPolicy in namespace `lab`) only exist inlined in that
  shell script.
* `labctl`'s commands and their effect on cluster state (see `README.md` and the script itself):
  `list`, `reassign <user>` (new pod, same home dir, same port), `reset <user> [--new-password]`
  (new pod, home dir wiped), `passwd <user> [password]`, `add-student <user> [password] [port]`,
  `remove-student <user> [--yes]`, `sync`, `wait-ready [--timeout <s>]`,
  `network peers|internet <on|off>`, `network status`, `shell <user>`, `logs <user>`.
  `reassign`/`reset` wait for rollout (up to 180s) before returning.
* `labctl` is planned to move to the backend (its own Kubernetes client against the kubeconfig
  output). Until then it stays in the image; keep all state in the cluster (objects and namespace
  labels) so a backend implementation can take over without migrating anything.

**Security-relevant facts to design around:**

* The kubeconfig grants cluster-admin on that team's cluster — equivalent in power to full root on
  the VM's Kubernetes control plane. It must only ever reach the teacher/owner role for that
  specific deployment/team, never a student/member.
* Each `labctl` command acts on one team's cluster only; any server-side trigger needs to resolve
  "which team / which cluster" from the caller's own access rights, not from client-supplied IDs
  alone — mirroring how `ensure_resend_access` / `ensure_deployment_access` already gate per-team
  credential access elsewhere in the backend.
* `add-student`/`remove-student`/`reset` are destructive or state-creating operations (data loss,
  new cluster objects); `reassign`/`passwd`/`list` are comparatively low-risk. Whatever surfaces
  these as buttons should weigh that difference the same way the existing resend-access endpoint
  already distinguishes "safe to retry" from "owner-only, confirmation-worthy" actions.
* There is no rate limiting or in-flight/lifecycle-state guard on `labctl` today (unlike the
  deployment lifecycle actions, which take an advisory lock while pending/running/destroying). A
  command fired while the team's deploy is mid-transition could race Terraform or an in-progress
  k3s start.

**Open question deliberately left to the implementing team:** whether triggering `labctl` from the
backend should call into the cluster directly (its own Kubernetes client against the kubeconfig
pulled from Terraform outputs) or shell out to the VM (e.g. via SSH, which depends on
`key_pair_name` having been set and is not guaranteed for every deployment). Both have different
implications for required secrets, latency, and failure modes; this file intentionally does not
pick one.
