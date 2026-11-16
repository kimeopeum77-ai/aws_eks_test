# Terraform 초기구성
terraform {
  backend "s3" {
    bucket       = "myterraform-bucket-state-mooneks"
    key          = "aws_eks/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "admin_user"
    use_lockfile = true # S3 자체 잠금 (dynamodb_table 방식은 Terraform 1.11부터 deprecated)
    encrypt      = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "admin_user_tf" # aws login 프로필(admin_user)을 credential_process로 감싼 프로필
}

# Kubernetes Provider
# EKS Cluster 구성 후 초기 구성 작업을 수행하기 위한 Terraform Kubernetes Provider 설정
# 생성 된 EKS Cluster의 EndPoint 주소 및 인증정보를 모듈 Output으로 받아 Provider 설정 정보로 입력
data "aws_eks_cluster_auth" "cluster" {
  name = module.aws_eks_cluster.cluster_name
}

provider "kubernetes" {
  host                   = module.aws_eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.aws_eks_cluster.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# AWS EKS Cluster
data "aws_iam_user" "EKS_Admin_ID" {
  user_name = "admin"
}

module "aws_eks_cluster" {
  source           = "./modules/eks_cluster"
  cidr             = "192.168.0.0/16"
  public_subnets   = ["192.168.1.0/24", "192.168.2.0/24"]
  private_subnets  = ["192.168.10.0/24", "192.168.20.0/24"]
  database_subnets = ["192.168.30.0/24", "192.168.40.0/24"]
  cluster_name     = "my-eks"
  cluster_version  = "1.32"
  cluster_admin    = data.aws_iam_user.EKS_Admin_ID.user_id
}

output "vpc_id" {
  value       = module.aws_eks_cluster.vpc_id
  description = "VPC ID Output"
}

output "private_subnets" {
  value       = module.aws_eks_cluster.private_subnets_cidr_blocks
  description = "Private_Subnets_Cidr_Blocks Output"
}

output "database_subnets" {
  value       = module.aws_eks_cluster.database_subnets
  description = "Database_Subnets Output"
}

output "database_subnet_group" {
  value       = module.aws_eks_cluster.database_subnet_group
  description = "Database_Subnet_Group Output"
}

output "bastionhost_ip" {
  value       = module.aws_eks_cluster.bastionhost_ip
  description = "BastionHost IP Address Output"
}

# AWS RDS ( CI/CD에서 사용 예정 ) 

/* module "aws_eks_rds" {
  source      = "./modules/rds"
  db_port     = 3306
  db_name     = "django_db"
  db_username = "admin"
  db_password = "RDSterraform123!"
}

output "rds_instance_address" {
  value       = module.aws_eks_rds.rds_instance_address
  description = "DataBase Instance address"
}

module "ecr" {
  source                            = "terraform-aws-modules/ecr/aws"
  repository_name                   = "django"
  repository_read_write_access_arns = [data.aws_iam_user.EKS_Admin_ID.arn]
  create_lifecycle_policy           = false
  repository_image_scan_on_push     = false
  tags = {
    Terraform = "true"
  }
} */