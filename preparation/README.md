The script creates:
- EKS cluster
- Nodegroup in private network
- Ingress class that creates ALBs (Application Load Balancers)
- External DNS that manages hosted zones in Route 53
- Hosted zone
- Certificate request for the hosted zone

Requirements:
- AWS CLI
- kubectl
- eksctl
- helm

Steps:
- Update variables in the top of the script
- Ensure that you are logged in with AWS CLI
- Run the script
- Update nameservers in your domain provider according to the created hosted zone
- Trigger certificate validation in the certificate request