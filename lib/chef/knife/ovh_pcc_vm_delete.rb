#
# Author:: Alexis Gruet (<alexis.gruet@kroknet.com>)
# License:: Apache License, Version 2.0
#

require 'chef/knife/ovh_base'

# Delete a virtual machine from vCenter
class Chef
  class Knife
    class OvhPccVmDelete < Knife
    
      include Knife::OvhBase
            
      banner "knife ovh pcc vm delete VMNAME"
    
      def run
        $stdout.sync = true
        
        vmname = @name_args[0]
        
        if vmname.nil?
          show_usage
          fatal_exit("You must specify a virtual machine name")
        end
        
        vim = get_vim_connection
        
        dcname = config[:vsphere_dc] || Chef::Config[:knife][:vsphere_dc]
        dc = vim.serviceInstance.find_datacenter(dcname) or
        fatal_exit("datacenter not found")
        
        vm = find_in_folders(dc.vmFolder, RbVmomi::VIM::VirtualMachine,vmname) or fatal_exit("VM #{vmname} not found")
        
        vm.PowerOffVM_Task.wait_for_completion unless vm.runtime.powerState == "poweredOff"
        vm.Destroy_Task
        puts "Deleted virtual machine #{vmname}"
      end
      
    end
  end
end