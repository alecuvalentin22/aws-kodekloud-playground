# Drill 12 — EBS, and why the device name lies

**The question:** "How do you attach storage to an instance and mount it
reliably?"

## The gotcha this drill exists for

Terraform asks for `/dev/sdf`:

```hcl
resource "aws_volume_attachment" "es_data" {
  device_name = "/dev/sdf"
  ...
}
```

On a **Nitro** instance — t3, m5, c5 and everything newer — EBS is presented
over NVMe and **the kernel ignores that name completely**. The disk turns up as
`/dev/nvme1n1`, numbered in *attach order*. Attach a second volume, or reboot
with a different attach sequence, and the numbers move.

```bash
lsblk
# nvme0n1  -> root (30G)
# nvme1n1  -> the data volume (10G)   <- NOT /dev/sdf
```

So `device_name` is only what the AWS API records. Anything that resolves the
disk by that name is broken; anything that resolves it by `/dev/nvme1n1` is
broken *later*, which is worse.

### What is stable

udev builds a symlink from the **volume ID**, with the dash stripped:

```bash
ls -l /dev/disk/by-id/ | grep Elastic
# nvme-Amazon_Elastic_Block_Store_vol0a1b2c3d4e5f -> ../../nvme1n1
```

`roles/storage` resolves the disk that way, and the volume ID reaches Ansible
through the **generated inventory** — Terraform knows it, Ansible needs it, and
`inventory/hosts.ini` is the seam:

```ini
es-01 ansible_host=1.2.3.4 private_ip=172.31.1.10 es_data_volume_id=vol-0a1b2c3d
```

### And mount by UUID, never by device name

```bash
grep elasticsearch /etc/fstab
# UUID=xxxxxxxx-... /var/lib/elasticsearch ext4 defaults,noatime,nofail 0 0
```

A fstab line saying `/dev/nvme1n1` is a latent outage: the host can mount the
wrong disk, or fail to boot into anything but the serial console. The UUID
belongs to the filesystem and travels with it.

`nofail` is there for the same reason — a missing disk should leave the host
reachable over SSH, not drop it into emergency mode.

## Two ordering bugs the role is written to avoid

**1. Never mount over a populated directory.** The `storage` role runs *before*
the `elasticsearch` role for exactly this reason. Mounting on top of a directory
that already has data **hides** the data rather than moving it — and you find
out when the cluster comes back empty.

**2. `chown` after mounting, not before.** Chowning the mount point before the
mount lands on the *underlying* directory, which the mount then hides. The
permissions you set are not the ones in effect, and Elasticsearch cannot write.

There is a third wrinkle: on the very first run the `elasticsearch` user does not
exist yet — the apt package creates it — so the role checks with `getent` and
the `elasticsearch` role chowns again afterwards.

## Why a separate volume at all

- **Data outlives the instance.** `delete_on_termination = false`, so a node can
  be terminated and its disk reattached to the replacement. That is how you
  actually replace a failed ES node.
- **Filling it does not take the OS down.** Drill 03 deliberately fills this
  volume to trip the flood-stage watermark. On a shared root volume that same
  test also breaks sshd, apt and journald.
- **It is small, so the drill is fast.** 10 GiB fills in seconds; 30 GiB does not.
- **It can be grown live** — see drill 03.

## The one that is not recoverable

**EBS is availability-zone scoped.** A volume cannot attach to an instance in a
different AZ, and there is no way to move it other than snapshot → restore into
the other AZ. That is why the Terraform reads the AZ back off the instance:

```hcl
availability_zone = aws_instance.es[count.index].availability_zone
```

rather than setting it independently, where the two could drift apart.

## Say this in the interview

> "Separate EBS volume per data node, `delete_on_termination` off so the data
> survives the instance. The thing that bites people is that on Nitro the device
> name you request is fiction — you ask for `/dev/sdf` and the kernel gives you
> `/dev/nvme1n1`, numbered in attach order. So I resolve the disk through
> `/dev/disk/by-id/` using the volume ID, which Terraform passes to Ansible in
> the generated inventory, and I mount by filesystem UUID in fstab with `nofail`.
> Device names in fstab are how you end up on the serial console."
