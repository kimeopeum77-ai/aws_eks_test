output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "VPC ID Output"
}

output "private_subnets_cidr_blocks" {
  value       = module.vpc.private_subnets_cidr_blocks
  description = "Private_Subnets_Cidr_Blocks Output"
}

output "database_subnets" {
  value       = module.vpc.database_subnets
  description = "Database_Subnets Output"
}

output "database_subnet_group" {
  value       = module.vpc.database_subnet_group
  description = "Database_Subnet_Group Output"
}

# 루트 main.tf의 Kubernetes Provider 설정에 쓰는 EKS 접속 정보 (endpoint / CA / 이름)
output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS Cluster Name Output"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "EKS Cluster API Endpoint Output"
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "EKS Cluster CA (base64) Output"
}

output "bastionhost_ip" {
  value       = aws_eip.BastionHost_eip.public_ip
  description = "BastionHost IP Address Output"
}