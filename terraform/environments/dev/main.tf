
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }

  backend "s3" {
    bucket         = "circle-of-trust-terraform-state"
    key            = "environments/dev/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
    kms_key_id     = "arn:aws:kms:us-west-2:123456789:key/your-key-id"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = "development"
      Project     = "circle-of-trust"
      ManagedBy   = "terraform"
      CostCenter  = "engineering"
    }
  }
}

data "aws_eks_cluster" "cluster" {
  name = module.kubernetes.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.kubernetes.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

module "networking" {
  source = "../../modules/networking"

  environment        = "dev"
  region             = var.region
  vpc_cidr           = "10.1.0.0/16"
  availability_zones = ["us-west-2a", "us-west-2b"]
  enable_nat_gateway = true
  enable_flow_logs   = false

  tags = local.common_tags
}

module "kubernetes" {
  source = "../../modules/kubernetes"

  environment            = "dev"
  cluster_name           = "circle-of-trust-dev"
  cluster_version        = "1.28"
  vpc_id                 = module.networking.vpc_id
  private_subnet_ids     = module.networking.private_subnet_ids
  cluster_security_group_id = module.networking.eks_cluster_security_group_id

  node_groups = {
    general = {
      desired_size   = 1
      max_size       = 3
      min_size       = 1
      instance_types = ["t3.large"]
      capacity_type  = "SPOT"
      disk_size      = 50
      labels = {
        role = "general"
      }
      taints = []
    }
  }

  enable_cluster_autoscaler = true
  enable_metrics_server     = true
  enable_aws_load_balancer_controller = true

  tags = local.common_tags
}

module "database" {
  source = "../../modules/database"

  environment        = "dev"
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.private_subnet_ids
  security_group_id  = module.networking.rds_security_group_id

  identifier          = "circle-of-trust-dev"
  engine_version      = "15.4"
  instance_class      = "db.t3.medium"
  allocated_storage   = 20
  max_allocated_storage = 100
  storage_encrypted   = true
  multi_az            = false

  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "Mon:04:00-Mon:05:00"
  
  create_read_replica = false
  replica_count       = 0

  performance_insights_enabled = false

  tags = local.common_tags
}

module "cache" {
  source = "../../modules/cache"

  environment       = "dev"
  vpc_id            = module.networking.vpc_id
  subnet_ids        = module.networking.private_subnet_ids

  cluster_id        = "circle-of-trust-dev"
  engine_version    = "7.0"
  node_type         = "cache.t3.micro"
  num_cache_nodes   = 1
  parameter_group_family = "redis7"

  automatic_failover_enabled = false
  multi_az_enabled          = false

  tags = local.common_tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  environment    = "dev"
  cluster_name   = module.kubernetes.cluster_name
  vpc_id         = module.networking.vpc_id

  prometheus_retention_days = 7
  prometheus_storage_size   = "20Gi"

  grafana_admin_password = var.grafana_admin_password

  alertmanager_teams_webhook = var.teams_webhook_url

  tags = local.common_tags
}

module "secrets" {
  source = "../../modules/secrets"

  environment = "dev"

  secrets = {
    "circle-of-trust/dev/database-url" = {
      description = "Database connection URL"
      value       = module.database.connection_url
    }
    "circle-of-trust/dev/redis-url" = {
      description = "Redis connection URL"
      value       = module.cache.primary_endpoint
    }
    "circle-of-trust/dev/jwt-secret" = {
      description = "JWT signing secret"
      generate    = true
      length      = 32
    }
  }

  enable_rotation = false
  rotation_days   = 0

  tags = local.common_tags
}

module "storage" {
  source = "../../modules/storage"

  environment = "dev"

  buckets = {
    backups = {
      name = "circle-of-trust-dev-backups"
      versioning_enabled = false
      lifecycle_rules = [
        {
          id      = "expire-old-backups"
          enabled = true
          expiration_days = 7
          transitions = []
        }
      ]
    }
    
    logs = {
      name = "circle-of-trust-dev-logs"
      versioning_enabled = false
      lifecycle_rules = [
        {
          id      = "expire-old-logs"
          enabled = true
          expiration_days = 30
        }
      ]
    }
  }

  tags = local.common_tags
}

locals {
  common_tags = {
    Environment = "development"
    Project     = "circle-of-trust"
    ManagedBy   = "terraform"
    CostCenter  = "engineering"
    Team        = "ai-platform"
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

variable "teams_webhook_url" {
  description = "teams webhook URL for alerts"
  type        = string
  sensitive   = true
  default     = ""
}
