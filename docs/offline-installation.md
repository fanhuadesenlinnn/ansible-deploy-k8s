# Offline installation

Offline mode deliberately uses a transport-neutral bundle. Ansible can copy it from the controller, or every node can
download the same tar archive from an HTTP server such as dufs, Nginx, MinIO, or an object-storage gateway.

## Bundle layout

```text
k8s-offline-bundle/
├── bin/
│   └── crictl
├── packages/
│   ├── containerd_*.deb
│   ├── kubeadm_*.deb
│   ├── kubectl_*.deb
│   ├── kubelet_*.deb
│   └── all required Debian package dependencies
├── images/
│   ├── kubernetes-images.tar
│   └── cni-images.tar
└── manifests/
    └── kube-flannel.yml
```

Package dependencies must match the target distribution and architecture. Build separate bundles when the operating
system release or architecture differs. The installer verifies that the bundle contains kubeadm, kubelet, kubectl, the
selected container runtime, a CNI manifest, and at least one image archive before package installation begins.

When `install_crictl` is enabled, place the extracted Linux binary for the target architecture at `bin/crictl`. The role
copies it to `/usr/local/bin/crictl`, sets executable permissions, writes `/etc/crictl.yaml`, and verifies the configured
CRI endpoint before kubeadm runs.

Image archives must be readable by the chosen runtime. For containerd, create them with `ctr`, `nerdctl`, or another
OCI-compatible tool. The installer imports every `images/*.tar` file into the `k8s.io` namespace.

## Local-controller transport

```yaml
install_mode: offline
offline_bundle_path: /srv/k8s-offline-bundle
offline_bundle_url: ""
```

## HTTP transport

Create a tar archive of the directory and publish it through an HTTP server:

```yaml
install_mode: offline
offline_bundle_path: ""
offline_bundle_url: http://192.0.2.10:666/k8s-offline-bundle.tar.gz
offline_bundle_checksum: sha256:<archive checksum>
```

Always publish the archive checksum through a separate trusted channel. Package installation uses `--no-download`, so a
missing dependency fails instead of silently contacting a configured apt repository.

The optional `playbooks/artifact-server.yml` installs dufs on the first control-plane host. It is a convenience tool,
not a dependency of the Kubernetes roles.
