# Homelab backup setup

If you want to use this setup, you can head to the [later section](#setup) dealing with setup.

## Background

This is my current setup to backup my homelab which is a truenas server while trying to follow the [3-2-1 backup rule](https://en.wikipedia.org/wiki/Backup#3-2-1_backup_rule).

The main server is backed up in three places:

| Copy | Where | How | Frequency |
|---|---|---|---|
| Primary | Main server (`krupskaya`), mirrored pool | Actual live data | – |
| Remote backup | ThinkPad (`ilyich`) at remote site, pool `tank` | Pull replication | Daily |
| Cold backup | USB HDD, pool `coldbackup`, stored disconnected | Local replication on main server | Weekly |

I have [tailscale](https://tailscale.com/blog/how-tailscale-works) setup on both machines and I use that for `krupskaya` to be reachable from `ilyich`. 

## Cold backup

This one is straightforward. The cold backup drive is connected to the main server once a week, updated, then exported and unplugged. The idea is mainly if the main machine has malware or any sort of electrical problems that could corrupt live data, I always have an offline copy that will be unaffected. 

To set this up all you need to do is connect the drive via USB, import the pool as `coldbackup`, add a replication task with the source as the main pool and destination as `coldbackup`,run it and unplug. I do this once a week. 

## Remote backup

This one takes more setup. I have a SATA HDD sitting in a USB enclosure that is always connected to an old Thinkpad running TrueNAS. I've read [it is not ideal to be using drives connected via USB in zfs](https://forums.truenas.com/t/why-you-should-avoid-usb-attached-drives-for-data-pool-disks/1499) but for me the worst case if the backup fails is just going over to the second location and debugging which isn't that inconvenient personally. So far I've had no issues. I've also added a `boot_check` script to address some of the concerns of using a USB connected drive. 

`ilyich` (remote server) is off most of the day. Every night it wakes on an RTC alarm at 2:00AM, pulls new snapshots from `krupskaya` over Tailscale, sends a status report back to `krupskaya`, and powers itself off again. Once a day, `krupskaya` checks the newest report and emails if anything looks wrong. 

```
02:00  ilyich wakes (RTC alarm)
       └─ boots, imports pool "tank", starts tailscale
       └─ Post Init: boot_check.sh confirms tank is online
~02:10 replication task "krupskaya backup" pulls snapshots over ssh
~02:30 shutdown.sh: waits for replication ( + weekly scrub if it is Sunday)
       └─ sends report to krupskaya, sets RTC alarm for the next wakeup, powers off
Later  krupskaya: check_remote_backup.sh reads the report, emails on problems
```

## SSH setup

This will allow the backup server to reach the main server. I have installed tailscale on both machines and added them to the same tailnet and noted down their tailnet IP addressed (should be something like 100.XXX.XXX.XXX).

| Key | Private half lives on | Public half lives on |
| --- | --- | --- |
| `ilyich`'s user key | `ilyich`: `/root/scripts/main.pem` | `krupskaya`: the login user's Authorized Keys |
| `krupskaya`'s host key | `krupskaya`: `/etc/ssh/ssh_host_ed25519_key` (already exists) | `ilyich`: `/root/scripts/known_hosts` |


## Scripts

| Script | Runs on | Triggered by | Location |
| --- | --- | --- | --- |
| `boot_check.sh` | `ilyich` | Post Init script | `/root/scripts/` |
| `shutdown.sh` | `ilyich` | Cron, shortly after replication starts | `/root/scripts/` |
| `check_remote_backup.sh` | `krupskaya` | Cron, once a day | `/mnt/data/scripts/` |

### `ilyich` : `/root/scripts/boot_check.sh`

This script tries to address a few of the concerns of using a USB attached drive by adding a recovery mechanism from the disk not being ready and also making shutdowns more safe by using the `manage_shutdown` setting in Linux which tells the kernel to spin the disk down when shutting down. It waits for 2 mins to see if the drive is imported. If successful, it resets a retry counter, enables `manage_shutdown` (which is reset on every boot) and completes. If unsuccessful, it resets the enclosure. If the disk reports a non zero size it then reset the whole machine hoping that a fresh import will fix the issue. It tries 3 times in 30 min intervals after which it gives up. 

Added as a PostInit script in the TrueNAS UI.

### `ilyich` : `/root/scripts/shutdown.sh`

This script runs a little after the laptop has woken up to check if the backup is complete and is responsible for shutting down the machine after and scheduling the next wakeup. On Sunday it starts a [scrub](https://openzfs.github.io/openzfs-docs/man/master/8/zpool-scrub.8.html) after the backup is done. It also builds a report and appends to a file on the main machine so I can view information of recent backups since the remote machine is mostly offline. I also have a mechanism to signal to the remote machine to stay on if I want to do any debugging of some sort. If the remote machine sees that the file `/mnt/data/ilyich/stay_on` exists on the main machine, it will not shutdown after the backup and stay on.

Added as a cron job in the TrueNAS UI that runs once a day at 2:30AM.


### `krupskaya` : `mnt/data/scripts/check_remote_backup.sh`

This is responsible to check the backup report file written by the remote server and report by email if there any issues. It only sends a weekly "OK" message if no issues were found all week.

## Setup

If anyone wants to use this setup, you can follow the following instructions:


### Setup on the backup server

1. **Create the scripts folder** on the boot pool:

   ```bash
   sudo mkdir -p /root/scripts && sudo chmod 700 /root/scripts
   ```
2. **Create BACKUP's user key** and print its public half for MAIN's Authorized Keys. This is used in the MAIN server setup step 4:

   ```bash
   sudo ssh-keygen -t ed25519 -N "" -f /root/scripts/main.pem -C "backup-report"
   sudo cat /root/scripts/main.pem.pub
   ```
3. **Record MAIN's host key,** then compare its fingerprint with MAIN's real one (see SSH keys explained) before trusting it:

   ```bash
   sudo ssh-keyscan -t ed25519 <MAIN_TAILSCALE_IP> > /root/scripts/known_hosts
   sudo ssh-keygen -lf /root/scripts/known_hosts
   ```
4. **Create the pull replication task** under Data Protection → Replication Tasks. Source is MAIN over an SSH connection, destination is a dataset on the backup pool (for example `tank/remote_backup`), and it runs on a schedule a few minutes after `WAKE_TIME`. I run it at 2:05AM (5 minutes after wakeup).
5. **Install `shutdown.sh` and `boot_check.sh`** in `/root/scripts/`, and edit their settings: pool name, MAIN's login and Tailscale IP, the report and flag paths on MAIN, and `WAKE_TIME` (the same value in both). Then:

   ```bash
   sudo chmod 700 /root/scripts/*.sh && sudo chmod 600 /root/scripts/main.pem
   ```
6. **Find the USB enclosure's ID** for `USB_ID` in `boot_check.sh`. It's the `ID xxxx:yyyy` value on the enclosure's line in the output of `lsusb`. Skip this if you're not using USB enclosure. 
7. **Add the boot check** under System → Advanced → Init/Shutdown Scripts: type Script, path `/root/scripts/boot_check.sh`, when Post Init, **timeout 600**.
8. **Schedule the shutdown** under System → Advanced → Cron Jobs: command `bash /root/scripts/shutdown.sh`, user `root`. Run it a little after replication starts. I set mine to 2:30AM since my replication starts at 2:05AM.
9. **Apply the spin-down setting once by hand,** because the first shutdown happens before the first boot check:

   ```bash
   sudo bash /root/scripts/boot_check.sh
   cat /sys/class/scsi_disk/*/manage_shutdown      # should say 1
   ```

### Main server setup

1. **Create the report folder** `/mnt/data/backup-reports/`.
2. **Pick the login user** BACKUP will use. I use `truenas_admin`. That user needs write permission on the report folder.
3. **Enable the SSH service** under System → Services → SSH, and set it to start automatically.
4. **Authorize BACKUP's user key.** Under Credentials → Users → (login user) → Edit → Authorized Keys, paste the public key from the BACKUP setup (step 2 there). Adding it through the UI keeps it in TrueNAS's saved configuration; a hand-edited `authorized_keys` file can be lost.
5. **Authorize the replication key.** Add the public key of the SSH connection BACKUP's replication task uses. If that connection logs in as a non-root user, enable "Allow passwordless sudo for zfs commands" for that user.
6. **Install `check_remote_backup.sh`** in a scripts folder on a dataset. Set `LOG` to the report log path and `REMOTE_NAME` to BACKUP's name.
7. **Schedule the watchdog** under System → Advanced → Cron Jobs: command `bash /mnt/data/scripts/check_remote_backup.sh`, user `root`, once a day. Run it well after BACKUP's report normally arrives. On scrub days the report only comes after the scrub finishes, which can take several hours.
8. **Test email** by running the script once by hand with an empty test log path, and confirm the "no log found" email arrives.



