
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
    key            = "environments/production/terraform.tfstate"
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
      Environment = "production"
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

  environment        = "production"
  region             = var.region
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = ["us-west-2a", "us-west-2b", "us-west-2c"]
  enable_nat_gateway = true
  enable_flow_logs   = true

  tags = local.common_tags
}

module "kubernetes" {
  source = "../../modules/kubernetes"

  environment            = "production"
  cluster_name           = "circle-of-trust-prod"
  cluster_version        = "1.28"
  vpc_id                 = module.networking.vpc_id
  private_subnet_ids     = module.networking.private_subnet_ids
  cluster_security_group_id = module.networking.eks_cluster_security_group_id

  node_groups = {
    general = {
      desired_size   = 3
      max_size       = 10
      min_size       = 3
      instance_types = ["c5.xlarge"]
      capacity_type  = "ON_DEMAND"
      disk_size      = 100
      labels = {
        role = "general"
      }
      taints = []
    }
    
    llm = {
      desired_size   = 2
      max_size       = 5
      min_size       = 2
      instance_types = ["g4dn.xlarge"]
      capacity_type  = "ON_DEMAND"
      disk_size      = 200
      labels = {
        role = "llm"
        gpu  = "true"
      }
      taints = [
        {
          key    = "gpu"
          value  = "true"
          effect = "NoSchedule"
        }
      ]
    }
  }

  enable_cluster_autoscaler = true
  enable_metrics_server     = true
  enable_aws_load_balancer_controller = true

  tags = local.common_tags
}

module "database" {
  source = "../../modules/database"

  environment        = "production"
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.private_subnet_ids
  security_group_id  = module.networking.rds_security_group_id

  identifier          = "circle-of-trust-prod"
  engine_version      = "15.4"
  instance_class      = "db.r5.large"
  allocated_storage   = 100
  max_allocated_storage = 500
  storage_encrypted   = true
  multi_az            = true

  backup_retention_period = 30
  backup_window          = "03:00-04:00"
  maintenance_window     = "Mon:04:00-Mon:05:00"
  
  create_read_replica = true
  replica_count       = 2

  performance_insights_enabled = true

  tags = local.common_tags
}

module "cache" {
  source = "../../modules/cache"

  environment       = "production"
  vpc_id            = module.networking.vpc_id
  subnet_ids        = module.networking.private_subnet_ids

  cluster_id        = "circle-of-trust-prod"
  engine_version    = "7.0"
  node_type         = "cache.r5.large"
  num_cache_nodes   = 2
  parameter_group_family = "redis7"

  automatic_failover_enabled = true
  multi_az_enabled          = true

  tags = local.common_tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  environment    = "production"
  cluster_name   = module.kubernetes.cluster_name
  vpc_id         = module.networking.vpc_id

  prometheus_retention_days = 30
  prometheus_storage_size   = "100Gi"

  grafana_admin_password = var.grafana_admin_password

  alertmanager_Teams_webhook = var.Teams_webhook_url

  tags = local.common_tags
}

module "secrets" {
  source = "../../modules/secrets"

  environment = "production"

  secrets = {
    "circle-of-trust/prod/database-url" = {
      description = "Database connection URL"
      value       = module.database.connection_url
    }
    "circle-of-trust/prod/redis-url" = {
      description = "Redis connection URL"
      value       = module.cache.primary_endpoint
    }
    "circle-of-trust/prod/jwt-secret" = {
      description = "JWT signing secret"
      generate    = true
      length      = 64
    }
  }

  enable_rotation = true
  rotation_days   = 90

  tags = local.common_tags
}

module "storage" {
  source = "../../modules/storage"

  environment = "production"

  buckets = {
    backups = {
      name = "circle-of-trust-prod-backups"
      versioning_enabled = true
      lifecycle_rules = [
        {
          id      = "expire-old-backups"
          enabled = true
          expiration_days = 90
          transitions = [
            {
              days          = 30
              storage_class = "GLACIER"
            }
          ]
        }
      ]
    }
    
    logs = {
      name = "circle-of-trust-prod-logs"
      versioning_enabled = false
      lifecycle_rules = [
        {
          id      = "expire-old-logs"
          enabled = true
          expiration_days = 365
        }
      ]
    }
  }

  tags = local.common_tags
}

locals {
  common_tags = {
    Environment = "production"
    Project     = "circle-of-trust"
    ManagedBy   = "terraform"
    CostCenter  = "engineering"
    Team        = "ai-platform"
  }
}
