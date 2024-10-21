#!/bin/bash

set -e

echo '
 /$$   /$$  /$$$$$$  /$$        /$$$$$$   /$$$$$$   /$$$$$$   /$$$$$$
| $$$ | $$ /$$__  $$| $$       /$$__  $$ /$$__  $$ /$$__  $$ /$$__  $$
| $$$$| $$| $$  \ $$| $$      | $$  \ $$| $$  \__/| $$  \__/| $$  \ $$
| $$ $$ $$| $$  | $$| $$      | $$$$$$$$|  $$$$$$ | $$      | $$  | $$
| $$  $$$$| $$  | $$| $$      | $$__  $$ \____  $$| $$      | $$  | $$
| $$\  $$$| $$  | $$| $$      | $$  | $$ /$$  \ $$| $$    $$| $$  | $$
| $$ \  $$|  $$$$$$/| $$$$$$$$| $$  | $$|  $$$$$$/|  $$$$$$/|  $$$$$$/
|__/  \__/ \______/ |________/|__/  |__/ \______/  \______/  \______/
'
echo

# STEP 1: CREATE VPC
echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=LAB-VPC}]' \
  --query 'Vpc.VpcId' \
  --output text)
echo "VPC created with ID: $VPC_ID"
echo

# STEP 2: CREATE SUBNETS
echo "Creating subnets..."

# Define subnets with their CIDR blocks and availability zones
declare -A SUBNETS=(
  [PublicSubnet1]="10.0.1.0/24 us-east-1a"
  [PublicSubnet2]="10.0.2.0/24 us-east-1b"
  [PrivateSubnet1]="10.0.3.0/24 us-east-1a"
  [PrivateSubnet2]="10.0.4.0/24 us-east-1b"
)

# Loop through the array to create each subnet and store their IDs
for NAME in "${!SUBNETS[@]}"; do
  CIDR="${SUBNETS[$NAME]}"
  CIDR_BLOCK=$(echo $CIDR | awk '{print $1}')
  AVAILABILITY_ZONE=$(echo $CIDR | awk '{print $2}')
  echo "Creating $NAME..."
  SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block "$CIDR_BLOCK" \
    --availability-zone "$AVAILABILITY_ZONE" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$NAME}]" \
    --query 'Subnet.SubnetId' \
    --output text 2>/dev/null)

  # Check if SUBNET_ID is not empty
  if [[ -n "$SUBNET_ID" ]]; then
    # Store each subnet ID in a separate variable
    case $NAME in
      PublicSubnet1) PUBLIC_SUBNET_1="$SUBNET_ID" ;;
      PublicSubnet2) PUBLIC_SUBNET_2="$SUBNET_ID" ;;
      PrivateSubnet1) PRIVATE_SUBNET_1="$SUBNET_ID" ;;
      PrivateSubnet2) PRIVATE_SUBNET_2="$SUBNET_ID" ;;
    esac
    echo "$NAME created with ID: $SUBNET_ID"
  else
    echo "Error creating $NAME." # Report error if SUBNET_ID is empty
  fi
done

# Output the subnet IDs
echo "Public Subnet 1 ID: $PUBLIC_SUBNET_1"
echo "Public Subnet 2 ID: $PUBLIC_SUBNET_2"
echo "Private Subnet 1 ID: $PRIVATE_SUBNET_1"
echo "Private Subnet 2 ID: $PRIVATE_SUBNET_2"
echo

# STEP 3: CREATE AND ATTACH INTERNET GATEWAYY
echo "Creating and Attaching Internet Gateway..."
IGW=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=LAB-IGW}]' \
  --query 'InternetGateway.InternetGatewayId' \
  --output text) && \
  echo "Internet Gateway created with ID: $IGW" && \
  aws ec2 attach-internet-gateway \
  --internet-gateway-id $IGW \
  --vpc-id $VPC_ID && \
  echo "Internet Gateway $IGW attached to VPC $VPC_ID"
echo

# STEP 4: CREATE ROUTE TABLES
echo "Creating Public Route Table..."
PUBLIC_ROUTE_TABLE=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=PublicRouteTable}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)
echo "Public Route Table created with ID: $PUBLIC_ROUTE_TABLE"
echo "Creating Private Route Table..."
PRIVATE_ROUTE_TABLE=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=PrivateRouteTable}]' \
  --query 'RouteTable.RouteTableId' \
  --output text)

# Array of subnets to associate with the public and private route tables
PU_SUBNETS=("$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2")
PR_SUBNETS=("$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2")
echo "Associating Public Subnets..."
for SUBNET in "${PU_SUBNETS[@]}"; do
  aws ec2 associate-route-table \
    --route-table-id "$PUBLIC_ROUTE_TABLE" \
    --subnet-id "$SUBNET"
  echo "Public Route Table $PUBLIC_ROUTE_TABLE associated with Subnet $SUBNET"
