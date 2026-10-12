#!/usr/bin/env bash
# Launch template track: add a second managed node group whose nodes install the JFrog kubelet
# credential provider at boot through EC2 user data. No Helm DaemonSet is needed on these nodes.
#
# What the launch template sets:
#   - IMDSv2 required and hop limit 1 (pods cannot reach the node's IAM credentials; the kubelet plugin on the host still can)
#   - 30 GB gp3 root volume
#   - MIME user data that downloads the plugin binary, generates the provider config from environment variables,
#     merges it into the kubelet credential provider config, restarts the kubelet and starts the rollback watcher
#
# Security group: the Support_PowerUsers role denies ec2:RunInstances on any subnet or security group that is not tagged
# workload=support. A launch template that names no security group gets the VPC default group and is denied
# (error: DenyEc2CreationWithNonSupportSubnetAndSG). cs-mumbai-security-group carries the tag, allows all traffic from the
# VPC range and all egress, so the nodes can reach the control plane.
#
# The node group deliberately does NOT carry the label credentialsProviderEnabled=true, so the Helm DaemonSet
# does not run on these nodes. Anything that works on them was installed by the launch template.
#
# After it finishes, if the template uses a security group that cannot reach the control plane's cluster security group,
# pods on these nodes cannot reach the Kubernetes API (CoreDNS stays 0/1). Keep CoreDNS on a node group that can:
#   kubectl cordon <node of this group>
#   kubectl rollout restart deployment coredns -n kube-system   # wait for 1/1 on the other node group
#   kubectl uncordon <node of this group>
#
# Run:  bash setup/launch-template-node-group.sh
set -euo pipefail

REGION=ap-south-1
CLUSTER=cecillesc-cluster
NODEGROUP=csc-lt-ng01
LT_NAME=cecillesc-eks-jfrog-lt
NODE_ROLE=cecillesc-eks-node-role
ARTIFACTORY_URL=hts2.jfrog.io
PROVIDER_VERSION=1.4.0
MATCH_IMAGES='*.jfrog.io'
CACHE_DURATION=5m
SUBNETS="subnet-0e0329cae30241be1 subnet-0dd649a1593a7fdd5"   # private subnets of the shared cs-mumbai-vpc (tagged workload=support)
SECURITY_GROUP=sg-07ac1d343fab233c2                            # cs-mumbai-security-group (tagged workload=support)

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${NODE_ROLE}"
WORK=$(mktemp -d)

echo "== 1. User data (MIME multipart)"
cat > "$WORK/userdata.sh" <<'EOS'
Content-Type: multipart/mixed; boundary="//"
MIME-Version: 1.0

--//
Content-Transfer-Encoding: 7bit
Content-Type: text/x-shellscript; charset="us-ascii"
Mime-Version: 1.0

#!/bin/bash
set -x
DIR=/etc/eks/image-credential-provider
BIN=$DIR/jfrog-credential-provider

case "$(uname -m)" in
  x86_64)        SUFFIX=amd64 ;;
  aarch64|arm64) SUFFIX=arm64 ;;
  *)             SUFFIX=amd64 ;;
esac

# 1. Download the plugin binary
curl -fsSL -o "$BIN" "https://releases.jfrog.io/artifactory/run/jfrog-credentials-provider/__PROVIDER_VERSION__/jfrog-credential-provider-linux-${SUFFIX}" || { echo "download failed"; exit 1; }
chmod +x "$BIN"

# 2. Generate the JFrog provider config from environment variables
export ARTIFACTORY_URL="__ARTIFACTORY_URL__"
export AWS_AUTH_METHOD="assume_role"
export AWS_ROLE_NAME="__NODE_ROLE__"
export IAM_ROLE_ARN="__NODE_ROLE_ARN__"
export MATCH_IMAGES="__MATCH_IMAGES__"
export DEFAULT_CACHE_DURATION="__CACHE_DURATION__"
# IMPORTANT: write to jfrog-provider.json. Without --provider-config the plugin writes config.json, which is the
# kubelet's own credential provider config, and the kubelet then fails to start.
"$BIN" add-provider-config --generateConfig --provider-home "$DIR" --provider-config jfrog-provider

# 3. Merge it into the kubelet credential provider config (the original is backed up)
"$BIN" add-provider-config --provider-home "$DIR" --provider-config config

# 4. Restart the kubelet so it reads the new provider, then watch it and roll back if it is unhealthy
systemctl restart kubelet
nohup "$BIN" watch-kubelet --provider-home "$DIR" > /var/log/jfrog-watch-kubelet.log 2>&1 &
--//--
EOS
sed -i.bak \
  -e "s|__PROVIDER_VERSION__|${PROVIDER_VERSION}|g" \
  -e "s|__ARTIFACTORY_URL__|${ARTIFACTORY_URL}|g" \
  -e "s|__NODE_ROLE__|${NODE_ROLE}|g" \
  -e "s|__NODE_ROLE_ARN__|${NODE_ROLE_ARN}|g" \
  -e "s|__MATCH_IMAGES__|${MATCH_IMAGES}|g" \
  -e "s|__CACHE_DURATION__|${CACHE_DURATION}|g" \
  "$WORK/userdata.sh"
USERDATA_B64=$(base64 < "$WORK/userdata.sh" | tr -d '\n')

echo "== 2. Launch template: $LT_NAME"
cat > "$WORK/lt.json" <<EOF
{
  "MetadataOptions": { "HttpEndpoint": "enabled", "HttpTokens": "required", "HttpPutResponseHopLimit": 1 },
  "BlockDeviceMappings": [ { "DeviceName": "/dev/xvda", "Ebs": { "VolumeSize": 30, "VolumeType": "gp3", "DeleteOnTermination": true } } ],
  "SecurityGroupIds": ["${SECURITY_GROUP}"],
  "UserData": "${USERDATA_B64}",
  "TagSpecifications": [ { "ResourceType": "instance", "Tags": [ { "Key": "owner", "Value": "cecillesc" }, { "Key": "purpose", "Value": "jfrog-kubelet-credential-provider-launch-template-demo" } ] } ]
}
EOF
if aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "launch template exists: creating a new version"
  aws ec2 create-launch-template-version --launch-template-name "$LT_NAME" --launch-template-data "file://$WORK/lt.json" --region "$REGION" --query 'LaunchTemplateVersion.VersionNumber' --output text
else
  aws ec2 create-launch-template --launch-template-name "$LT_NAME" --launch-template-data "file://$WORK/lt.json" --region "$REGION" --query 'LaunchTemplate.[LaunchTemplateId,LatestVersionNumber]' --output text
fi
LT_VERSION=$(aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" --region "$REGION" --query 'LaunchTemplates[0].LatestVersionNumber' --output text)

echo "== 3. Managed node group: $NODEGROUP (1 x t3.medium, launch template version $LT_VERSION)"
# shellcheck disable=SC2086
aws eks create-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets $SUBNETS \
  --instance-types t3.medium \
  --ami-type AL2023_x86_64_STANDARD \
  --launch-template "name=${LT_NAME},version=${LT_VERSION}" \
  --scaling-config minSize=1,maxSize=2,desiredSize=1 \
  --labels demo=launch-template \
  --tags owner=cecillesc >/dev/null
aws eks wait nodegroup-active --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"

echo "== 4. Done"
kubectl get nodes -L eks.amazonaws.com/nodegroup,credentialsProviderEnabled
echo "User data used (for the record): $WORK/userdata.sh"
