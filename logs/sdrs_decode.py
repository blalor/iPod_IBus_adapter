#!/usr/bin/env python
# encoding: utf-8
"""
sdrs_decode.py

Created by Brian Lalor on 2010-10-14.
Copyright (c) 2010 __MyCompanyName__. All rights reserved.
"""

import sys
import os
import string
from datetime import datetime, timedelta

def make_printable(x):
    if x in string.printable:
        return x
    else:
        return "."


ADDRS = {
    '68' : 'RAD',
    '73' : 'SDRS',
    'FF' : 'BCST',
}

RAD_CMDS = {
    '01 00' : "turn off, or mode (deactivate?)",
    '02 00' : "Request status update ('now')",
    '03 00' : 'channel up',
    '04 00' : 'channel down',
    '05 00' : 'hold channel up',
    '06 00' : 'hold channel down',
    '07 00' : 'hold "M"',
    '08 01' : 'recall preset 1',
    '08 02' : 'recall preset 2',
    '08 03' : 'recall preset 3',
    '08 04' : 'recall preset 4',
    '08 05' : 'recall preset 5',
    '08 06' : 'recall preset 6',
    '09 01' : 'set preset 1',
    '09 02' : 'set preset 2',
    '09 03' : 'set preset 3',
    '09 04' : 'set preset 4',
    '09 05' : 'set preset 5',
    '09 06' : 'set preset 6',
    '14 00' : 'hold SAT (ESN request)',
    '15 00' : 'SAT',
    '15 01' : '<UNKNOWN>',
    '0E 00' : 'inf, 1st press (artist)',
    '0F 00' : 'inf, 2nd press (song)',
}

def main():
    last_timestamp = None
    
    for line in sys.stdin.readlines():
        line = line.strip()
        
        timestamp = datetime.strptime(line[:23], '%Y-%m-%d %H:%M:%S.%f')
        packet = line[26:].split()
        
        if packet[0] == '!': continue
        
        # print packet
        src = packet[0]
        dest = packet[2]
        
        desc = None
        
        if (src in ['68', '73']) and (dest in ['73', '68', 'FF']):
            # print "%s:  %s" % (timestamp, " ".join(packet[3:-1]))
            
            # from rad to sdrs
            cmd = packet[3]
            data = packet[4:-1]
            cmd_id = '??'
            
            desc = '"' + "".join([make_printable(chr(int(x, 16))) for x in data]) + '"'
            
            if (src == '68') and (dest == 'FF') and (cmd == '02'):
                # 68 04 FF 02 04 95
                # RAD  --> LOC : Device status ready Bit2
                desc = "Device status ready Bit2"
            
            elif (src == '68') and (dest == '73') and (cmd == '01'):
                # 68 03 73 01 19
                # RAD  --> SDRS: Device status request
                desc = "Device status request"
            
            elif (src == '73') and (dest == '68') and (cmd == '02'):
                # 73 04 68 02 00 1D
                # SDRS --> RAD : Device status ready
                desc = "Device status ready"
            
            elif (src == '68') and (cmd == '3D'):
                cmd_id = data[0]
                desc = RAD_CMDS[" ".join(data)]
            
            elif (src == '73') and (cmd == '3E'):
                cmd_id = data[0]
                # '00'
                
                if cmd_id in ('01', '02', '03', '04', '05', '11', '12'):
                    # 01 00 18 12 04 4C 69 74 68 69 75 6D 20 52
                    # 02 00 18 12 04 4C 69 74 68 69 75 6D 20 51
                    channel = int(data[2], 16)
                    
                    preset_byte = int(data[3], 16)
                    preset_band = preset_byte >> 4;
                    preset_num = preset_byte & 0x0F;
                    
                    # data[4] is always 0x04
                    scan = "    "
                    
                    if cmd_id in ('01', '11'):
                        if data[1] == '00':
                            name_tag = 'Chan text update'
                        elif data[1] == '06':
                            name_tag = 'INF1 text update'
                        elif data[1] == '07':
                            name_tag = 'INF2 text update'
                        elif data[1] == '0C':
                            name_tag = 'ESN text update'
                        else:
                            name_tag = 'UNKN text update'
                        
                        if cmd_id == '11':
                            scan = "[SC]"
                    
                    elif cmd_id in ('02', '12'):
                        name_tag = 'Status update'
                        
                        if cmd_id == '12':
                            scan = "[SC]"
                        
                    
                    elif cmd_id == '03':
                        name_tag = 'Chan DN ACK'
                    elif cmd_id == '04':
                        name_tag = 'hold Chan UP update'
                    elif cmd_id == '05':
                        name_tag = 'hold Chan DN update'
                    
                    desc = "%4s %19s: channel %d, preset bank %d, preset num %d | %s" % (
                        scan,
                        name_tag,
                        channel,
                        preset_band,
                        preset_num,
                        "".join([make_printable(chr(int(x, 16))) for x in data[5:]])
                    )
                    
                    
            
            
            if desc != None:
                if last_timestamp == None:
                    delta_t = timedelta(0)
                else:
                    delta_t = timestamp - last_timestamp
                
                print '%5dms:  %-4s --> %-4s: <%-77s> [%s] %s' % (((delta_t.seconds * 1000) + (delta_t.microseconds/1000)), ADDRS[src], ADDRS[dest], " ".join(packet[3:-1]), cmd_id, desc)
            else:
                print line
            
            last_timestamp = timestamp
            
    




if __name__ == '__main__':
    main()

