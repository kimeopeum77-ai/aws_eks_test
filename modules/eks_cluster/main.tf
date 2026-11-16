# 이 모듈이 쓰는 Provider와 버전 범위를 명시합니다.
# (명시하지 않으면 버전 제약 없이 최신 버전이 설치될 수 있음)
# EKS 모듈 v20이 aws provider 5.95 이상 6.0 미만을 요구하므로 같은 범위로 맞춥니다.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.95, < 6.0"
    }
  }
}

# VPC
module "vpc" {
  source           = "terraform-aws-modules/vpc/aws"
  version          = "5.1.1"
  name             = "eks_vpc"
  azs              = local.azs
  cidr             = local.cidr
  public_subnets   = local.public_subnets
  private_subnets  = local.private_subnets
  database_subnets = local.database_subnets

  # bool 값은 문자열("true")이 아닌 true / false로 작성 (문자열 bool은 Terraform 0.11 시절 문법)
  enable_dns_hostnames = true
  enable_dns_support   = true

  # AWS Load Balancer Controller가 서브넷을 찾을 때 쓰는 태그
  #  - 예전에는 아래쪽 aws_ec2_tag 리소스로 따로 붙였지만, VPC 모듈이 자기가 모르는 태그를 apply 때마다 지우려고 해서
  #    서브넷이 매번 "변경됨"으로 나오고, 그 여파로 NAT 경로(aws_route)까지 재생성되는 문제가 있었습니다.
  #  - VPC 모듈의 public_subnet_tags / private_subnet_tags로 넣으면 한 곳에서만 관리되어 충돌이 없습니다.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1" # internet-facing 로드밸런서용
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1" # internal 로드밸런서용
  }

  tags = {
    "TerraformManaged" = "true"
  }
}

# Security-Group (BastionHost)
module "BastionHost_SG" {
  source          = "terraform-aws-modules/security-group/aws"
  version         = "5.1.0"
  name            = "BastionHost_SG"
  description     = "BastionHost_SG"
  vpc_id          = module.vpc.vpc_id
  use_name_prefix = false

  ingress_with_cidr_blocks = [
    {
      from_port   = local.ssh_port
      to_port     = local.ssh_port
      protocol    = local.tcp_protocol
      description = "SSH"
      cidr_blocks = local.all_network
    },
    {
      from_port   = local.any_protocol
      to_port     = local.any_protocol
      protocol    = local.icmp_protocol
      description = "ICMP"
      cidr_blocks = local.cidr
    }
  ]
  egress_with_cidr_blocks = [
    {
      from_port   = local.any_port
      to_port     = local.any_port
      protocol    = local.any_protocol
      cidr_blocks = local.all_network
    }
  ]
}

# BastionHost EIP
resource "aws_eip" "BastionHost_eip" {
  instance = aws_instance.BastionHost.id
  tags = {
    Name = "BastionHost_EIP"
  }
}

# 최신 Amazon Linux 2023 AMI ID (AWS가 SSM Parameter로 제공하는 공식 값)
#  - AMI ID를 직접 적으면 시간이 지나 AMI가 deprecated / 삭제될 때 apply가 실패하므로 항상 최신 값을 조회합니다.
#  - AMI ID는 비밀 값이 아니므로 insecure_value 사용 (value를 쓰면 plan에 (sensitive value)로 가려짐)
#  - 확인 명령: aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# BastionHost Key-Pair DataSource
data "aws_key_pair" "EC2-Key" {
  key_name = "EC2-Key"
}

