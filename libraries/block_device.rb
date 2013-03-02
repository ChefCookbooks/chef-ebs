module BlockDevice
  def self.wait_for(device)
    loop do
      if File.blockdev?(device)
        Chef::Log.info("device #{device} ready")
        break
      else
        Chef::Log.info("device #{device} not ready - waiting")
        sleep 10
      end
    end
  end

  def self.wait_for_logical_volumes
    loop do
      lvscan = `lvscan`
      if lvscan.lines.all?{|line| line.include?('ACTIVE')}
        Chef::Log.debug("All LVM volume disks seem to be active:\n#{lvscan}")
        break
      else
        Chef::Log.debug("Not all LVM volume disks seem to be active, waiting 10 more seconds:\n#{lvscan}")
        sleep 10
      end
    end
  end

  def self.existing_raid_at?(device)
    raids = `mdadm --examine --scan`
    if raids.match(device) || raids.match(device.gsub(/md/, "md/"))
      Chef::Log.debug("Checking for existing RAID arrays at #{device}: #{raids}")
      Chef::Log.info("Checking for existing RAID arrays at #{device}: true")
      true
    else
      Chef::Log.debug("Checking for existing RAID arrays at #{device}: #{raids}")
      Chef::Log.info("Checking for existing RAID arrays at #{device}: false")
      false
    end
  end

  def self.assembled_raid_at?(device)
    raids = `mdadm --detail --scan`
    if raids.match(device)
      Chef::Log.debug("Checking for running RAID arrays at #{device}: #{raids}")
      Chef::Log.info("Checking for running RAID arrays at #{device}: true")
      true
    else
      Chef::Log.debug("Checking for running RAID arrays at #{device}: #{raids}")
      Chef::Log.info("Checking for running RAID arrays at #{device}: false")
      false
    end
  end

  def self.assemble_raid(raid_device, options)
    Chef::Log.info "Resuming existing RAID array #{raid_device} with #{options[:disks].size} disks, RAID level #{options[:raid_level]} at #{options[:mount_point]}"
    exec_command("mdadm --assemble --verbose #{raid_device} #{options[:disks].join(' ')}") or raise "Failed to assemble the RAID array at #{raid_device}"
  end

  def self.assure_nomount(disk_device)
    Chef::Log.info "Unmounting DISK device #{disk_device}"
    exec_command("umount #{disk_device}", true)

    # TODO: fixup /etc/fstab so the device does not try to mount at boot
  end

  def self.create_raid(raid_device, options)
    Chef::Log.info "creating RAID array #{raid_device} with #{options[:disks].size} disks, RAID level #{options[:raid_level]} at #{options[:mount_point]}"
    exec_command("yes | mdadm --create --chunk=#{options[:chunk_size]} --metadata=1.2 --verbose #{raid_device} --level=#{options[:raid_level]} --raid-devices=#{options[:disks].size} #{options[:disks].join(' ')}") or raise "Failed to create the RAID array at #{raid_device}"
  end

  def self.set_read_ahead(raid_device, ahead_option)
    Chef::Log.info "Setting read ahead options for RAID array #{raid_device} to #{ahead_option}"
    exec_command("blockdev --setra #{ahead_option} #{raid_device}") or raise "Failed to set read ahead options for RAID array at #{raid_device} to #{ahead_option}"
  end

  def self.lvm_device(raid_device)
    "/dev/#{lvm_volume_group(raid_device)}/lvm#{raid_device.match(/\d+/)[0]}"
  end

  def self.lvm_volume_group(raid_device)
    "lvm-raid-#{raid_device.match(/\d+/)[0]}"
  end

  def self.existing_lvm_at?(lvm_device)
    lvms = `lvscan`
    if lvms.match(lvm_device)
      Chef::Log.debug("Checking for active LVM volumes at #{lvm_device}: #{lvms}")
      Chef::Log.debug("Checking for active LVM volumes at #{lvm_device}: true")
      true
    else
      Chef::Log.debug("Checking for active LVM volumes at #{lvm_device}: #{lvms}")
      Chef::Log.debug("Checking for active LVM volumes at #{lvm_device}: false")
      false
    end
  end

  def self.create_lvm(raid_device, options)
    Chef::Log.info "creating LVM volume out of #{raid_device} with #{options[:disks].size} disks at #{options[:mount_point]}"
    unless lvm_physical_group_exists?(raid_device)
      exec_command("pvcreate #{raid_device}") or raise "Failed to create LVM physical disk for #{raid_device}"
    end
    unless lvm_volume_group_exists?(raid_device)
      exec_command("vgcreate #{lvm_volume_group(raid_device)} #{raid_device}") or raise "Failed to create LVM volume group for #{raid_device}"
    end
    unless lvm_volume_exits?(raid_device)
      extends = `vgdisplay #{lvm_volume_group(raid_device)} | grep Free`.scan(/\d+/)[0]
      exec_command("lvcreate -l #{extends} #{lvm_volume_group(raid_device)} -n #{File.basename(lvm_device(raid_device))}") or raise "Failed to create the LVM volume at #{raid_device}"
    end
  end

  def self.lvm_physical_group_exists?(raid_device)
    pvscan = `pvscan`
    if pvscan.match(raid_device)
      Chef::Log.debug("Checking for existing LVM physical disk for #{raid_device}: #{pvscan}")
      Chef::Log.debug("Checking for existing LVM physical disk for #{raid_device}: true")
      true
    else
      Chef::Log.debug("Checking for existing LVM physical disk for #{raid_device}: #{pvscan}")
      Chef::Log.debug("Checking for existing LVM physical disk for #{raid_device}: false")
      false
    end
  end

  def self.lvm_volume_group_exists?(raid_device)
    vgscan = `vgscan`
    if vgscan.match(lvm_volume_group(raid_device))
      Chef::Log.debug("Checking for existing LVM volume group for #{lvm_volume_group(raid_device)}: #{vgscan}")
      Chef::Log.debug("Checking for existing LVM volume group for #{lvm_volume_group(raid_device)}: true")
      true
    else
      Chef::Log.debug("Checking for existing LVM volume group for #{lvm_volume_group(raid_device)}: #{vgscan}")
      Chef::Log.debug("Checking for existing LVM volume group for #{lvm_volume_group(raid_device)}: false")
      false
    end
  end

  def self.lvm_volume_exits?(raid_device)
    wait_for_logical_volumes
    lvscan = `lvscan`
    if lvscan.match(lvm_device(raid_device))
      Chef::Log.debug("Checking for existing LVM volume disk for #{lvm_device(raid_device)}: #{lvscan}")
      Chef::Log.debug("Checking for existing LVM volume disk for #{lvm_device(raid_device)}: true")
      true
    else
      Chef::Log.debug("Checking for existing LVM volume disk for #{lvm_device(raid_device)}: #{lvscan}")
      Chef::Log.debug("Checking for existing LVM volume disk for #{lvm_device(raid_device)}: false")
      false
    end
  end

  def self.exec_command(command, ignore_errors = false)
    Chef::Log.debug("Executing: #{command}")
    output = `#{command} 2>&1`
    if $?.success? || ignore_errors
      Chef::Log.info output
      true
    else
      Chef::Log.fatal output
      false
    end
  end

  def self.translate_device_names(devices, skip = 0)
    if on_kvm? && devices.size > 0
      Chef::Log.info("Running on QEMU/KVM: Starting at /dev/sdb skipping #{skip}")
      new_devices = ('b'..'z').to_a[0 + skip, devices.size].each_with_index.map {|char, index| [ devices[index], "/dev/sd#{char}" ]  }
      Chef::Log.info("Running on QEMU/KVM: Translated EBS devices #{devices.inspect} to #{new_devices.map{|d| d[1]}.inspect}")
      new_devices
    else
      devices
    end
  end

  def self.available_device_id(range_regex)
    current_devices = range_regex ? Dir.glob("#{range_regex}*") : Dir.glob('/dev/xvd*')
    if current_devices.empty?
      range = "#{range_regex}"
      range.slice!('/dev/xvd')
      range.slice!('[')
      range.slice!(']')
      devid = range[0,1]
    else
      last_device = current_devices.sort.last
      last_device.slice!('/dev/xvd')
      devid = last_device[0,1].succ
      if devid == 'b'
        devid.succ
      end
    end    
  end
  
  def self.on_kvm?
    `cat /proc/cpuinfo`.match(/QEMU/)
  end
end
