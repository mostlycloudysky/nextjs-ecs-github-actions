provider "aws" {
  region = var.region
}

# VPC & Subnets
resource "aws_default_vpc" "main_vpc" {}

resource "aws_default_subnet" "subnet_us_east_1a" {
  availability_zone = "us-east-1a"
}

resource "aws_default_subnet" "subnet_us_east_1b" {
  availability_zone = "us-east-1b"
}

resource "aws_default_subnet" "subnet_us_east_1c" {
  availability_zone = "us-east-1c"
}

# SSL Certificate
resource "aws_acm_certificate" "ssl_cert" {
  domain_name       = var.custom_domain_name
  validation_method = "DNS"
  tags = {
    Name = "cloudysky.link-cert"
  }
}

resource "aws_route53_record" "ssl_cert_validation_record" {
  zone_id = var.hosted_zone_id
  name    = tolist(aws_acm_certificate.ssl_cert.domain_validation_options)[0].resource_record_name
  type    = tolist(aws_acm_certificate.ssl_cert.domain_validation_options)[0].resource_record_type
  records = [tolist(aws_acm_certificate.ssl_cert.domain_validation_options)[0].resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "ssl_cert_validation" {
  certificate_arn         = aws_acm_certificate.ssl_cert.arn
  validation_record_fqdns = [aws_route53_record.ssl_cert_validation_record.fqdn]
}

data "aws_ecr_repository" "nextjs_repo" {
  name = "nextjs-ecr-repository"
}

# ECS Resources
resource "aws_ecs_cluster" "nextjs_cluster" {
  name = "nextjs-cluster"
}

resource "aws_ecs_task_definition" "nextjs_task" {
  family                = "nextjs-task"
  container_definitions = <<-DEFINITION
  [
    {
      "name": "nextjs-container",
      "image": "${data.aws_ecr_repository.nextjs_repo.repository_url}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "hostPort": 8080
        }
      ],
      "memory": 512,
      "cpu": 256,
      "environment": [
        {
          "name": "NEXT_PUBLIC_BASE_URL",
          "value": "https://dev-next.cloudysky.link"
        }
      ]
    }
  ]
  DEFINITION

  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  memory                   = 512
  cpu                      = 256
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
}

data "aws_iam_policy_document" "ecs_role_assumption" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution_role" {
  name               = "NextJS-ECSTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_role_assumption.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy_attach" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ALB & Security Groups
resource "aws_security_group" "alb_sg" {
  name = "ALB-SecurityGroup"
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_alb" "nextjs_alb" {
  name               = "NextJS-ALB"
  load_balancer_type = "application"
  subnets = [
    aws_default_subnet.subnet_us_east_1a.id,
    aws_default_subnet.subnet_us_east_1b.id,
    aws_default_subnet.subnet_us_east_1c.id
  ]
  security_groups = [aws_security_group.alb_sg.id]
}

resource "aws_lb_target_group" "nextjs_tg" {
  name        = "NextJS-TargetGroup"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_default_vpc.main_vpc.id
}

resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_alb.nextjs_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate_validation.ssl_cert_validation.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nextjs_tg.arn
  }
}

# Route53 Record
resource "aws_route53_record" "nextjs_domain_record" {
  zone_id = var.hosted_zone_id
  name    = var.custom_domain_name
  type    = "A"

  alias {
    name                   = aws_alb.nextjs_alb.dns_name
    zone_id                = aws_alb.nextjs_alb.zone_id
    evaluate_target_health = false
  }
}

# ECS Service
resource "aws_ecs_service" "nextjs_service" {
  name                 = "NextJS-Service"
  cluster              = aws_ecs_cluster.nextjs_cluster.id
  task_definition      = aws_ecs_task_definition.nextjs_task.arn
  launch_type          = "FARGATE"
  desired_count        = 3
  force_new_deployment = true

  load_balancer {
    target_group_arn = aws_lb_target_group.nextjs_tg.arn
    container_name   = "nextjs-container"
    container_port   = 8080
  }

  network_configuration {
    subnets          = [aws_default_subnet.subnet_us_east_1a.id, aws_default_subnet.subnet_us_east_1b.id, aws_default_subnet.subnet_us_east_1c.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs_service_sg.id]
  }
}

resource "aws_security_group" "ecs_service_sg" {
  name = "ECS-Service-SecurityGroup"
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
