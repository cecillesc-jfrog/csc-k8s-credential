# csc-k8s-credential

A secretless path from commit to running pod, on Amazon EKS and JFrog Artifactory (hts2).

1. **Build:** GitHub Actions builds an amd64 image and pushes it to Artifactory, logging in with GitHub OIDC. No JFrog credential is stored in GitHub.
2. **Pull:** EKS nodes pull the image with no `imagePullSecrets`, using the JFrog kubelet credential provider.

The cluster has two node groups, one per way of installing the provider:

| | Path A: node group `csc-ng01` | Path B: node group `csc-lt-ng01` |
|---|---|---|
| Provider installed by | Helm DaemonSet, from the official `examples/aws-values.yaml` | EC2 launch template user data at node boot |
| Nodes selected by | label `credentialsProviderEnabled=true` | the node group itself (no label) |
| Node settings | defaults | IMDSv2 required, hop limit 1, volume and security group in the template |
| Test pod | `oidc-demo` | `lt-test` |

Start with Path A for a POC. Add Path B where you own node boot. Pick one install method per node group.

## Repository layout

| Path | What it is |
|---|---|
| `.github/workflows/docker-push.yml` | Builds and pushes the image with GitHub OIDC (`workflow_dispatch`) |
| `Dockerfile` | A tiny Alpine image that prints its build number |
| `k8s/oidc-demo-pod.yaml` | Pod template with no `imagePullSecrets` and a node group selector |
| `k8s/run-pull-test.sh` | Runs the pull test on Path A, Path B or both |
| `setup/create-cluster.sh` | Creates the EKS cluster with the AWS CLI |
| `setup/aws-values.yaml` | Path A Helm values: the official `aws-values.yaml` with four values changed |
| `setup/aws-values.as-published.yaml` | The official file with only the placeholders filled in (fails: role ARN) |
| `setup/launch-template-node-group.sh` | Path B: creates the launch template and its node group |

The `setup/` files contain account-specific IDs (account, subnets, security group). Keep this repository private.

## Run order

1. **Setup**
   - Create the cluster: `bash setup/create-cluster.sh`.
   - In hts2: create a read-only Artifactory user, bind the node role ARN to it (`PUT /access/api/v1/aws/iam_role`), and create the GitHub OIDC provider `csc-github-oidc` with an identity mapping for this repository.
   - In this repository: add the secret `JF_URL` (`https://hts2.jfrog.io`) and register a self-hosted runner with Docker available.
2. **Deploy**
   - Path A: `helm upgrade --install secret-provider jfrog/jfrog-credential-provider --namespace jfrog --create-namespace -f setup/aws-values.yaml`
   - Path B: `bash setup/launch-template-node-group.sh`
   - Run the GitHub workflow "Build and Push Demo Image". It pushes `oidc-demo/hello:<run number>`.
3. **Run**
   - `./k8s/run-pull-test.sh <run number>` (both paths), or add `a` or `b`.
   - Check that the pods are Running, `imagePullSecrets` is empty, and hts2 > Administration > Identity and Access > Access Tokens shows "Generated access token for Aws assumed role token exchange".

## Gotchas

- In `aws_role_name` put the node role **name**, not the ARN. The ARN gives a `404` from the instance metadata service and no token.
- In launch template user data, generate the provider config with `--provider-config jfrog-provider`. Without it the kubelet's own `config.json` is overwritten and the node never joins.
- If the launch template's security group cannot reach the cluster security group, pods on those nodes cannot reach the Kubernetes API. Keep CoreDNS on the other node group (cordon, restart `coredns`, uncordon).
- Kubernetes events expire after about an hour. Capture screenshots right after the pull test.
- On the hts2 demo instance, non-admin users get `500 Failed to reload cache`, so the bound user is an admin for the demo. Use a read-only user in a real setup.

## Cleanup

```
kubectl delete pod oidc-demo lt-test -n default --ignore-not-found
aws eks delete-nodegroup --cluster-name cecillesc-cluster --nodegroup-name csc-lt-ng01 --region ap-south-1
aws ec2 delete-launch-template --launch-template-name cecillesc-eks-jfrog-lt --region ap-south-1
```
To keep the cluster but stop the cost, scale both node groups to 0.
