provider "aws" {
  region = var.aws_region
}

################################################################################
# EKS Cluster — private registry module (infrastructure only, no app workloads)
################################################################################

module "eks_cluster" {
  source  = "app.terraform.io/jose-merchan/eks-cluster/aws"
  version = "0.0.4"

  # Mandatory tags
  environment = var.environment
  owner       = var.owner
  cost_center = var.cost_center
  project     = var.project

  # Cluster
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # Public endpoint — remote runner needs API server access
  endpoint_public_access       = true
  endpoint_public_access_cidrs = ["0.0.0.0/0"]
  enable_irsa                  = true
  log_retention_days           = 90

  # Node group — 3 nodes so Vault HA Raft (3 replicas) can schedule
  node_groups = {
    dev = {
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      max_size       = 5
      desired_size   = 3
      disk_size_gb   = 50
    }
  }

  # VPC — eu-central-1 has 3 AZs; using 10.1.x range to avoid collision
  availability_zones     = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  vpc_cidr               = "10.1.0.0/16"
  private_subnet_cidrs   = ["10.1.0.0/19", "10.1.32.0/19", "10.1.64.0/19"]
  public_subnet_cidrs    = ["10.1.128.0/20", "10.1.144.0/20", "10.1.160.0/20"]
  enable_internet_access = true
  single_nat_gateway     = true

  addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true, before_compute = true }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
  }
}

################################################################################
# IRSA — IAM role for the EBS CSI driver service account
################################################################################

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks_cluster.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks_cluster.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks_cluster.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name_prefix        = "${var.cluster_name}-ebs-csi-"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json

  tags = {
    Environment = var.environment
    Owner       = var.owner
    CostCenter  = var.cost_center
    Project     = var.project
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
