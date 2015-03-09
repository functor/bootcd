# Purpose
Let us try to shorten the devel loop when playing with changes to the bootcd internals.
And namely, the set of systemd files that describe booting off the CD image


# Environment

## the 'try this out several times' utility

* The utility sits in `git/tests/system`  

* you can push it onto a specific build using `make sync` as usual

* and then run it on the testmaster side like this

  `iterate-ping-node -o run01 <nb_iterations>`

* This allows to run a given bootcd (the iso computed for one node) several times over, and to gather all logs from qemu
* This is **only** restarting the kvm/qemu node several times, nothing is done to recompute the .iso itself (see below for that). So the game is to easily simulate how a change to `bootcd` would affect a node ISO without rebuilding the whole damn thing
* When -o is provided, the directory argument is created and all log files are stored in there

# Easily redo a .iso

## preparation

* select a running test in testmaster/; like e.g. one that has failed the `ping_node` step already

* you will need one local terminal in `git/bootcd`

* do the usual routine on running `exp`, exposing variables in this terminal

* and run `make sync-unwrap` from this workdir `bootcd`

At that point there will be the following files and subdirs on the KVM host (in my case boxtops)

* the normal node bootCD iso, like e.g. 
  * `vnode01.pl.sophia.inria.fr.iso` 
* a copy of that file, like e.g. 
  * `vnode01.pl.sophia.inria.fr.iso.ref` 
* a read-only copy of the bootcd image in `bootcd.ref/`
* a writable version of this in `bootcd/`
* a read-only copy of the overlay image in `overlay.ref/`
* a writable version of this in `overlay/`

## iteration

The workflow from then on is you can

* change the layout/contents of the `bootcd/` directory on the KVM host
  * either manually right in the KVM host, and/or with
  * `make sync-push` if you want to rsync the contents of `initscripts/` and ` systemd/` workdirs onto KVM 
* and then rewrap the ISO image and hammer on it, and for this you run
  * `make sync-rewrap` from the `bootcd/` workdir, and then
  * `iterate-ping-node` from the `tests/` workdir

Once you're satisfied you can make a difference between bootcd/ and bootcd.ref/ to see how the changes need to be implemented in `build.sh` and/or `prep.sh`
