package "mdadm"
package "lvm2"

execute "Load device mapper kernel module" do
  command "modprobe dm-mod"
  ignore_failure true
end

credentials = Chef::EncryptedDataBagItem.load(node[:ebs][:creds][:databag], node[:ebs][:creds][:item])

node[:ebs][:raids].each do |device, options|
  disks = []
  if !options[:disks] && options[:num_disks]
    #next_mount = Dir.glob('/dev/xvd?').sort.last[-1,1].succ
    next_mount = BlockDevice.available_device_id(node[:ebs][:block_range_regex])
    1.upto(options[:num_disks].to_i) do |i|
      disks << mount = "/dev/sd#{next_mount}"
      next_mount = next_mount.succ

      vol = aws_ebs_volume mount do
        aws_access_key credentials['access_key_id']
        aws_secret_access_key credentials['secret_access_key']
        size options[:disk_size]
        device mount
        availability_zone node[:ec2][:placement_availability_zone]
        action :nothing
      end
      vol.run_action(:create)
      vol.run_action(:attach)
    end
  end
  node.set[:ebs][:raids][device][:disks] = disks.map { |d| d.sub('/sd', '/xvd') } if !disks.empty?
  node.save unless Chef::Config[:solo]
end

node[:ebs][:raids].each do |raid_device, options|
  lvm_device = BlockDevice.lvm_device(raid_device)

  Chef::Log.info("Waiting for individual disks of RAID #{options[:mount_point]}")
  options[:disks].each do |disk_device|
    BlockDevice::wait_for(disk_device)
  end

  ruby_block "Create or resume RAID array #{raid_device}" do
    block do
      if BlockDevice.existing_raid_at?(raid_device)
        if BlockDevice.assembled_raid_at?(raid_device)
          Chef::Log.info "Skipping RAID array at #{raid_device} - already assembled and probably mounted at #{options[:mount_point]}"
        else
          BlockDevice.assemble_raid(raid_device, options)
        end
      else
        # When ephemeral disks, minimally one comes mounted by default on AWS.
        # Assure no disk intended for the raid remains mounted before creating.
        options[:disks].each do |disk_device|
          BlockDevice.assure_nomount(disk_device)
        end
        BlockDevice.create_raid(raid_device, options.update(:chunk_size => node[:ebs][:mdadm_chunk_size]))
      end

      BlockDevice.set_read_ahead(raid_device, node[:ebs][:md_read_ahead])
    end
  end

  ruby_block "Create or attach LVM volume out of #{raid_device}" do
    block do
      BlockDevice.create_lvm(raid_device, options)
    end
  end

  execute "mkfs" do
    command "mkfs -t #{options[:fstype]} #{lvm_device}"

    not_if do
      # check volume filesystem
      system("blkid -s TYPE -o value #{lvm_device}")
    end
  end

  directory options[:mount_point] do
    recursive true
    action :create
    mode "0755"
  end

  mount options[:mount_point] do
    fstype options[:fstype]
    device lvm_device
    options "noatime"
    not_if do
      File.read('/etc/mtab').split("\n").any?{|line| line.match(" #{options[:mount_point]} ")}
    end
  end

  mount options[:mount_point] do
    action :enable
    fstype options[:fstype]
    device lvm_device
    options "noatime"
    not_if do
      File.read('/etc/mtab').split("\n").any?{|line| line.match(" #{options[:mount_point]} ")}
    end
  end

  template "/etc/mdadm/mdadm.conf" do
    source "mdadm.conf.erb"
    mode 0644
    owner 'root'
    group 'root'
  end

  template "/etc/rc.local" do
    source "rc.local.erb"
    mode 0755
    owner 'root'
    group 'root'
  end
end
