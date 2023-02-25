#########################################################################
#### This script provisions the web servers that are inside the webserver subnets. The only access to these hosts 
#       is either through the Palo Alto Firewall in the Security VPC, or locally from within the VPC. 
# 
#       As the EC2s are deployed from AWS Linux AMIs, they do not have the packages and configuration needed 
#       for web servers. 
#
#       This script will convert them into web servers as follows: 
#         1. Create a temporary IGW in the WebServer VPC 
#         2. Create a temporary ENI, attach it to the soon-to-be web serving EC2s
#         3. Map a public IP to the ENI, with route to the Internet through the IGW
#
#       Now that we have useful access to the EC2s, we perform the following steps:
#         4. SSH to the EC2 with the keypair generated by Terraform upon instance creation
#         5. Update the packages on linux, install and configure a LAMP stack, set the system up to run Apache upon restart
#              5a. "sudo amazon-linux-extras install php8.0 mariadb10.5 -y", 
#                   "sudo yum install -y httpd",
#                   "sudo systemctl start httpd",
#                   "sudo systemctl enable httpd"]
#
#         6. Wait a minute for the software and network to coalesce 
#         7. Test the webserver via curl to retrieve the Apache default test page
# 
#      Put things into production order: 
#         8. Disassociate the ENI from the webserver 
#         9. Disassociate the IGW from the WebServer VPC
#        10. Remove the temporary routes from EC2 to Internet via IGW


#################

# Set up some variables (ws == webserver host)
debug_flag=1                  #0: run straight through script, 1: pause and prompt during script run
which_web_server=2            #set up for 1 or 2

#Common vars 
bh_AMI=ami-094125af156557ca2
bh_type=t2.micro
ws_keypair=temp-replace-before-running-script
open_sec_group=SG-allow_ipv4
ws_loginid=ec2-user
igw_name=temp-webserver-igw


if [ $which_web_server -eq 1 ]
   then 
      echo "  --> Setting up to build Web Server #1"
      #Webserver1 specific vars
      ws_inst_name=WebSrv1-az1
      ws_subnet=websrv-az1-inst
      ws_subnet_private_ip="10.110.0.30"
      ws_normal_rt=WebSrv-subnets-RT
      ws_temp_rt=Temp-RT-WebSrv-subnets
 fi 

if [ $which_web_server -eq 2 ]
   then 
      echo "  --> Setting up to build Web Server #2"
      #Webserver1 specific vars
      ws_inst_name=WebSrv1-az2
      ws_subnet=websrv-az2-inst
      ws_subnet_private_ip="10.110.128.30"
      ws_normal_rt=WebSrv-subnets-RT
      ws_temp_rt=Temp-RT-WebSrv-subnets
 fi 



# Get some info from AWS for the target webserver
subnetid=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${ws_subnet}" --query "Subnets[*].SubnetId" --output text)
vpcid=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${ws_subnet}" --query "Subnets[*].VpcId" --output text)
cidr=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=${ws_subnet}" --query "Subnets[*].CidrBlock" --output text)
echo "SubnetId:"${subnetid}
echo "VpcId:"${vpcid}
echo "CIDR:"${cidr}
 
#Build an IGW so we can access the web server from the outside -  just for initial configuration
igwid=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
aws ec2 create-tags --resources $igwid --tags Key=Name,Value=${igw_name}

# Attach the IGW to the web server's subnet's VPC 
aws ec2 attach-internet-gateway --internet-gateway-id ${igwid} --vpc-id ${vpcid}
echo "Created IGW:"${igwid}" and attached to VPC:"${vpcid}
      
# Get the handle for the web server EC2 - filter on running to avoid picking up previously terminated instances with same name
instid=$(aws ec2 describe-instances --filters Name=tag:Name,Values=${ws_inst_name} "Name=instance-state-name,Values=running" --query "Reservations[*].Instances[*].InstanceId" --output text)
echo "Web Server identified:"${ws_inst_name}", InstanceID:"${instid}

