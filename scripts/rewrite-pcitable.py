#!/usr/bin/env python

"""
The point of this small utility is to take a file in the format
of /lib/modules/`uname -r`/modules.pcimap and output a condensed, more
easily used format for module detection

The output is used by the PlanetLab boot cd (3.0+) and the pl_hwinit script
to load all the applicable modules by scanning lspci output.

Excepted format of file includes lines of:

# pci_module vendor device subvendor subdevice class class_mask driver_data
cciss 0x00000e11 0x0000b060 0x00000e11 0x00004070 0x00000000 0x00000000 0x0
cciss 0x00000e11 0x0000b178 0x00000e11 0x00004070 0x00000000 0x00000000 0x0

Output format, for each line that matches the above lines:
cciss 0e11:b060 0e11:b178
"""

import os, sys
import string


def usage():
    print( "Usage:" )
    print( "rewrite-pcitable.py <pcitable> [<output>]" )
    print( "" )


if len(sys.argv) < 2:
    usage()
    sys.exit(1)


pcitable_file_name= sys.argv[1]
try:
    pcitable_file= file(pcitable_file_name,"r")
except IOError:
    sys.stderr.write( "Unable to open: %s\n" % pcitable_file_name )
    sys.exit(1)

if len(sys.argv) > 2:
    output_file_name= sys.argv[2]
    try:
        output_file= file(output_file_name,"w")
    except IOError:
        sys.stderr.write( "Unable to open %s for writing.\n" % output_file )
        sys.exit(1)
else:
    output_file= sys.stdout


line_num= 0

# associative array to store all matches of module -> ['vendor:device',..]
# entries
all_modules= {}

for line in pcitable_file:
    line_num= line_num+1
    
    # skip blank lines, or lines that begin with # (comments)
    line= string.strip(line)
    if len(line) == 0:
        continue
    
    if line[0] == "#":
        continue

    line_parts= string.split(line)
    if line_parts is None or len(line_parts) != 8:
        sys.stderr.write( "Skipping line %d (incorrect format)\n" % line_num )
        continue

    # first two parts are always vendor / device id
    module= line_parts[0]
    vendor_id= line_parts[1]
    device_id= line_parts[2]
    

    # valid vendor and devices are 10 chars (0xXXXXXXXX) and begin with 0x
    if len(vendor_id) != 10 or len(device_id) != 10:
        sys.stderr.write( "Skipping line %d (invalid vendor/device id length)\n"
                          % line_num )
        continue

    if string.lower(vendor_id[:2]) != "0x" \
           or string.lower(device_id[:2]) != "0x":
        sys.stderr.write( "Skipping line %d (invalid vendor/device id format)\n"
                          % line_num )
        continue

    # cut down the ids, only need last 4 bytes
    # start at 6 = (10 total chars - 4 last chars need)
    vendor_id= string.lower(vendor_id[6:])
    device_id= string.lower(device_id[6:])

    full_id= "%s:%s" % (vendor_id, device_id)

    if all_modules.has_key(module):
        all_modules[module].append( full_id )
    else:
        all_modules[module]= [full_id,]

for module in all_modules.keys():
    devices= string.join( all_modules[module], " " )
    output_file.write( "%s %s\n" % (module,devices) )

    
output_file.close()
pcitable_file.close()
