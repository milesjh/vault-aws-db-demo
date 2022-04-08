# Env Var Setup
## !!!! Regen Vault Token before demo!!!
export VAULT_TOKEN="REPLACEME"
export VAULT_ADDR="https://REPLACEME.aws.hashicorp.cloud:8200"
export VAULT_NAMESPACE="admin"

# Enable AppRole Auth Method
vault auth list

vault auth enable approle
vault write auth/approle/role/vault-aws-db-demo \
    secret_id_ttl=1000m \
    token_num_uses=0 \
    token_ttl=20m \
    token_max_ttl=90m \
    secret_id_num_uses=40

vault auth list

# Read AppRole ID & Secret
vault read auth/approle/role/vault-aws-db-demo/role-id
vault write -f auth/approle/role/vault-aws-db-demo/secret-id
## !!! Write these to TFC Workspace and GitHub Actions Variables !!!
#### var.role_id, var.secret_id
#### roleId, secretId

# # Login with AppRole
# vault write auth/approle/login \
#     role_id=REPLACEME \
#     secret_id=REPLACEM

# Enable AWS Secrets Engine
vault secrets enable -path=aws aws

vault write aws/config/root \
    access_key=REPLACE_ACCESS_KEY \
    secret_key=REPLACE_SECRET_KEY \
    region=us-west-2

# Create Role: IAM User
vault write aws/roles/rds-admin-user \
    credential_type=iam_user \
    policy_document=-<<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "rds:*",
                "application-autoscaling:DeleteScalingPolicy",
                "application-autoscaling:DeregisterScalableTarget",
                "application-autoscaling:DescribeScalableTargets",
                "application-autoscaling:DescribeScalingActivities",
                "application-autoscaling:DescribeScalingPolicies",
                "application-autoscaling:PutScalingPolicy",
                "application-autoscaling:RegisterScalableTarget",
                "cloudwatch:DescribeAlarms",
                "cloudwatch:GetMetricStatistics",
                "cloudwatch:PutMetricAlarm",
                "cloudwatch:DeleteAlarms",
                "ec2:DescribeAccountAttributes",
                "ec2:DescribeAvailabilityZones",
                "ec2:DescribeCoipPools",
                "ec2:DescribeInternetGateways",
                "ec2:DescribeLocalGatewayRouteTablePermissions",
                "ec2:DescribeLocalGatewayRouteTables",
                "ec2:DescribeLocalGatewayRouteTableVpcAssociations",
                "ec2:DescribeLocalGateways",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSubnets",
                "ec2:DescribeVpcAttribute",
                "ec2:DescribeVpcs",
                "ec2:GetCoipPoolUsage",
                "sns:ListSubscriptions",
                "sns:ListTopics",
                "sns:Publish",
                "logs:DescribeLogStreams",
                "logs:GetLogEvents",
                "outposts:GetOutpostInstanceTypes",
                "iam:GetUser"
            ],
            "Effect": "Allow",
            "Resource": "*"
        },
        {
            "Action": "pi:*",
            "Effect": "Allow",
            "Resource": "arn:aws:pi:*:*:metrics/rds/*"
        },
        {
            "Action": "iam:CreateServiceLinkedRole",
            "Effect": "Allow",
            "Resource": "*",
            "Condition": {
                "StringLike": {
                    "iam:AWSServiceName": [
                        "rds.amazonaws.com",
                        "rds.application-autoscaling.amazonaws.com"
                    ]
                }
            }
        }
    ]
}
EOF

# Obtain IAM User Creds
vault read aws/creds/rds-admin-user

# Create Role: STS Federation Tokens
vault write aws/roles/rds-admin-ft \
    credential_type=federation_token \
    policy_document=-<<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "rds:*",
                "application-autoscaling:DeleteScalingPolicy",
                "application-autoscaling:DeregisterScalableTarget",
                "application-autoscaling:DescribeScalableTargets",
                "application-autoscaling:DescribeScalingActivities",
                "application-autoscaling:DescribeScalingPolicies",
                "application-autoscaling:PutScalingPolicy",
                "application-autoscaling:RegisterScalableTarget",
                "cloudwatch:DescribeAlarms",
                "cloudwatch:GetMetricStatistics",
                "cloudwatch:PutMetricAlarm",
                "cloudwatch:DeleteAlarms",
                "ec2:DescribeAccountAttributes",
                "ec2:DescribeAvailabilityZones",
                "ec2:DescribeCoipPools",
                "ec2:DescribeInternetGateways",
                "ec2:DescribeLocalGatewayRouteTablePermissions",
                "ec2:DescribeLocalGatewayRouteTables",
                "ec2:DescribeLocalGatewayRouteTableVpcAssociations",
                "ec2:DescribeLocalGateways",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSubnets",
                "ec2:DescribeVpcAttribute",
                "ec2:DescribeVpcs",
                "ec2:GetCoipPoolUsage",
                "sns:ListSubscriptions",
                "sns:ListTopics",
                "sns:Publish",
                "logs:DescribeLogStreams",
                "logs:GetLogEvents",
                "outposts:GetOutpostInstanceTypes",
                "iam:GetUser"
            ],
            "Effect": "Allow",
            "Resource": "*"
        }
    ]
}
EOF

# Obtain Federated Token Creds
vault write aws/sts/rds-admin-ft ttl=60m

# Create Role: STS AssumeRole
vault write aws/roles/rds-admin-ar \
    role_arns=arn:aws:iam::ACCTNUM:role/vault-demo-rds \
    credential_type=assumed_role

# Obtain AssumeRole Creds
vault write aws/sts/rds-admin-ar ttl=60m

# Create Policy mapping AppRole to AWS Secrets Engine & PGSQL
vault policy write vault-aws-db-demo -<<EOF
path "auth/token/create" {
  capabilities=["update"]
}
path "aws/*" {
  capabilities = ["create", "update", "read", "delete"]
}

path "database/*" {
  capabilities = ["create", "update", "read", "delete"]
}
EOF

vault write auth/approle/role/vault-aws-db-demo \
    policies="vault-aws-db-demo"


#### RUN TF ####

# Enable PostgreSQL Secrets Engine
vault secrets enable database
vault write database/config/demopostgresqldb \
    plugin_name="postgresql-database-plugin" \
    allowed_roles="postgresql-admin" \
    connection_url="postgresql://{{username}}:{{password}}@REPLACEME.us-west-2.rds.amazonaws.com:5432/postgres" \
    username="vaultuser" \
    password="REPLACEME"
vault write database/roles/postgresql-admin \
    db_name=demopostgresqldb \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
    default_ttl="1h" \
    max_ttl="24h"

#postgresql://{{username}}:{{password}}@
# Obtain PostgreSQL DB Creds
vault read database/creds/postgresql-admin





#vault write aws/roles/vault-demo-milesjh role_arns=arn:aws:iam::ACCTNUM:role/vault-demo-milesjh credential_type=assumed_role
#vault write aws/sts/test ttl=15m

# ,
#         {
#             "Action": "pi:*",
#             "Effect": "Allow",
#             "Resource": "arn:aws:pi:*:*:metrics/rds/*"
#         },
#         {
#             "Action": "iam:CreateServiceLinkedRole",
#             "Effect": "Allow",
#             "Resource": "*",
#             "Condition": {
#                 "StringLike": {
#                     "iam:AWSServiceName": [
#                         "rds.amazonaws.com",
#                         "rds.application-autoscaling.amazonaws.com"
#                     ]
#                 }
#             }
#         }