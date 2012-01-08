#
# Author:: Alexis Gruet (<alexis.gruet@kroknet.com>)
# License:: Apache License, Version 2.0
#

require 'chef/knife/ovh_base'

# Clone an existing template into a new VM - bootstrap chef - and optionally give some recipes and/or roles
# 
# usage:

# knife vsphere vm clone web06 00_UBUNTU-10.04 --domain intra.kroknet.com \ 
#       --hostname web06 --ip 46.105.128.246 --gw 46.105.128.254 --dns 213.186.33.99 --netmask 255.255.255.224 \
#       -d pcc-178-33-102-96_datacenter144 --ssh-user agruet --ssh-password test --distro ubuntu10.04-apt \
#       -r 'recipe[kroknet-apt-repository_dev]'

class Chef
    class Knife
        class OvhPccVmClone < Knife
            
          include Knife::OvhBase
        
          deps do
            require 'readline'
            require 'netaddr'
            require 'chef/json_compat'
            require 'chef/knife/bootstrap'
            Chef::Knife::Bootstrap.load_deps
          end  

          banner "knife ovh pcc vm clone VMNAME TEMPLATE (options)"

          attr_accessor :initial_sleep_delay
        
          option :customization_ip,
          :long => "--ip IP",
          :description => "ip address for customization"

          option :customization_netmask,
          :long => "--netmask NETMASK",
          :description => "netmask for customization"

          option :customization_gw,
          :long => "--gw GATEWAY",
          :description => "gateway for customization"

          option :customization_dns,
          :long => "--dns DNS IP",
          :description => "dns ip for customization"

          option :customization_domain,
          :long => "--domain CUST_DOMAIN",
          :description => "domain name for customization"

          option :customization_hostname,
          :long => "--hostname HOSTNAME",
          :description => "Unqualified hostname for customization"

          option :customization_tz,
          :long => "--tz CUST_TIMEZONE",
          :description => "Timezone 'Area/Location' format"

          option :distro,
          :short => "-d DISTRO",
          :long => "--distro DISTRO",
          :description => "Bootstrap a distro using a template",
          :proc => Proc.new { |d| Chef::Config[:knife][:distro] = d },
          :default => "ubuntu10.04-apt"  

          option :bootstrap_version,
          :long => "--bootstrap-version VERSION",
          :description => "The version of Chef to install",
          :proc => Proc.new { |v| Chef::Config[:knife][:bootstrap_version] = v }

          option :run_list,
          :short => "-r RUN_LIST",
          :long => "--run-list RUN_LIST",
          :description => "Comma separated list of roles/recipes to apply",
          :proc => lambda { |o| o.split(/[\s,]+/) },
          :default => []

          option :ssh_user,
          :short => "-x USERNAME",
          :long => "--ssh-user USERNAME",
          :description => "The ssh username",
          :default => "root"

          option :ssh_password,
          :short => "-P PASSWORD",
          :long => "--ssh-password PASSWORD",
          :description => "The ssh password" 

          option :power,  
          :long => "--start STARTVM",
          :description => "Indicates whether to start the VM after a successful clone",
          :default => true

          def locate_config_value(key)
            key = key.to_sym
            Chef::Config[:knife][key] || config[key]
          end              
        
          def tcp_test_ssh(hostname)
            tcp_socket = TCPSocket.new(hostname, 22)
            readable = IO.select([tcp_socket], nil, nil, 5)
            if readable
                Chef::Log.debug("sshd accepting connections on #{hostname}, banner is #{tcp_socket.gets}")
                yield
                true
                else
                false
            end
            rescue SocketError
            sleep 2
            false
            rescue Errno::ETIMEDOUT
            false
            rescue Errno::EPERM
            false
            rescue Errno::ECONNREFUSED
            sleep 2
            false
            # This happens on OVH quite often
            rescue Errno::EHOSTUNREACH
            sleep 2
            false
            ensure
            tcp_socket && tcp_socket.close
          end
        
          # Run !
          def run
              
            $stdout.sync = true
    
            vmname = @name_args[0]
              
            if vmname.nil?
              show_usage
              fatal_exit("You must specify a virtual machine name")
            end
    
            template = @name_args[1]
            if template.nil?
              show_usage
              fatal_exit("You must specify a template name")
            end
    
            vim = get_vim_connection
    
            dcname = config[:vsphere_dc] || Chef::Config[:knife][:vsphere_dc]
            dc = vim.serviceInstance.find_datacenter(dcname) or abort "datacenter not found"
    
            hosts = find_all_in_folders(dc.hostFolder, RbVmomi::VIM::ComputeResource)
            rp = hosts.first.resourcePool
    
            src_vm = find_in_folders(dc.vmFolder, RbVmomi::VIM::VirtualMachine, template) or
            abort "VM/Template not found"
    
            # kroknet - <alexis.gruet@kroknet.com>
            # Fix to handle the vm creation with many parameters 
    
            fixed_name = RbVmomi::VIM.CustomizationFixedName
            fixed_name.name = config[:customization_hostname]
    
            # Global settings 
            vm_dns = RbVmomi::VIM.CustomizationGlobalIPSettings                                                                                                 
    
            my_dns    = config[:customization_dns].split(',');
            my_suffix = config[:customization_domain].split(',');
    
            vm_dns.dnsServerList = my_dns
            vm_dns.dnsSuffixList = my_suffix
    
            # Who am i ?
            identity_settings  = RbVmomi::VIM.CustomizationLinuxPrep
    
            identity_settings.hostName   = fixed_name
            identity_settings.domain     = config[:customization_domain]
            identity_settings.hwClockUTC = false
            identity_settings.timeZone   = 'Europe/Paris'
    
            cidr_ip = NetAddr::CIDR.create(config[:customization_ip])
    
            # IP
            vm_ip = RbVmomi::VIM::CustomizationFixedIp(:ipAddress => cidr_ip.ip)
    
            # IPV4 Settings eth0
            vm_ip_settings = RbVmomi::VIM.CustomizationIPSettings
    
            my_gw =  config[:customization_gw].split(',');
    
            vm_ip_settings.ip            = vm_ip
            vm_ip_settings.subnetMask    = config[:customization_netmask]
            vm_ip_settings.dnsServerList = my_dns
            vm_ip_settings.gateway       = my_gw
            vm_ip_settings.dnsDomain     = config[:customization_domain] 
    
            #adapter mapping 
            adapter_mapping = RbVmomi::VIM.CustomizationAdapterMapping
            adapter_mapping.adapter = vm_ip_settings
    
            customization_spec = RbVmomi::VIM.CustomizationSpec
    
            multi_nic = [ adapter_mapping ]
    
            customization_spec.globalIPSettings = vm_dns
            customization_spec.identity         = identity_settings
            customization_spec.nicSettingMap    = multi_nic
    
            rspec = RbVmomi::VIM.VirtualMachineRelocateSpec(:pool => rp)
    
            clone_spec = RbVmomi::VIM.VirtualMachineCloneSpec(:customization => customization_spec,
                                                              :location      => rspec,
                                                              :powerOn       => false,
                                                              :template      => false)
    
            task = src_vm.CloneVM_Task(:folder => src_vm.parent, :name => vmname, :spec => clone_spec)
            puts "Cloning template #{template} to new VM #{vmname}"
            task.wait_for_completion
            puts "Finished creating virtual machine #{vmname}"
    
            if config[:power]
                vm = find_in_folders(dc.vmFolder, RbVmomi::VIM::VirtualMachine, vmname) or
                fatal_exit("VM #{vmname} not found")
                vm.PowerOnVM_Task.wait_for_completion
                puts "Powered on virtual machine #{vmname}"
        
                # TODO:
                #  Fix this crappy stuff - while loop is used 
                #   to ensure the hostname is well done updated by the the tools 
                #   should be nice to ask francois from ovh to figured out if one method exist to deal with this corner case
                #
                print "\n#{ui.color("Waiting for server", :magenta)}"
                
                while vm.guest.hostName != vmname
                    print(".")    
                    sleep 2
                end
        
                puts("\n")
                print "\n#{ui.color("VM #{vmname} - Ready - Starting chef bootstrap", :magenta)}"
                puts("\n")
                print "\n#{ui.color("As to bootstrap chef we need a ssh conn - lets check for it", :magenta)}"
                
                #or fatal_exit( "\n#{ui.color("No way to connect the remote server via SSH - IP : #{cidr_ip.ip} - If use used a private IP, ensure a vpn connection exist", :magenta)}" )
                
                print "." until tcp_test_ssh(config[:customization_ip]) {
                  bootstrap = Chef::Knife::Bootstrap.new
                  bootstrap.name_args = [cidr_ip.ip]
                  bootstrap.config[:run_list] = config[:run_list]
                  bootstrap.config[:ssh_user] = config[:ssh_user]
                  bootstrap.config[:chef_node_name] = config[:chef_node_name] 
                  bootstrap.config[:bootstrap_version] = locate_config_value(:bootstrap_version)
                  bootstrap.config[:distro] = locate_config_value(:distro)
                  bootstrap.config[:use_sudo] = true unless config[:ssh_user] == 'root'
                  bootstrap.config[:environment] = config[:environment]
        
                  bootstrap.run
                  
                  puts("\n")  
                  puts("\n")
                  print "\n#{ui.color("server is up and bootstraped with a chef-client", :green)}"
                  puts("\n")  
                                                         
                }    
            end
    
          end # end run 
        
        end
    
      end

    end
