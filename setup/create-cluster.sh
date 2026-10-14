#!/usr/bin/env bash
# Create the EKS cluster for the JFrog kubelet credential provider demo with the AWS CLI instead of eksctl.
#
# Why: the Support_PowerUsers role is explicitly denied ec2:CreateVpc, ec2:CreateInternetGateway and
# ec2:AuthorizeSecurityGroupIngress, so eksctl's CloudFormation stacks fail. The EKS service creates the
# cluster security group itself, so the direct EKS API calls below avoid those denied actions.
#
# Run:  bash setup/create-cluster.sh
set -euo pipefail

REGION=ap-south-1
CLUSTER=cecillesc-cluster
NODEGROUP=csc-ng01
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Shared cluster role that already exists in the account (used by petera-cluster).
CLUSTER_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/AmazonEKSAutoClusterRole"

# Your own node role. One IAM role can be bound to only one Artifactory user.
NODE_ROLE=cecillesc-eks-node-role

# Shared cs-mumbai-vpc (vpc-035c32a7304fca214): 2 public + 2 private subnets.
CLUSTER_SUBNETS=subnet-0ea76df9f0c88b7ac,subnet-0b6fa8588710b0432,subnet-0e0329cae30241be1,subnet-0dd649a1593a7fdd5
NODE_SUBNETS="subnet-0e0329cae30241be1 subnet-0dd649a1593a7fdd5"   # private subnets, outbound via NAT

echo "== 1. Node IAM role: $NODE_ROLE"
if aws iam get-role --role-name "$NODE_ROLE" >/dev/null 2>&1; then
  echo "role exists, reusing"
else
  aws iam create-role --role-name "$NODE_ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags Key=owner,Value=cecillesc >/dev/null
  for p in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly; do
    aws iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn "arn:aws:iam::aws:policy/$p"
  done
  echo "waiting 20s for IAM to propagate"; sleep 20
fi
NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE" --query Role.Arn --output text)
echo "node role ARN: $NODE_ROLE_ARN"

echo "== 2. EKS cluster: $CLUSTER (about 10 minutes)"
aws eks create-cluster --region "$REGION" --name "$CLUSTER" \
  --kubernetes-version 1.34 \
  --role-arn "$CLUSTER_ROLE_ARN" \
  --resources-vpc-config "subnetIds=${CLUSTER_SUBNETS},endpointPublicAccess=true,endpointPrivateAccess=false" \
  --access-config authenticationMode=API_AND_CONFIG_MAP \
  --tags owner=cecillesc,purpose=jfrog-kubelet-credential-provider-demo >/dev/null
aws eks wait cluster-active --region "$REGION" --name "$CLUSTER"

echo "== 3. Add-ons: vpc-cni, kube-proxy, coredns"
for a in vpc-cni kube-proxy coredns; do
  aws eks create-addon --region "$REGION" --cluster-name "$CLUSTER" --addon-name "$a" >/dev/null
done
aws eks wait addon-active --region "$REGION" --cluster-name "$CLUSTER" --addon-name vpc-cni
aws eks wait addon-active --region "$REGION" --cluster-name "$CLUSTER" --addon-name kube-proxy

echo "== 4. Managed node group: $NODEGROUP (2 x t3.medium, label credentialsProviderEnabled=true)"
# shellcheck disable=SC2086
aws eks create-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets $NODE_SUBNETS \
  --instance-types t3.medium \
  --ami-type AL2023_x86_64_STANDARD \
  --disk-size 30 \
  --scaling-config minSize=1,maxSize=2,desiredSize=2 \
  --labels credentialsProviderEnabled=true \
  --tags owner=cecillesc >/dev/null
aws eks wait nodegroup-active --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"
aws eks wait addon-active --region "$REGION" --cluster-name "$CLUSTER" --addon-name coredns

echo "== 5. kubeconfig"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo
echo "Done. Node role (use in the Helm values as aws_role_name, name only): $NODE_ROLE"
echo "Node role ARN (use in the Artifactory binding): $NODE_ROLE_ARN"
kubectl get nodes --show-labels
