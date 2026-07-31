# ansible-deploy-k8s

Install a standard Kubernetes cluster with Ansible and kubeadm. The repository is independent of any application,
private registry, internal DNS name, or CI/CD platform.

## Supported scope

- Ubuntu and Debian hosts using systemd and apt
- amd64 and arm64
- one or more control-plane nodes and any number of workers
- containerd by default; CRI-O is optional
- Flannel by default; another CNI can be supplied as a manifest URL or local file
- online installation or an offline bundle copied by Ansible/downloaded from an HTTP server
- optional metrics-server, cert-manager, Reloader, and Istio manifests

This project does not deploy business applications, Git servers, CI systems, storage systems, or container registries.
It installs new clusters and supports adding nodes; it does not perform in-place Kubernetes upgrades.

## Safety properties

- A normal installation never runs `kubeadm reset`.
- Existing `/etc/kubernetes/admin.conf` and `/etc/kubernetes/kubelet.conf` files prevent reinitialization and rejoin.
- Destructive reset is isolated in `playbooks/reset.yml` and requires a boolean confirmation plus the cluster name.
- No real credentials or production inventory are stored in the repository.
- NodePort defaults are not widened and operating-system package mirrors are not overwritten.

## Quick start

Requirements on the Ansible controller:

- Python 3.10+
- Ansible Core 2.16+
- SSH access to every target host
- passwordless sudo, or provide an Ansible become password securely

Install the controller dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

Copy the example inventory and replace the documentation-only addresses:

```bash
cp -R inventories/example inventories/my-cluster
$EDITOR inventories/my-cluster/hosts.yml
$EDITOR inventories/my-cluster/group_vars/all.yml
```

Non-example inventory directories are ignored by Git to reduce the chance of committing production addresses or secrets.

Verify connectivity and install:

```bash
ansible -i inventories/my-cluster/hosts.yml k8s_cluster -m ansible.builtin.ping
ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/site.yml
```

The admin kubeconfig is written to `artifacts/<cluster-name>.conf` on the Ansible controller.

## Inventory model

The first host in `kube_control_plane` initializes the cluster. Additional hosts join as control-plane nodes. All hosts
must also be children of `k8s_cluster`; the example inventory constructs that relationship automatically.

```yaml
all:
  children:
    kube_control_plane:
      hosts:
        control-01:
          ansible_host: 192.0.2.10
    kube_workers:
      hosts:
        worker-01:
          ansible_host: 192.0.2.11
    k8s_cluster:
      children:
        kube_control_plane: {}
        kube_workers: {}
```

For multiple control-plane nodes, set `control_plane_endpoint` to a stable load balancer or virtual IP. This project
does not create that load balancer.

## Online and offline installation

Online mode uses the official Kubernetes and CRI-O package repositories and the configured CNI manifest URL:

```yaml
install_mode: online
```

Offline mode accepts either a local bundle directory or an HTTP-hosted tar archive:

```yaml
install_mode: offline
offline_bundle_path: /absolute/path/on/ansible-controller/k8s-offline-bundle
# Alternatively:
# offline_bundle_url: http://artifact-server.example/k8s-offline-bundle.tar.gz
# offline_bundle_checksum: sha256:<archive checksum>
```

The extracted bundle must contain `packages/*.deb`, `images/*.tar`, and `manifests/<cni file>`. Any HTTP server can host
the bundle; dufs is available as an optional helper through `playbooks/artifact-server.yml`.

See [docs/offline-installation.md](docs/offline-installation.md) for the expected layout.

## Optional add-ons

Add-ons are disabled unless their corresponding variable is enabled:

```yaml
addons:
  metrics_server: true
  cert_manager: false
  reloader: false
  istio: false
```

Run them independently:

```bash
ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/addons.yml
```

## Resetting a cluster

Reset is intentionally separate and destructive:

```bash
ansible-playbook -i inventories/my-cluster/hosts.yml playbooks/reset.yml \
  -e kubernetes_reset_confirm=true \
  -e kubernetes_reset_cluster_name=my-cluster-name
```

Review the playbook before running it. It removes kubeadm state and CNI network configuration from the selected hosts.
It also removes the root kubeconfig installed on each host and the exported controller-side kubeconfig. As documented by
kubeadm, reset does not remove iptables, nftables, or IPVS rules; clean those separately when a completely pristine host
is required.

## Existing clusters and upgrades

`playbooks/site.yml` is intentionally an install and scale-out workflow. On a configured node, it verifies that the
installed kubelet patch version matches `kubernetes_version` and fails before changing packages when it does not. Follow
the upstream kubeadm upgrade sequence for upgrades; changing `kubernetes_version` alone is not an upgrade procedure.

Treat the container runtime, pod and service CIDRs, and control-plane endpoint as immutable after initialization unless
you are following a dedicated Kubernetes migration or reconfiguration procedure.

## Main variables

All documented defaults are in `inventories/example/group_vars/all.yml`. Important variables include:

- `kubernetes_version` and `kubernetes_version_minor`
- `container_runtime`
- `pod_network_cidr` and `service_cidr`
- `control_plane_endpoint`
- `api_server_cert_sans`
- `cni_manifest_url` or `cni_manifest_file`
- `cni_manifest_checksum`
- `install_mode`
- `offline_bundle_checksum`
- `registry_mirrors`
- `proxy_env`
- `kubernetes_apply_force_conflicts` (disabled by default)

## Validation

```bash
pip install -r requirements-dev.txt
yamllint .
ansible-lint
just check
```