done
echo "Associating Private Subnets..."
for SUBNET in "${PR_SUBNETS[@]}"; do
  aws ec2 associate-route-table \
    --route-table-id "$PRIVATE_ROUTE_TABLE" \
    --subnet-id "$SUBNET"
  echo "Private Route Table $PRIVATE_ROUTE_TABLE associated with Subnet $SUBNET"
done
echo "Setting up routing for the Internet Gateway..."
aws ec2 create-route \
  --route-table-id $PUBLIC_ROUTE_TABLE \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW
echo "IGW routing established"
echo

# STEP 5: CREATE NAT GATEWAY
echo "Allocating Elastic IP"
ELASTIC_IP=$(aws ec2 allocate-address \
  --domain vpc \
  --query 'AllocationId' \
  --output text)
echo "Creating NAT Gateway..."
NAT=$(aws ec2 create-nat-gateway \
  --subnet-id $PUBLIC_SUBNET_1 \
  --allocation-id $ELASTIC_IP \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=LAB-NAT}]' \
  --query 'NatGateway.NatGatewayId' \
  --output text)
echo "Setting up routing for NAT Gateway..."
aws ec2 create-route \
  --route-table-id $PRIVATE_ROUTE_TABLE \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $NAT
echo

# STEP 6: CREATE SECURITY GROUPS
echo "Creating WebServer SG..."
WSSG=$(aws ec2 create-security-group \
  --group-name WebServer-SG \
  --description "Allow HTTP and SSH" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)
echo "WebServer SG created with ID: $WSSG"
echo "Creating RDS SG..."
RDSSG=$(aws ec2 create-security-group \
  --group-name RDS-SG \
  --description "Allow MySQL access" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)
echo "RDS SG created with ID: $RDSSG"

# Retrieve Public IP
PUBLIC_IP=$(curl -s https://checkip.amazonaws.com)

echo "Authorizing WebServer SG..."
aws ec2 authorize-security-group-ingress \
  --group-id $WSSG \
  --protocol tcp \
  --port 22 \
  --cidr $PUBLIC_IP/32
aws ec2 authorize-security-group-ingress \
  --group-id $WSSG \
  --protocol tcp \
  --port 80 \
  --cidr $PUBLIC_IP/32
echo "Authorizing RDS SG..."
aws ec2 authorize-security-group-ingress \
  --group-id $RDSSG \
  --protocol tcp \
  --port 3306 \
  --source-group $WSSG
echo

# STEP 7: LAUNCH THE EC2 INSTANCE
# Check if the key pair already exists
KEY_NAME="EC2-KEY"
if aws ec2 describe-key-pairs \
  --key-names $KEY_NAME &> /dev/null; then
  echo "Key pair '$KEY_NAME' already exists"
else
  echo "Creating key pair '$KEY_NAME'..."
  KEY_MATERIAL=$(aws ec2 create-key-pair --key-name $KEY_NAME --query 'KeyMaterial' --output text)
  echo "Key pair '$KEY_NAME' created and saved to $KEY_NAME.pem"
  echo "$KEY_MATERIAL" > $KEY_NAME.pem
  chmod 400 $KEY_NAME.pem
fi

echo "Launching the EC2 Instance (Web Server)"
INSTANCE=$(aws ec2 run-instances \
  --image-id ami-0ebfd941bbafe70c6 \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --security-group-ids $WSSG \
  --subnet-id $PUBLIC_SUBNET_1 \
  --associate-public-ip-address \
  --user-data file://setup.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=LAB-WS}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
echo "Web Server instance launched with ID: $INSTANCE"
echo "Waiting for the instance to be in running state..."
aws ec2 wait instance-running --instance-ids $INSTANCE
echo "Instance $INSTANCE_ID is now running."
echo

# STEP 8: CREATE RDS DATABASE (MULTI-AZ)
echo "Creating DB Subnet Group..."
RDS_SUBNET_GROUP=$(aws rds create-db-subnet-group \
  --db-subnet-group-name MyDBSubnetGroup \
  --subnet-ids $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2 \
  --db-subnet-group-description "My DB Subnet Group" \
  --query 'DBSubnetGroup.DBSubnetGroupName' \
  --output text)
echo "Launching RDS Instance..."
RDS_INSTANCE=$(aws rds create-db-instance \
  --db-instance-identifier MyDBInstance \
  --db-instance-class db.t3.micro \
  --engine mysql \
  --allocated-storage 20 \
  --master-username admin \
  --master-user-password password \
  --vpc-security-group-ids $RDSSG \
  --db-subnet-group-name $RDS_SUBNET_GROUP \
  --multi-az \
  --query 'DBInstance.DBInstanceIdentifier' \
  --output text)

echo "Waiting RDS Instance get available...it takes a few minutes"
aws rds wait db-instance-available \
  --db-instance-identifier $RDS_INSTANCE

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier MyDBInstance) \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

echo
echo "RDS Endpoint: $RDS_ENDPOINT"
echo "Complete!"













