# BastionHost Instance
# EKS Cluster SG : module.eks.cluster_primary_security_group_id
#  - 예전에는 data "aws_eks_cluster"로 다시 조회했지만, EKS 모듈이 같은 값을 Output으로 주므로 바로 참조합니다.
#  - data source + depends_on 조합은 plan 단계에서 값을 못 읽고 apply 때로 미뤄지는 문제가 있습니다.
resource "aws_instance" "BastionHost" {
  ami                         = data.aws_ssm_parameter.al2023_ami.insecure_value
  instance_type               = "t3.medium"
  key_name                    = data.aws_key_pair.EC2-Key.key_name
  subnet_id                   = module.vpc.public_subnets[1]
  associate_public_ip_address = true
  vpc_security_group_ids      = [module.BastionHost_SG.security_group_id, module.eks.cluster_primary_security_group_id]
  depends_on                  = [module.eks]
  tags = {
    Name = "BastionHost_Instance"
  }

  # 새 AMI가 나올 때마다 인스턴스가 재생성되지 않도록 AMI 변경은 무시
  lifecycle {
    ignore_changes = [ami]
  }
}

# Security-Group (NAT-Instance)
module "NAT_SG" {
  source          = "terraform-aws-modules/security-group/aws"
  version         = "5.1.0"
  name            = "NAT_SG"
  description     = "All Traffic"
  vpc_id          = module.vpc.vpc_id
  use_name_prefix = false

  ingress_with_cidr_blocks = [
    {
      from_port   = local.any_port
      to_port     = local.any_port
      protocol    = local.any_protocol
      cidr_blocks = local.private_subnets[0]
    },
    {
      from_port   = local.any_port
      to_port     = local.any_port
      protocol    = local.any_protocol
      cidr_blocks = local.private_subnets[1]
    }
  ]
  egress_with_cidr_blocks = [
    {
      from_port   = local.any_port
      to_port     = local.any_port
      protocol    = local.any_protocol
      cidr_blocks = local.all_network
    }
  ]
}

# NAT Instance ENI(Elastic Network Interface)
resource "aws_network_interface" "NAT_ENI" {
  subnet_id         = module.vpc.public_subnets[0]
  private_ips       = ["192.168.1.50"]
  security_groups   = [module.NAT_SG.security_group_id]
  source_dest_check = false

  tags = {
    Name = "NAT_Instance_ENI"
  }
}

# NAT Instance
#  - 예전 NAT 전용 AMI(amzn-ami-vpc-nat, Amazon Linux 1)는 2023-11에 deprecated 되어 더 이상 쓸 수 없습니다.
#  - 대신 Amazon Linux 2023 AMI를 쓰고, 부팅 시 user_data로 NAT 기능(IP 포워딩 + iptables MASQUERADE)을 켭니다.
#  - NAT가 동작하려면 ENI의 source_dest_check = false 설정도 필요합니다 (위 NAT_ENI에 설정되어 있음).
resource "aws_instance" "NAT_Instance" {
  ami           = data.aws_ssm_parameter.al2023_ami.insecure_value
  instance_type = "t2.micro"
  depends_on    = [aws_network_interface.NAT_ENI]

  network_interface {
    network_interface_id = aws_network_interface.NAT_ENI.id
    device_index         = 0
  }

  user_data = <<-EOF
    #!/bin/bash
    # 1) 커널 IP 포워딩 활성화 (재부팅 후에도 유지)
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/90-nat.conf
    sysctl -p /etc/sysctl.d/90-nat.conf

    # 2) iptables 설치 - EIP가 붙기 전에는 인터넷이 안 되므로 성공할 때까지 재시도
    until dnf install -y iptables-services; do sleep 10; done

    # 3) VPC 대역(${local.cidr})에서 나가는 트래픽을 NAT 인스턴스 IP로 변환(MASQUERADE)
    IFACE=$(ip route show default | awk '{print $5}' | head -n1)
    iptables -t nat -A POSTROUTING -o "$IFACE" -s ${local.cidr} -j MASQUERADE
    iptables -F FORWARD

    # 4) 규칙 저장 후 iptables 서비스 활성화 (재부팅 후에도 규칙 유지)
    service iptables save
    systemctl enable --now iptables
  EOF

  tags = {
    Name = "NAT_Instance"
  }

  # 새 AMI가 나올 때마다 인스턴스가 재생성되지 않도록 AMI 변경은 무시
  lifecycle {
    ignore_changes = [ami]
  }
}

