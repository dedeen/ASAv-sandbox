#
# Build VPC for the Security Appliances 
module "vpc" {
  source          = "terraform-aws-modules/vpc/aws"

  for_each = var.security_vpcs
    providers = {
      aws = aws.usw2  # Set region via provider alias
    }
    name              = each.value.region_dc
    cidr              = each.value.cidr
    azs               = each.value.az_list
	
    # Create subnets: private get route through NATGW, intra do not
    private_subnets   		= each.value.vpc_subnets	
    private_subnet_names 	= each.value.subnet_names
  #  public_subnets    		= [each.value.az2_subnet]
  #  public_subnet_names 	= ["az2_subnet"]
    enable_ipv6            	= false
	
    # Create single NATGW for each VPC, all private subnets must route through it to reach Internet 
    enable_nat_gateway     	= false
    one_nat_gateway_per_az  	= false # single_nat_gateway overrides this parameter
    single_nat_gateway      	= true	# only need to create 1 EIP above with this setting
    reuse_nat_ips	    	= true	# dont create EIPs here for NATGW, instead use from above 
    #external_nat_ip_ids	    	= "${aws_eip.nat.*.id}"			# as per above 
}

/*xx
# NACL for public (edge) subnet 
resource "aws_network_acl" "NACL-edge" {
  vpc_id      	= module.vpc["datacenter1"].vpc_id
  depends_on 	= [module.vpc["datacenter1"].public_subnets]	#11
  
  ingress {
    protocol		= "-1"
    rule_no		= 100
    action		= "allow"
    cidr_block		= "0.0.0.0/0"
    from_port		= 0	# ignored with protocol -1
    to_port		= 0	# ignored with protocol -1
  }
  egress {
    protocol		= "-1"
    rule_no		= 101
    action		= "allow"
    cidr_block		= "0.0.0.0/0"
    from_port		= 0	# ignored with protocol -1
    to_port		= 0	# ignored with protocol -1
  }
  tags = {
    Name = "NACL-edge"
  }
}

# NACLs for private (server) subnet
resource "aws_network_acl" "NACL-server" {
  vpc_id      	= module.vpc["datacenter1"].vpc_id
  depends_on 	= [module.vpc["datacenter1"].private_subnets]	#11
  
  ingress {
    protocol		= "-1"
    rule_no		= 100
    action		= "allow"
    cidr_block		= "0.0.0.0/0"
    from_port		= 0	# ignored with protocol -1
    to_port		= 0	# ignored with protocol -1
  }
  egress {
    protocol		= "-1"
    rule_no		= 101
    action		= "allow"
    cidr_block		= "0.0.0.0/0"
    from_port		= 0	# ignored with protocol -1
    to_port		= 0	# ignored with protocol -1
  }
  tags = {
    Name = "NACL-server"
  }
}

# NACLs for intra (vault) subnet
resource "aws_network_acl" "NACL-vault" {
  vpc_id      	= module.vpc["datacenter1"].vpc_id
  depends_on 	= [module.vpc["datacenter1"].intra_subnets]		#11
  
  ingress {
    protocol		= "-1"
    rule_no		= 100
    action		= "allow"
    cidr_block		= "0.0.0.0/0"
    from_port		= 0	# ignored with protocol -1
    to_port		= 0	# ignored with protocol -1
  }
  egress {
    protocol		= "-1"
    rule_no		= 101
    action		= "allow"
    cidr_block		= "0.0.0.0/0"
    from_port		= 0	# ignored with protocol -1
    to_port		= 0	# ignored with protocol -1
  }
  tags = {
    Name = "NACL-vault"
  }
}	  
	  

	  
# Assoc NACLs to subnets
resource "aws_network_acl_association" "edgeNACL_snet" {
  depends_on	 = [module.vpc["datacenter1"],aws_network_acl.NACL-edge, module.vpc["datacenter1"].public_subnets]   
  network_acl_id = aws_network_acl.NACL-edge.id
  subnet_id      = module.vpc["datacenter1"].public_subnets[0]	# public == edge 
}
resource "aws_network_acl_association" "serverNACL_snet" {
  depends_on	 = [module.vpc["datacenter1"],aws_network_acl.NACL-server,module.vpc["datacenter1"].private_subnets] 
  network_acl_id = aws_network_acl.NACL-server.id
  subnet_id      = module.vpc["datacenter1"].private_subnets[0]	# private == server
}
resource "aws_network_acl_association" "vaultNACL_snet" {
  depends_on	 = [module.vpc["datacenter1"],aws_network_acl.NACL-vault,module.vpc["datacenter1"].intra_subnets] 
  network_acl_id = aws_network_acl.NACL-vault.id
  subnet_id      = module.vpc["datacenter1"].intra_subnets[0]	# intra == vault
}
	
    
 # Create SecGrp to allow ICMP into attached subnet
resource "aws_security_group" "SG-inbnd_icmp" {
  name          = "SG-inbnd_icmp"
  description   = "SG-inbnd_icmp"
  depends_on 	= [module.vpc["datacenter1"]]
  vpc_id        = module.vpc["datacenter1"].vpc_id
  ingress {
    description         = "ICMP inbound"
    cidr_blocks         = ["0.0.0.0/0"]
    from_port           = 8
    to_port             = 0
    protocol            = "icmp"
  }
  tags = {
    Name = "SG-inbnd_icmp"
    Owner = "dan-via-terraform"
  }
}

resource "aws_security_group" "SG-inbnd_http" {
  name          = "SG-inbnd_http"
  description   = "SG-inbnd_http"
  depends_on 	= [module.vpc["datacenter1"]]
  vpc_id        = module.vpc["datacenter1"].vpc_id
  ingress {
    description         = "http"
    cidr_blocks         = ["0.0.0.0/0"]
    from_port           = 80
    to_port             = 80 
    protocol            = "tcp"
  }
	  
ingress {
    description         = "https"
    cidr_blocks         = ["0.0.0.0/0"]
    from_port           = 443
    to_port             = 443 
    protocol            = "tcp"
  }
	  
  tags = {
    Name = "SG-inbnd_http" 
    Owner = "dan-via-terraform"
  }
}

# Create SecGrp to allow all IPv4 traffic into attached subnet
resource "aws_security_group" "SG-allow_ipv4" {
  name                  = "SG-allow_ipv4"
  description           = "SG-allow_ipv4"
  depends_on 		= [module.vpc["datacenter1"]]
  vpc_id                = module.vpc["datacenter1"].vpc_id
  ingress {
    description         = "inbound v4"
    cidr_blocks         = ["0.0.0.0/0"]
    from_port           = 0
    to_port             = 0
    protocol            = "-1"
  }
  egress {
    description         = "outbound v4"
    cidr_blocks         = ["0.0.0.0/0"]
    from_port           = 0
    to_port             = 0
    protocol            = "-1"
  }
  tags = {
    Name = "SG-allow_ipv4"
    Owner = "dan-via-terraform"
  }
}

# Create SecGrp to allow inbound ssh, outbound all 
resource "aws_security_group" "SG-inbnd_ssh" {
  name                  = "SG-inbnd_ssh"
  description           = "SG-inbnd_ssh"
  depends_on 		= [module.vpc["datacenter1"]]
  vpc_id                = module.vpc["datacenter1"].vpc_id
  ingress {
    description         = "All inbound ssh"
    cidr_blocks         = ["0.0.0.0/0"]
    from_port           = 22
    to_port             = 22
    protocol            = "tcp"
  }
  egress {
    description         = "All outbound v4"
    cidr_blocks         = ["0.0.0.0/0"]
    from_port           = 0
    to_port             = 0
    protocol            = "-1"
  }
  tags = {
    Name = "SG-inbnd_ssh"
    Owner = "dan-via-terraform"
  }
}

# Create SecGrp to allow traffic from within the public and private subnets, blocked outside of these 
resource "aws_security_group" "SG-intra_vpc_v4" {
  name                  = "SG-intra_vpc_v4"
  description           = "SG-intra_vpc_v4"
  depends_on 		= [module.vpc["datacenter1"]]
  vpc_id                = module.vpc["datacenter1"].vpc_id
  ingress {
    description         = "All intra vpc v4"
    cidr_blocks         = ["0.0.0.0/0"]
    from_port           = 22
    to_port             = 22
    protocol            = "tcp"
  }
  egress {
    description         = "All intra vpc v4"
    cidr_blocks         = ["0.0.0.0/0"]
    from_port           = 0
    to_port             = 0
    protocol            = "-1"
  }
  tags = {
    Name = "SG-intra_vpc_v4"
    Owner = "dan-via-terraform"
  }
}

##############	  
xx*/