# Create a network interface in the webserver's subnet with a public IP - to associate with the IGW
#eniid=$(aws ec2 create-network-interface --description "Temp ENI  to config web server" --subnet-id ${subnetid} 2>/dev/null | jq -r '.NetworkInterface.NetworkInterfaceId')
#echo "ENI Created:"${eniid}

# Allocate a public IP address from AWS
eipid=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
echo "EIP Created:"${eipid}

# Associate the EIP with the webserver EC2
#associd=$(aws ec2 associate-address --instance-id ${instid} --allocation-id ${eipid})
associd=$(aws ec2 associate-address --instance-id ${instid} --allocation-id ${eipid} --query AssociationId --output text)
echo "EIP::EC2 association created:"${associd}

# Verify that the public IP (EIP) is attached to the web server NIC
publicip=$(aws ec2 describe-instances --instance-ids ${instid} --query "Reservations[*].Instances[*].PublicIpAddress" --output text)
privateip=$(aws ec2 describe-instances --instance-ids ${instid} --query "Reservations[*].Instances[*].PrivateIpAddress" --output text)
echo " ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "|   WebServer #" ${which_web_server} "Remapped to IGW for sw install"
echo "|     EC2's PublicIP :"${publicip}
echo "|     EC2's PrivateIP:"${privateip}
echo "|     Subnet:"${ws_subnet}" ==> "${subnetid}
echo "|     Normal RT:      "${ws_normal_rt}
echo "|     Temp RT  :      "${ws_temp_rt}
echo " ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# Now that the instrastructure setup is built and configured, we need to change the route table 
#    for the webserver instance to use the IGW for 0.0.0.0/0. This will allow this script to 
#    connect to the instance and configure it. Once complete, we change the route table back to 
#    the original setup. 

# Create RT 
rtid=$(aws ec2 create-route-table --vpc-id ${vpcid} --query "RouteTable.RouteTableId" --output text)
aws ec2 create-tags --resources $rtid --tags Key=Name,Value=${ws_temp_rt}
echo "Created temp route table:"${ws_temp_rt}" ==> "${rtid}

# Add default route
routesuccess=$(aws ec2 create-route --route-table-id ${rtid} --destination-cidr-block 0.0.0.0/0 --gateway-id ${igwid})
echo "Successfully created route?:"${routesuccess}

# Set up to change the subnet <-> route table association temporarily 
rt_normal_tag=$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${ws_normal_rt}" --query "RouteTables[*].RouteTableId"  --output text)
rt_temp_tag=$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=${ws_temp_rt}" --query "RouteTables[*].RouteTableId"  --output text)

echo "Here are the RT handles retrieved from AWS, normal:"${rt_normal_tag}" temp:"${rt_temp_tag}


###############################################################################################
read -p "Pausing to check results before deleting, Enter to proceed"
###############################################################################################

# Disassociate EIP from Instance 
echo "Disassociating EIP:"${eipid}" from instance:"${instid}" with existing association:"${associd}
result=$(aws ec2 disassociate-address --association-id ${associd})

# Release EIP from Account
echo "Releasing EIP:"${eipid}
result=$(aws ec2 release-address --allocation-id ${eipid})
 #~~~
      if [ $debug_flag -eq 1 ]
         then read -p "___Paused, enter to proceed___"
      fi
      #~~~

# Detach IGW from VPC
echo "Detaching IGW:"${igwid}" from VPC:"${vpcid}
result=$(aws ec2 detach-internet-gateway --internet-gateway-id ${igwid} --vpc-id ${vpcid})

# Delete IGW
echo "Deleting IGW:"${igwid}
result=$(aws ec2 delete-internet-gateway --internet-gateway-id ${igwid})

# Delete temp route table
echo "Deleting Temp RT :"${rtid}
read -p "..."
result=$(aws ec2 delete-route-table --route-table-id ${rtid})

read -p "Resource cleanup complete, ENTER to exit script"

exit 0
