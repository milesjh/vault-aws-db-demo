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
    hcp = {
      source  = "hashicorp/hcp"
      version = ">= 0.24.0"
    }
  }
}

locals {
  name   = "postgresqldemo"
  region = "us-west-2"
  tags = {
    Owner       = "user"
    Environment = "dev"
  }
}

provider "hcp" {
  client_id     = var.hcp_client_id
  client_secret = var.hcp_client_secret
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

resource "hcp_hvn" "demo" {
  hvn_id         = "demo-hvn"
  cloud_provider = "aws"
  region         = "us-west-2"
  cidr_block     = "172.25.16.0/20"
}

resource "hcp_vault_cluster" "demo" {
  cluster_id      = "vault-cluster-demo"
  hvn_id          = hcp_hvn.demo.hvn_id
  tier            = "starter_small"
  public_endpoint = true
  lifecycle {
    prevent_destroy = true
  }
}

resource "hcp_vault_cluster_admin_token" "demo" {
  cluster_id = hcp_vault_cluster.demo.cluster_id
}

resource "hcp_aws_network_peering" "demo" {
  peering_id      = "peer-demo"
  hvn_id          = hcp_hvn.demo.hvn_id
  peer_vpc_id     = module.vpc.vpc_id
  peer_account_id = module.vpc.vpc_owner_id
  peer_vpc_region = local.region
}

// This data source is the same as the resource above, but waits for the connection to be Active before returning.
data "hcp_aws_network_peering" "demo" {
  hvn_id                = hcp_hvn.demo.hvn_id
  peering_id            = hcp_aws_network_peering.demo.peering_id
  wait_for_active_state = true
}

// Accept the VPC peering within your AWS account.
resource "aws_vpc_peering_connection_accepter" "peer" {
  vpc_peering_connection_id = hcp_aws_network_peering.demo.provider_peering_id
  auto_accept               = true
}

// Create an HVN route that targets your HCP network peering and matches your AWS VPC's CIDR block.
// The route depends on the data source, rather than the resource, to ensure the peering is in an Active state.
resource "hcp_hvn_route" "demo" {
  hvn_link         = hcp_hvn.demo.self_link
  hvn_route_id     = "peering-route"
  destination_cidr = module.vpc.vpc_cidr_block
  target_link      = data.hcp_aws_network_peering.demo.self_link
}


################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name                 = local.name
  cidr                 = "10.99.0.0/18"
  enable_dns_hostnames = true
  enable_dns_support   = true


  azs              = ["${local.region}a", "${local.region}b", "${local.region}c"]
  public_subnets   = ["10.99.0.0/24", "10.99.1.0/24", "10.99.2.0/24"]
  private_subnets  = ["10.99.3.0/24", "10.99.4.0/24", "10.99.5.0/24"]
  database_subnets = ["10.99.7.0/24", "10.99.8.0/24", "10.99.9.0/24"]

  manage_default_route_table = true
  default_route_table_name   = "default-vpc-rt"
  default_route_table_routes = [
    {
      cidr_block                = hcp_hvn.demo.cidr_block
      vpc_peering_connection_id = hcp_aws_network_peering.demo.provider_peering_id
    }
  ]

  create_database_subnet_group       = true
  create_database_subnet_route_table = false

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
      cidr_blocks = join(",", flatten([module.vpc.vpc_cidr_block, hcp_hvn.demo.cidr_block]))
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
  instance_class       = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100

  # NOTE: Do NOT use 'user' as the value for 'username' as it throws:
  # "Error creating DB Instance: InvalidParameterValue: MasterUsername
  # user cannot be used as it is a reserved word used by the engine"
  db_name             = "demopostgresqldb"
  username            = "vaultuser"
  port                = 5432
  publicly_accessible = false

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