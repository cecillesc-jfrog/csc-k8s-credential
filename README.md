# csc-k8s-credential-demo

Secretless path from commit to running pod.

1. GitHub Actions builds an amd64 image and pushes it to hts2 `csc-project-docker-local`, authenticating with GitHub OIDC (no stored JFrog credential).
2. An EKS cluster pulls the image with no imagePullSecret, using the JFrog kubelet credential provider (IAM role assumption).

Files:
- `.github/workflows/docker-push.yml`: build and push (manual run)
- `Dockerfile`: tiny Alpine image that prints its build number
- `k8s/oidc-demo-pod.yaml`, `k8s/run-pull-test.sh`: run the image on the cluster

Setup notes: the `JF_URL` secret, a self-hosted runner for this repo, and an OIDC identity mapping for this repository on the hts2 provider `csc-github-oidc`.
