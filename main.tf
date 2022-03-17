# TFC Hook
# Single Vault Node
# AWS RDS DB

# Vault Configs
## Dev Mode should be fine
## Azure AD Auth Method
## AWS Dynamic Creds from Vault
### Root Creds from Doormat??
### Federated Token AND Assumed Role
## AWS RDS Dynamic Creds from Vault
### Root Creds manually input


terraform {
  cloud {
    organization = "milesjh-sandbox"

    workspaces {
      tags = ["app"]
    }
  }

  required_version = ">= 0.13.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = ">= 3.0"
    }
  }
}

provider "vault" {
  # approle

  auth_login {
    path      = "auth/approle/login"
    namespace = "admin"

    parameters = {
      role_id   = var.role_id
      secret_id = var.secret_id
    }
  }
}


data "vault_aws_access_credentials" "creds" {
  backend = "aws/"
  role    = "rds-admin-ar" # rds-admin-ft, rds-admin-user
  type    = "sts"          # creds
}

provider "aws" {
  region     = local.region
  token      = data.vault_aws_access_credentials.creds.security_token
  access_key = data.vault_aws_access_credentials.creds.access_key
  secret_key = data.vault_aws_access_credentials.creds.secret_key
}

locals {
  name   = "postgresql-demo"
  region = "us-west-2"
  tags = {
    Owner       = "user"
    Environment = "dev"
  }
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = local.name
  cidr = "10.99.0.0/18"

  azs              = ["${local.region}a", "${local.region}b", "${local.region}c"]
  public_subnets   = ["10.99.0.0/24", "10.99.1.0/24", "10.99.2.0/24"]
  private_subnets  = ["10.99.3.0/24", "10.99.4.0/24", "10.99.5.0/24"]
  database_subnets = ["10.99.7.0/24", "10.99.8.0/24", "10.99.9.0/24"]

  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  tags = local.tags
}

module "security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = local.name
  description = "Complete PostgreSQL example security group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      description = "PostgreSQL access from within VPC"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]

  tags = local.tags
}

################################################################################
# RDS Module
################################################################################

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = local.name

  # All available versions: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html#PostgreSQL.Concepts
  engine               = "postgres"
  engine_version       = "14.1"
  family               = "postgres14" # DB parameter group
  major_engine_version = "14"         # DB option group
  instance_class       = "db.t4g.large"

  allocated_storage     = 20
  max_allocated_storage = 100

  # NOTE: Do NOT use 'user' as the value for 'username' as it throws:
  # "Error creating DB Instance: InvalidParameterValue: MasterUsername
  # user cannot be used as it is a reserved word used by the engine"
  db_name  = "demo-postgresql-db"
  username = "vaultuser"
  password = "vaultpass"
  port     = 5432

  multi_az               = true
  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [module.security_group.security_group_id]

  maintenance_window              = "Mon:00:00-Mon:03:00"
  backup_window                   = "03:00-06:00"
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  create_cloudwatch_log_group     = true

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  create_monitoring_role                = true
  monitoring_interval                   = 60
  monitoring_role_name                  = "example-monitoring-role-name"
  monitoring_role_description           = "Description for monitoring role"

  parameters = [
    {
      name  = "autovacuum"
      value = 1
    },
    {
      name  = "client_encoding"
      value = "utf8"
    }
  ]

  tags = local.tags
  db_option_group_tags = {
    "Sensitive" = "low"
  }
  db_parameter_group_tags = {
    "Sensitive" = "low"
  }
}

# module "db_default" {
#   source = "terraform-aws-modules/rds/aws"

#   identifier = "${local.name}-default"

#   create_db_option_group    = false
#   create_db_parameter_group = false

#   # All available versions: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html#PostgreSQL.Concepts
#   engine               = "postgres"
#   engine_version       = "14.1"
#   family               = "postgres14" # DB parameter group
#   major_engine_version = "14"         # DB option group
#   instance_class       = "db.t4g.large"

#   allocated_storage = 20

#   # NOTE: Do NOT use 'user' as the value for 'username' as it throws:
#   # "Error creating DB Instance: InvalidParameterValue: MasterUsername
#   # user cannot be used as it is a reserved word used by the engine"
#   db_name  = "demo-postgresql-db"
#   username = "vaultuser"
#   port     = 5432

#   db_subnet_group_name   = module.vpc.database_subnet_group
#   vpc_security_group_ids = [module.security_group.security_group_id]

#   maintenance_window      = "Mon:00:00-Mon:03:00"
#   backup_window           = "03:00-06:00"
#   backup_retention_period = 0

#   tags = local.tags
# }

# module "db_disabled" {
#   source = "terraform-aws-modules/rds/aws"

#   identifier = "${local.name}-disabled"

#   create_db_instance        = false
#   create_db_parameter_group = false
#   create_db_option_group    = false
# }