# NAT Instance ENI EIP
resource "aws_eip" "NAT_Instance_eip" {
  network_interface = aws_network_interface.NAT_ENI.id
  tags = {
    Name = "NAT_EIP"
  }
  depends_on = [aws_network_interface.NAT_ENI, aws_instance.NAT_Instance]
}

# Private Subnet Routing Table ( dest: NAT Instance ENI )
#  - 예전에는 data "aws_route_table" + depends_on = [module.vpc]로 서브넷의 라우팅 테이블을 조회했지만,
#    VPC에 아주 작은 변경만 있어도 조회가 apply 때로 미뤄져 아래 NAT 경로가 "삭제 후 재생성"되는 문제가 있었습니다.
#    (경로가 지워진 순간 private 서브넷의 노드가 인터넷에 못 나감)
#  - VPC 모듈이 private 서브넷마다 라우팅 테이블을 하나씩 만들고 같은 순서로 연결하므로,
#    모듈 Output(private_route_table_ids)을 바로 씁니다. [0] → private 서브넷 1, [1] → private 서브넷 2
resource "aws_route" "private_subnet_1" {
  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.NAT_ENI.id
  depends_on             = [module.vpc, aws_instance.NAT_Instance]
}

resource "aws_route" "private_subnet_2" {
  route_table_id         = module.vpc.private_route_table_ids[1]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.NAT_ENI.id
  depends_on             = [module.vpc, aws_instance.NAT_Instance]
}

# =================================================================================================
# =================================================================================================
# =================================================================================================

# Kubernetes Provider는 루트 main.tf로 옮겼습니다 (모듈 안에는 provider 블록을 두지 않음).
#  - 모듈 안에 provider가 있으면 이 모듈을 호출할 때 count / for_each / depends_on을 쓸 수 없고,
#    모듈을 삭제(destroy)할 때 provider 설정이 먼저 사라져 오류가 나기 쉽습니다.
# 루트에서 쓸 EKS 접속 정보는 outputs.tf의 cluster_name / cluster_endpoint / cluster_certificate_authority_data로 내보냅니다.
# (예전 문법 참고: certificate_authority.0.data → 지금은 [0] 인덱스 문법 사용)

# Terraform EKS Module DOCS : https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  # EKS Cluster Setting
  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  # OIDC(OpenID Connect) 구성 
  enable_irsa = true

  # EKS Worker Node 정의 ( ManagedNode방식 / Launch Template 자동 구성 )
  eks_managed_node_groups = {
    EKS_Worker_Node = {
      # Kubernetes 1.33부터 Amazon Linux 2(AL2) AMI가 없으므로 AL2023 AMI를 지정
      # (EKS 모듈 v20의 기본값은 AL2_x86_64라서 지정하지 않으면 노드 그룹 생성이 실패함)
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.small"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }

  # public-subnet(bastion)과 API와 통신하기 위해 설정(443)
  cluster_endpoint_public_access = true

  # K8s ConfigMap Object "aws_auth" 구성
  enable_cluster_creator_admin_permissions = true
}

# 서브넷 태그(AWS Load Balancer Controller용)는 위 VPC 모듈의 public_subnet_tags / private_subnet_tags로 옮겼습니다.
# 예전 aws_ec2_tag 리소스는 Terraform 관리 대상에서만 빼고, 실제 서브넷의 태그는 지우지 않습니다 (destroy = false).
# 이미 apply된 환경에서 한 번 적용된 뒤에는 이 removed 블록을 지워도 됩니다.
removed {
  from = aws_ec2_tag.private_subnet_tag
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_ec2_tag.public_subnet_tag
  lifecycle {
    destroy = false
  }
}