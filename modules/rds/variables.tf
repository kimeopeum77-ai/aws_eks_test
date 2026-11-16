locals {
  tcp_protocol = "tcp"
  any_port     = 0
  any_protocol = "-1"
  all_network  = "0.0.0.0/0"
}

variable "db_port" {
  description = "RDS DB Port"
  type        = number # 포트는 숫자이므로 string 대신 number
}

variable "db_name" {
  description = "RDS DB Name"
  type        = string
}

variable "db_username" {
  description = "RDS DB UserName"
  type        = string
}

variable "db_password" {
  description = "RDS DB Password"
  type        = string
  sensitive   = true # plan / apply 출력에 비밀번호가 그대로 찍히지 않도록 가림
}
