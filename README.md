# instance-guestfish
Ganeti OS-Interface utilizing [guestfish](https://libguestfs.org/guestfish.1.html). A secure and programatic way to modify instance disks.

## Usage
* Step 1: provide a source for provisioning your instances:
  * create a tar ball with debootstrap (use `examples/debian_ubuntu.sh`)
  * _create your own image via a ISO install_ (needes example documentation, image source not implemented yet)
  * _use public cloud images (e.g. openstack)_ (examples needed, image source not implemented yet)

* Step 2: provide a distribution mechanism for your sources
  * copy the sources to every node (simple, stupid, time/disk consuming)
  * supply a HTTP server to stream your sources
  * supply the sources via a NFS mount to all your nodes (good, when NFS Server at hand)
  * store your source as a Ceph image
  * use a public HTTP server for cloud images

* Step 3: configure your OS variant
  * is the source an image or a tar ball?
  * is the source compressed?
  * what's the minimum disk size needed?
  * should ssh-keys or password be deployed?

## OS variant configuration

For the moment see comments in `variants/default.env`
