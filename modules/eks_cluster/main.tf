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

# =================================================================================================
# BastionHost IAM Role
#  - Bastion에서 kubectl / k9s로 EKS에 접속하려면 AWS 자격 증명이 필요합니다.
#  - 액세스 키를 인스턴스에 넣지 않고, IAM Role(Instance Profile)을 붙여 임시 자격 증명을 자동으로 받습니다.
#  - 이 Role은 아래 EKS 모듈의 access_entries에서 클러스터 관리자 권한을 받습니다.
# =================================================================================================
resource "aws_iam_role" "BastionHost_role" {
  name = "${local.cluster_name}-bastion-role"

  # EC2 인스턴스가 이 Role을 사용할 수 있도록 허용 (Trust Policy)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# aws eks update-kubeconfig 실행에 필요한 최소 권한 (이 클러스터 조회만 허용)
resource "aws_iam_role_policy" "BastionHost_eks_describe" {
  name = "eks-describe-cluster"
  role = aws_iam_role.BastionHost_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = module.eks.cluster_arn
    }]
  })
}

# EC2에 IAM Role을 붙이기 위한 Instance Profile
resource "aws_iam_instance_profile" "BastionHost_profile" {
  name = "${local.cluster_name}-bastion-profile"
  role = aws_iam_role.BastionHost_role.name
}

