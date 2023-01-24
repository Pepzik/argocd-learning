#!/bin/bash -x

##### Variables #####

CLUSTER_NAME="my-cluster"
CLUSTER_REGION="us-west-2"

KEY_PAIR_NAME="$CLUSTER_NAME-key-pair"

NODE_GROUP_NAME="ng-1"
NODE_GROUP_NODE_TYPE="t3.medium"
NODE_GROUP_NODES_NUMBER_DESIRED="2"
NODE_GROUP_NODES_NUMBER_MIN="2"
NODE_GROUP_NODES_NUMBER_MAX="4"
NODE_GROUP_VOLUME_TYPE="gp2"
NODE_GROUP_VOLUME_SIZE="20"

AWS_REGION_IMAGE_REPOSITORY="602401143452.dkr.ecr.us-west-2.amazonaws.com/amazon/aws-load-balancer-controller"

DOMAIN_NAME="kklonow.xyz"

##### Commands #####

# Create empty cluster
eksctl create cluster \
  --name=$CLUSTER_NAME \
  --region=$CLUSTER_REGION \
  --without-nodegroup

# Create key pair
aws ec2 create-key-pair \
  --key-name $KEY_PAIR_NAME

# Create nodegroup
eksctl create nodegroup \
  --cluster=$CLUSTER_NAME \
  --region=$CLUSTER_REGION \
  --name=$NODE_GROUP_NAME \
  --node-type=$NODE_GROUP_NODE_TYPE \
  --nodes=$NODE_GROUP_NODES_NUMBER_DESIRED \
  --nodes-min=$NODE_GROUP_NODES_NUMBER_MIN \
  --nodes-max=$NODE_GROUP_NODES_NUMBER_MAX \
  --node-volume-type $NODE_GROUP_VOLUME_TYPE \
  --node-volume-size=$NODE_GROUP_VOLUME_SIZE \
  --ssh-access \
  --ssh-public-key=$KEY_PAIR_NAME \
  --asg-access \
  --external-dns-access \
  --full-ecr-access \
  --appmesh-access \
  --alb-ingress-access \
  --node-private-networking

# Get created cluster security group
CLUSTER_SG=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=eks-cluster* \
  --query "SecurityGroups[*].[GroupId]" \
  --output text)

# Get my IP address
MY_IP_ADDRESS=$(curl 'https://api.ipify.org')

# Allow full access for my IP address
aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG \
  --protocol -1 \
  --port -1 \
  --cidr $MY_IP_ADDRESS/32

# Create IAM OIDC provider to use AWS IAM
eksctl utils associate-iam-oidc-provider \
  --region $CLUSTER_REGION \
  --cluster $CLUSTER_NAME \
  --approve

# Download IAM policy for ALB controller
curl https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json \
  > iam_policy_latest.json

# Create policy for ALB controller
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy_latest.json

# Get ARN of the create policy
POLICY_ARN=$(aws iam list-policies \
  --query "Policies[*].[Arn]" \
  --output text \
  | grep AWSLoadBalancerControllerIAMPolicy)

# Create service account for ALB controller
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=$POLICY_ARN \
  --override-existing-serviceaccounts \
  --approve

# Add eks-charts repository to helm
helm repo add eks https://aws.github.io/eks-charts

# Update helm repositories
helm repo update

# Get VPC ID of the cluster VPC
CLUSTER_VPC=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=eks-cluster* \
  --query "SecurityGroups[*].[VpcId]" \
  --output text)

# Add ALB controller for the cluster with use of helm
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$CLUSTER_REGION \
  --set vpcId=$CLUSTER_VPC \
  --set image.repository=$AWS_REGION_IMAGE_REPOSITORY

# Create policy for External DNS
aws iam create-policy \
  --policy-name AllowExternalDNSUpdates \
  --policy-document \
'{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}'

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# Create service account for external DNS
eksctl create iamserviceaccount \
  --name external-dns \
  --namespace default \
  --cluster $CLUSTER_NAME \
  --approve \
  --override-existing-serviceaccounts \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AllowExternalDNSUpdates

# Create external yaml with external DNS configuration
cat > external-dns.yaml << EOL
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-dns
rules:
- apiGroups: [""]
  resources: ["services","endpoints","pods"]
  verbs: ["get","watch","list"]
- apiGroups: ["extensions","networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get","watch","list"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-dns-viewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-dns
subjects:
- kind: ServiceAccount
  name: external-dns
  namespace: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
spec:
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: external-dns
  template:
    metadata:
      labels:
        app: external-dns   
    spec:
      serviceAccountName: external-dns
      containers:
      - name: external-dns
        image: k8s.gcr.io/external-dns/external-dns:v0.10.2
        args:
        - --source=service
        - --source=ingress
        - --provider=aws
        - --aws-zone-type=public # only look at public hosted zones (valid values are public, private or no value for both)
        - --registry=txt
        - --txt-owner-id=my-hostedzone-identifier
      securityContext:
        fsGroup: 65534 # For ExternalDNS to be able to read Kubernetes and AWS token files
EOL

# Create external DNS
kubectl apply -f external-dns.yaml

# Create hosted zone for own domain
aws route53 create-hosted-zone --name $DOMAIN_NAME --caller-reference "hosted-zone-from-script"

# Request certificate for the domain
aws acm request-certificate --domain-name $DOMAIN_NAME --subject-alternative-names *.$DOMAIN_NAME --validation-method DNS