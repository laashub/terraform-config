variable "az" {}
variable "bastion_ami" {}
variable "bastion_config" {}
variable "env" {}
variable "gateway_id" {}
variable "index" {}
variable "nat_ami" {}
variable "nat_instance_type" {}
variable "nat_quay_instance_type" {}
variable "public_subnet" {}
variable "vpc_id" {}
variable "workers_org_subnet" {}
variable "workers_com_subnet" {}

resource "aws_route53_zone" "az" {
  name = "aws-us-east-${var.az}.travisci.net"

  tags {
    AvailabilityZone = "${var.az}"
  }
}

resource "aws_subnet" "public" {
  vpc_id = "${var.vpc_id}"
  cidr_block = "${var.public_subnet}"
  availability_zone = "us-east-${var.az}"
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.env}-${var.index}-public-${var.az}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = "${var.vpc_id}"

  route {
    cidr_block = "107.22.236.225/32"
    instance_id = "${aws_instance.nat_quay.id}"
  }

  route {
    cidr_block = "174.129.233.65/32"
    instance_id = "${aws_instance.nat_quay.id}"
  }

  route {
    cidr_block = "184.73.225.107/32"
    instance_id = "${aws_instance.nat_quay.id}"
  }

  route {
    cidr_block = "184.73.236.204/32"
    instance_id = "${aws_instance.nat_quay.id}"
  }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${var.gateway_id}"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id = "${aws_subnet.public.id}"
  route_table_id = "${aws_route_table.public.id}"
}

resource "aws_security_group" "nat" {
  name = "${var.env}-${var.index}-public-nat-${var.az}"
  description = "NAT Security Group for Public VPC"
  vpc_id = "${var.vpc_id}"

  ingress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["${aws_subnet.public.cidr_block}"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "nat" {
  ami = "${var.nat_ami}"
  instance_type = "${var.nat_instance_type}"
  vpc_security_group_ids = ["${aws_security_group.nat.id}"]
  subnet_id = "${aws_subnet.public.id}"
  source_dest_check = false

  tags = {
    Name = "${var.env}-${var.index}-nat-${var.az}"
  }
}

resource "aws_eip" "nat" {
  instance = "${aws_instance.nat.id}"
  vpc = true
  depends_on = ["aws_route_table.public"]
}

resource "aws_instance" "nat_quay" {
  ami = "${var.nat_ami}"
  instance_type = "${var.nat_quay_instance_type}"
  vpc_security_group_ids = ["${aws_security_group.nat.id}"]
  subnet_id = "${aws_subnet.public.id}"
  source_dest_check = false

  tags = {
    Name = "${var.env}-${var.index}-nat-quay-${var.az}"
  }
}

resource "aws_eip" "bastion" {
  instance = "${aws_instance.bastion.id}"
  vpc = true
  depends_on = ["aws_route_table.public"]
}

resource "aws_security_group" "bastion" {
  name = "${var.env}-${var.index}-bastion-${var.az}"
  description = "Security Group for bastion server for VPC"
  vpc_id = "${var.vpc_id}"

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "template_file" "bastion_cloud_init" {
  template = "${file("${path.module}/bastion-cloud-init.tpl")}"

  vars {
    bastion_config = "${var.bastion_config}"
    env = "${var.env}"
    index = "${var.index}"
  }
}

resource "aws_instance" "bastion" {
  ami = "${var.bastion_ami}"
  instance_type = "t2.micro"
  vpc_security_group_ids = ["${aws_security_group.bastion.id}"]
  subnet_id = "${aws_subnet.public.id}"
  tags = {
    Name = "${var.env}-${var.index}-bastion-${var.az}"
  }
  user_data = "${data.template_file.bastion_cloud_init.rendered}"
}

resource "aws_route53_record" "bastion" {
  zone_id = "${aws_route53_zone.az.zone_id}"
  name = "bastion.aws-us-east-${var.az}.travisci.net"
  type = "A"
  ttl = "300"
  records = ["${aws_eip.bastion.public_ip}"]
}

module "workers_org" {
  source = "./workers"

  az = "${var.az}"
  cidr_block = "${var.workers_org_subnet}"
  env = "${var.env}"
  index = "${var.index}"
  nat_quay_id = "${aws_instance.nat_quay.id}"
  nat_ami = "${var.nat_ami}"
  nat_instance_type = "${var.nat_instance_type}"
  site = "org"
  vpc_id = "${var.vpc_id}"
}

module "workers_com" {
  source = "./workers"

  az = "${var.az}"
  cidr_block = "${var.workers_com_subnet}"
  env = "${var.env}"
  index = "${var.index}"
  nat_quay_id = "${aws_instance.nat_quay.id}"
  nat_ami = "${var.nat_ami}"
  nat_instance_type = "${var.nat_instance_type}"
  site = "com"
  vpc_id = "${var.vpc_id}"
}

output "bastion_eip" { value = "${aws_eip.bastion.public_ip}" }
output "bastion_id" { value = "${aws_instance.bastion.id}" }
output "bastion_sg_id" { value = "${aws_security_group.bastion.id}" }
output "nat_eip" { value = "${aws_eip.nat.public_ip}" }
output "nat_id" { value = "${aws_instance.nat.id}" }
output "public_subnet" { value = "${aws_subnet.public.cidr_block}" }
output "workers_com_subnet" { value = "${var.workers_com_subnet}" }
output "workers_com_subnet_id" { value = "${module.workers_com.subnet_id}" }
output "workers_org_subnet" { value = "${var.workers_org_subnet}" }
output "workers_org_subnet_id" { value = "${module.workers_org.subnet_id}" }