# BastionHost 부팅 스크립트 (user_data)
#  - 실행 로그: Bastion에서 /var/log/bastion-init.log
locals {
  bastion_user_data = <<-EOF
    #!/bin/bash
    # set -e는 쓰지 않음: 한 단계(예: k9s 다운로드)가 실패해도 나머지 단계는 계속 실행되도록
    # (예전에는 GitHub 다운로드가 한 번 끊기자 kubeconfig 등록까지 건너뛰는 문제가 있었음)
    set -uxo pipefail
    exec > /var/log/bastion-init.log 2>&1

    # 다운로드 공통 옵션: 네트워크 오류(연결 끊김 등) 시 5초 간격으로 5번 재시도
    CURL="curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 10"
    FAILED=""

    # 1) ec2-user의 kubeconfig에 EKS 클러스터 등록 (가장 중요하므로 먼저 실행)
    #    - IAM Role 자격 증명 사용, alias로 짧은 이름(${local.cluster_name}) 지정
    #    - 새로 만든 IAM Role 자격 증명이 늦게 전달될 수 있어 실패하면 15초 간격으로 최대 10번 재시도
    for i in $(seq 1 10); do
      sudo -u ec2-user aws eks update-kubeconfig --region ${local.region} --name ${local.cluster_name} --alias ${local.cluster_name} && break
      echo "update-kubeconfig 실패 ($i/10), 15초 후 재시도"; sleep 15
    done
    [ -f /home/ec2-user/.kube/config ] || FAILED="$FAILED kubeconfig"

    # 2) kubectl - 클러스터 버전(${local.cluster_version})과 같은 마이너 버전의 최신 패치를 설치
    #    (kubectl은 클러스터와 마이너 버전 ±1까지만 지원 / 체크섬이 맞을 때만 설치)
    install_kubectl() {
      KUBECTL_VERSION=$($CURL https://dl.k8s.io/release/stable-${local.cluster_version}.txt) || return 1
      $CURL -o /tmp/kubectl "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl" || return 1
      $CURL -o /tmp/kubectl.sha256 "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl.sha256" || return 1
      echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum --check || return 1
      install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    }
    install_kubectl || FAILED="$FAILED kubectl"

    # 3) k9s - GitHub 최신 릴리스 설치 (파일로 먼저 받은 뒤 압축 해제)
    install_k9s() {
      $CURL -o /tmp/k9s.tar.gz https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz || return 1
      tar -xzf /tmp/k9s.tar.gz -C /tmp k9s || return 1
      install -m 0755 /tmp/k9s /usr/local/bin/k9s
    }
    install_k9s || FAILED="$FAILED k9s"

    # 3-1) 추가 편의 도구 (모두 GitHub / 공식 배포처의 최신 릴리스)
    #    - kubectx / kubens : context / namespace 빠르게 전환 (예: kubens kube-system)
    #    - fzf  : 퍼지 검색 (Ctrl+R 명령 기록 검색, kubectx/kubens 인자 없이 실행하면 목록에서 선택)
    #    - helm : Kubernetes 패키지 매니저 (AWS Load Balancer Controller 등 설치에 사용)
    #    - stern: 여러 파드 로그를 한 번에 보기 (예: stern -n kube-system coredns)
    #    ※ $${...} / %%{...}는 Terraform이 아닌 셸 문법을 그대로 쓰기 위한 이스케이프
    gh_latest() {   # GitHub 최신 릴리스 태그(예: v0.11.0) 조회
      $CURL -I -o /dev/null -w '%%{url_effective}' "https://github.com/$1/releases/latest" | sed 's#.*/tag/##'
    }
    install_kubectx() {
      v=$(gh_latest ahmetb/kubectx) || return 1
      for t in kubectx kubens; do
        $CURL -o /tmp/$t.tar.gz "https://github.com/ahmetb/kubectx/releases/download/$v/$${t}_$${v}_linux_x86_64.tar.gz" || return 1
        tar -xzf /tmp/$t.tar.gz -C /tmp $t || return 1
        install -m 0755 /tmp/$t /usr/local/bin/$t || return 1
      done
    }
    install_fzf() {
      v=$(gh_latest junegunn/fzf) || return 1
      $CURL -o /tmp/fzf.tar.gz "https://github.com/junegunn/fzf/releases/download/$v/fzf-$${v#v}-linux_amd64.tar.gz" || return 1
      tar -xzf /tmp/fzf.tar.gz -C /tmp fzf || return 1
      install -m 0755 /tmp/fzf /usr/local/bin/fzf
    }
    install_helm() {
      HV=$($CURL https://get.helm.sh/helm-latest-version) || return 1
      $CURL -o /tmp/helm.tar.gz "https://get.helm.sh/helm-$${HV}-linux-amd64.tar.gz" || return 1
      tar -xzf /tmp/helm.tar.gz -C /tmp linux-amd64/helm || return 1
      install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
    }
    install_stern() {
      v=$(gh_latest stern/stern) || return 1
      $CURL -o /tmp/stern.tar.gz "https://github.com/stern/stern/releases/download/$v/stern_$${v#v}_linux_amd64.tar.gz" || return 1
      tar -xzf /tmp/stern.tar.gz -C /tmp stern || return 1
      install -m 0755 /tmp/stern /usr/local/bin/stern
    }
    # 3-2) EKS / 출력 편의 도구
    #    - eksctl   : EKS 관리 CLI (IRSA용 eksctl create iamserviceaccount, 노드 그룹 / 애드온 관리)
    #    - jq / yq  : JSON / YAML에서 필요한 값만 뽑기 (예: kubectl get pod -o json | jq '.items[].metadata.name')
    #    - kubecolor: kubectl 출력에 색 표시 (zsh에서 kubectl → kubecolor 별칭, 자동완성은 그대로)
    install_eksctl() {
      $CURL -o /tmp/eksctl.tar.gz https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz || return 1
      tar -xzf /tmp/eksctl.tar.gz -C /tmp eksctl || return 1
      install -m 0755 /tmp/eksctl /usr/local/bin/eksctl
    }
    install_jq_yq() {
      dnf install -y jq || return 1
      $CURL -o /tmp/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 || return 1
      install -m 0755 /tmp/yq /usr/local/bin/yq
    }
    install_kubecolor() {
      v=$(gh_latest kubecolor/kubecolor) || return 1
      $CURL -o /tmp/kubecolor.tar.gz "https://github.com/kubecolor/kubecolor/releases/download/$v/kubecolor_$${v#v}_linux_amd64.tar.gz" || return 1
      tar -xzf /tmp/kubecolor.tar.gz -C /tmp kubecolor || return 1
      install -m 0755 /tmp/kubecolor /usr/local/bin/kubecolor
    }
    install_eksctl || FAILED="$FAILED eksctl"
    install_jq_yq || FAILED="$FAILED jq/yq"
    install_kubecolor || FAILED="$FAILED kubecolor"

    install_kubectx || FAILED="$FAILED kubectx"
    install_fzf || FAILED="$FAILED fzf"
    install_helm || FAILED="$FAILED helm"
    install_stern || FAILED="$FAILED stern"

    # 4) 편의 설정 - kubectl 자동완성 + 'k' 별칭
    cat >> /home/ec2-user/.bashrc <<'BASHRC'
    source <(kubectl completion bash)
    alias k=kubectl
    complete -o default -F __start_kubectl k
    BASHRC

    # 5) zsh + oh-my-zsh + Powerlevel10k(p10k) + Kubernetes 플러그인
    #    - oh-my-zsh 플러그인
    #        kubectl : 자동완성 + k, kgp(get pods), kgs(get svc), kaf(apply -f) 같은 별칭
    #        helm    : helm 자동완성          aws : aws CLI 자동완성        git : git 별칭
    #        fzf     : Ctrl+R 명령 기록 퍼지 검색, Ctrl+T 파일 검색
    #        sudo    : ESC 두 번 → 방금 명령 앞에 sudo 붙이기
    #        z       : 자주 가는 디렉터리로 바로 이동 (예: z aws)
    #        extract : 압축 종류 상관없이 'extract 파일명'으로 풀기
    #        colored-man-pages : man 페이지 색 표시
    #        zsh-autosuggestions(이전 명령 추천 → 오른쪽 화살표로 입력), zsh-syntax-highlighting(명령 색 표시)
    #    - p10k 테마는 lean 스타일 기본 설정을 쓰고, 프롬프트 오른쪽에 현재 k8s context / namespace를 항상 표시
    #    - 설치 스크립트를 원격 실행하지 않고 git clone으로 직접 받음 (실패하면 5번 재시도)
    clone() {
      for n in 1 2 3 4 5; do
        rm -rf "$2"
        git clone --depth=1 "$1" "$2" && return 0
        echo "git clone 실패 ($n/5): $1"; sleep 5
      done
      return 1
    }
    install_zsh() {
      dnf install -y zsh git || return 1
      H=/home/ec2-user
      ZC=$H/.oh-my-zsh/custom
      clone https://github.com/ohmyzsh/ohmyzsh.git $H/.oh-my-zsh || return 1
      clone https://github.com/romkatv/powerlevel10k.git $ZC/themes/powerlevel10k || return 1
      clone https://github.com/zsh-users/zsh-autosuggestions.git $ZC/plugins/zsh-autosuggestions || return 1
      clone https://github.com/zsh-users/zsh-syntax-highlighting.git $ZC/plugins/zsh-syntax-highlighting || return 1

      # p10k 설정: lean 템플릿 사용 + kubecontext를 kubectl 입력 때만이 아니라 항상 표시
      cp $ZC/themes/powerlevel10k/config/p10k-lean.zsh $H/.p10k.zsh
      sed -i 's/^\(\s*\)\(typeset -g POWERLEVEL9K_KUBECONTEXT_SHOW_ON_COMMAND=\)/\1# \2/' $H/.p10k.zsh

      cat > $H/.zshrc <<'ZSHRC'
    # p10k 설정 마법사(p10k configure)를 자동으로 띄우지 않음 - 다시 설정하려면 'p10k configure' 실행
    POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true

    export ZSH="$HOME/.oh-my-zsh"
    ZSH_THEME="powerlevel10k/powerlevel10k"
    plugins=(git aws kubectl helm fzf sudo z extract colored-man-pages zsh-autosuggestions zsh-syntax-highlighting)
    export PATH=/usr/local/bin:$PATH

    source $ZSH/oh-my-zsh.sh
    [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

    # kubectl 출력에 색 표시 (kubecolor), 자동완성은 kubectl 것을 그대로 사용
    if command -v kubecolor >/dev/null; then
      alias kubectl=kubecolor
      compdef kubecolor=kubectl
    fi

    # eksctl 자동완성
    command -v eksctl >/dev/null && source <(eksctl completion zsh)

    # 추가 별칭
    alias kx=kubectx      # context 전환
    alias kn=kubens       # namespace 전환
    alias kgpa='kubectl get pods -A'
    alias kevents='kubectl get events -A --sort-by=.lastTimestamp'
    ZSHRC

      chown -R ec2-user:ec2-user $H/.oh-my-zsh $H/.p10k.zsh $H/.zshrc
      usermod -s /bin/zsh ec2-user   # ec2-user 기본 셸을 zsh로 변경
    }
    install_zsh || FAILED="$FAILED zsh"

    # 결과 요약 - 실패한 단계가 있으면 로그 마지막 줄에 표시되고, cloud-init도 실패로 기록됨
    if [ -n "$FAILED" ]; then echo "[실패한 단계]$FAILED"; exit 1; fi
    echo "[완료] kubeconfig / kubectl / k9s / eksctl / jq / yq / kubecolor / kubectx / fzf / helm / stern / zsh + p10k 설치 성공"
  EOF

  # NAT 인스턴스 부팅 스크립트 - IP 포워딩 + iptables MASQUERADE
  nat_user_data = <<-EOF
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
  iam_instance_profile        = aws_iam_instance_profile.BastionHost_profile.name
  # EKS 클러스터와 eks:DescribeCluster 권한이 모두 만들어진 뒤에 Bastion을 생성 (부팅 스크립트가 바로 사용하므로)
  depends_on = [module.eks, aws_iam_role_policy.BastionHost_eks_describe]

  # 부팅 시 kubectl / k9s 설치 + kubeconfig 등록 (처음 부팅할 때 한 번만 실행됨)
  #  - 실행 로그: /var/log/bastion-init.log
  #  - user_data는 처음 부팅 때만 실행되므로, 내용을 바꾸면 인스턴스를 새로 만들도록 설정 (user_data_replace_on_change)
  #  - 스크립트 내용은 아래 locals의 bastion_user_data 참고
  #  - replace(..., "\r", ""): Windows에서 파일이 CRLF로 저장돼도 Linux에서 스크립트가 실행되도록 \r 제거
  user_data_replace_on_change = true
  user_data                   = replace(local.bastion_user_data, "\r", "")

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

  # 스크립트 내용은 위 locals의 nat_user_data 참고
  # replace(..., "\r", ""): Windows에서 파일이 CRLF로 저장돼도 Linux에서 스크립트가 실행되도록 \r 제거
  user_data = replace(local.nat_user_data, "\r", "")

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

  # BastionHost IAM Role에 클러스터 관리자 권한 부여 (EKS Access Entry 방식)
  #  - 예전에는 aws-auth ConfigMap을 직접 수정했지만, 지금은 EKS API의 Access Entry로 권한을 줍니다.
  #  - 실습용이라 관리자(AmazonEKSClusterAdminPolicy)를 주며, 조회만 필요하면 AmazonEKSViewPolicy로 낮추면 됩니다.
  access_entries = {
    bastion = {
      principal_arn = aws_iam_role.BastionHost_role.arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
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