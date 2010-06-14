#!/usr/bin/env python
# encoding: utf-8
"""
untitled.py

Created by Brian Lalor on 2010-04-21.
Copyright (c) 2010 __MyCompanyName__. All rights reserved.
"""

import sys
import os
from pprint import pprint 
import string
import serial
import time
import cPickle as pickle

# alextronic: http://translate.google.com/translate?js=y&prev=_t&hl=en&ie=UTF-8&layout=1&eotf=1&u=http%3A%2F%2Fwww.alextronic.de%2Fbmw%2Fprojects_bmw_info_ibus.html&sl=de&tl=en
# http://ibus.stuge.se/IBus_Devices
id_map = {
    0x00 : 'Broadcast',
    0x18 : 'CDW - CDC CD-Player',
    0x30 : 'SES (voice)', # alextronic
    0x3B : 'NAV/GT Navigation/Videomodule (graphics driver, navigation)',
    0x3F : 'DIS (ext. diagnostic system)', # alextronic
    0x43 : 'MenuScreen',
    0x44 : '?????',
    0x50 : 'MFL Multi Functional Steering Wheel Buttons',
    0x60 : 'PDC Park Distance Control',
    0x68 : 'RAD Radio',
    0x6A : 'DSP Digital Sound Processor',
    0x73 : 'SDRS',
    0x7F : 'GPS',
    0x80 : 'IKE Instrument Kombi Electronics',
    #0xA8 : '?????',
    0xBB : 'TV Module',
    0xBF : 'GLO global broadcast', # 'LCM Light Control Module, or maybe broadcast?',
    0xC0 : 'MID Multi-Information Display Buttons',
    0xC8 : 'TEL Telephone',
    0xD0 : 'Navigation Location/Data', # alextronic
    0xE7 : 'OBC TextBar',
    #0xE8 : '?????',
    0xED : 'Lights, Wipers, Seat Memory',
    0xF0 : 'BMB Board Monitor Buttons',
    0xFF : 'Broadcast',
    
    ## seen on my MINI
    0xA4 : 'ABM Airbag',
    0x5B : 'IHK Integrated heating, A/C',
}

sat_channel = 1
sat_band = 1
sat_preset = 1

# The structure of an Ibus packet is the folllowing :
## -	Source Device ID The device which needs to send a message to another device
## -	Length The length of the packet whithout Source ID and length it-self.
## -	Destination Device ID The device which must receive the message
## -	Data The message to send to Destination ID
## -	XOR CheckSum This byte is used to check the integrity of the message. 
##         The receiver will compare that value with its own computation, and
##         if not equal, will reject the packet.

def make_printable(x):
    if x in string.printable:
        return x
    else:
        return "."
    



## all args are 2-char hex strings; data is space-separated
def make_packet(src, dest, data, text = ""):
    print 'make_packet(%s, %s, %s, %s)' % (src, dest, data, text)
    
    # add two for length and checksum bytes
    data_len = len(data.split()) + len(text) + 2
    
    packet = [src, '%.2X' % (data_len,), dest]
    packet.extend(data.split())
    print 'packet:', packet
    bin_packet = "".join([chr(int(x, 16)) for x in packet])
    #print bin_packet
    bin_packet += text
    #print bin_packet
    
    chksum = 0
    for b in bin_packet:
        chksum ^= ord(b)
    
    bin_packet += chr(chksum)
    #print " ".join(['%.2X' % (ord(b),) for b in bin_packet])
    # ser.write("".join([chr(int(x, 16)) for x in "73 04 FF 02 01 8B".split()]))
    return bin_packet    


def display_packet_data(packet, ser):
    whole_hex_packet = " ".join(['%.2X' % (b,) for b in packet])
    global sat_channel
    global sat_band
    global sat_preset
    
    ## http://web.comhem.se/bengt-olof.swing/stwbuttons.htm
    buttons = {
        '50 04 68 32 10 1E' : '<-> press',
        '50 04 68 32 11 1F' : '<+> press',
        '50 04 68 32 30 3E' : '<-> release',
        '50 04 68 32 31 3F' : '<+> release',
        
        '50 04 68 3B 01 06' : '<next> press',
        '50 04 68 3B 11 16' : '<next> 1 second',
        '50 04 68 3B 21 26' : '<next> release',
        
        '50 04 68 3B 08 0F' : '<previous> press',
        '50 04 68 3B 18 1F' : '<previous> 1 second',
        '50 04 68 3B 28 2F' : '<previous> release',
        
        '50 04 C8 3B 80 27' : '<R/T>',
        '50 04 C8 3B 80 27' : '<voice> press',
        '50 04 C8 3B 90 37' : '<voice> hold',
        '50 04 C8 3B A0 07' : '<voice> release',
    }
    
    cd_cmd = " ".join(['%.2X' % (b,) for b in packet[3:-6]])
    
    # 18 0a 68 39 02 09 00 3f 00 06 22 53
    #          39 02 09                     -- cmd prefix
    #                   00                  -- literal
    #                      3f               -- populated CDs (bitmask)
    #                         00            -- literal
    #                            06 22      -- disc, track
    #                                  53
    # command prefix, disc, track, checksum
    cd_changer = {
        '39 00 02' : 'CD and Track Status Not Playing Response',
        '39 00 09' : 'CD and Track Status Playing Response',
        '39 02 09' : 'Track Start Playing',
        '39 03 09' : 'CD Status Scan Forward',
        '39 04 09' : 'CD Status Scan Backward',
        '39 07 09' : 'Track End Playing',
        '39 08 09' : 'CD # dd',
        '39 08 09' : 'CD Seeking',
        '39 08 09' : 'Loaded CD 1,2,3,4,5,6',
        '39 08 09' : 'Track # tt',
    }
    
    sdrs_rx = {
        'sPoll'  : '01',    # 68 03 73 , chksum  19
        
        'sPower' : '3D 00 00', # 68 05 73 , chksum  23
        'sMode'  : '3D 01 00', # 68 05 73 , chksum  22
        'sNow'   : '3D 02 00', # 68 05 73 , chksum  21
        'sUp'    : '3D 03 00', # 68 05 73 , chksum  20
        'sDown'  : '3D 04 00', # 68 05 73 , chksum  27
        'sUpH'   : '3D 05 00', # 68 05 73 , chksum  26
        'sDownH' : '3D 06 00', # 68 05 73 , chksum  25
        
        
        'sPre1'  : '3D 08 01', # 68 05 73 , chksum  2A
        'sPre2'  : '3D 08 02', # 68 05 73 , chksum  29
        'sPre3'  : '3D 08 03', # 68 05 73 , chksum  28
        'sPre4'  : '3D 08 04', # 68 05 73 , chksum  2F
        'sPre5'  : '3D 08 05', # 68 05 73 , chksum  2E
        'sPre6'  : '3D 08 06', # 68 05 73 , chksum  2D
        
        'sPreH1' : '3D 09 01', # 68 05 73 , chksum  2B
        'sPreH2' : '3D 09 02', # 68 05 73 , chksum  28
        'sPreH3' : '3D 09 03', # 68 05 73 , chksum  29
        'sPreH4' : '3D 09 04', # 68 05 73 , chksum  2E
        'sPreH5' : '3D 09 05', # 68 05 73 , chksum  2F
        'sPreH6' : '3D 09 06', # 68 05 73 , chksum  2C
        
        'sM'     : '3D 0D 00', # 68 05 73 , chksum  2E
        'sInf1'  : '3D 0E 00', # 68 05 73 , chksum  2D
        'sInf2'  : '3D 0F 00', # 68 05 73 , chksum  2C
        
        'sSat2?' : '3D 14 00', # sent for press-and-hold of SAT
        'sSat'   : '3D 15 00', # 68 05 73 , chksum  36
    }
    
    sdrs_tx = {
        'power': "73 10 68 3e 00 00 01 11 04 70 6f 77 65 72 20 20 20 7e",
    }
    ## if whole_hex_packet in buttons:
    ##     print buttons[whole_hex_packet]
    ## 
    ## elif cd_cmd in cd_changer:
    ##     print "%s: disc %X, track %X, CDs loaded %s" % (cd_changer[cd_cmd],
    ##                                                     packet[-3],
    ##                                                     packet[-2],
    ##                                                     bin(packet[7]))
    ##     
    ## 
    ## elif (packet[1] == 3) and (packet[3] == 1):
    ##     print "device status request"
    ## elif (packet[1] == 4) and (packet[3] == 2):
    ##     print "device status response"        
    ## elif (packet[3] == 0x18) and (packet[2] == 0xBF):
    ##     # speed
    ##     speed, rpm = packet[4:6]
    ##     print "speed: %dmph, %d RPM" % (speed * 0.621371192 * 2, rpm * 100)
    ## elif (packet[3] == 0x11):
    ##     key_pos = "unknown"
    ##     
    ##     if packet[4] & 1 == 1:
    ##         key_pos = "acc"
    ##     elif packet[4] & 2 == 2:
    ##         key_pos = "run"
    ##     elif packet[4] & 3 == 3:
    ##         key_pos = "start"
    ##     
    ##     print "key in '%s' position" % (key_pos,)
    if packet[2] == 0x73:
        sat_cmd = " ".join(['%.2X' % (b,) for b in packet[3:-1]])
        
        for cmd_key in sdrs_rx:
            if sdrs_rx[cmd_key] == sat_cmd:
                sat_cmd = cmd_key
                break
        
        # print "satrad destination!", sat_cmd
        
        if sat_cmd == 'sPoll':
            print "responding to poll"
            ser.write(make_packet('73', 'FF', '02 00'))
        
        elif sat_cmd == 'sPower':
            print 'responding to power'
            ser.write(make_packet('73', '68',
                                  '3E 00 00 %.2X %d%d 04' % (sat_channel, sat_band, sat_preset)))
        elif sat_cmd == 'sMode':
            print 'responding to mode'
            ser.write(make_packet('73', '68',
                                  '3E 00 00 %.2X %d%d 04' % (sat_channel, sat_band, sat_preset)))
        elif sat_cmd == 'sNow':
            print 'responding to now'
            ser.write(make_packet('73', '68',
                                  '3E 02 00 %.2X %d%d 04' % (sat_channel, sat_band, sat_preset), "        "))
        elif sat_cmd == 'sUp':
            print 'responding to channel up'
            sat_channel += 1
            ser.write(make_packet('73', '68',
                                  '3E 02 00 %.2X %d%d 04' % (sat_channel, sat_band, sat_preset), "        "))
        
        elif sat_cmd == 'sDown':
            print 'responding to channel down'
            sat_channel -= 1
            ser.write(make_packet('73', '68',
                                  '3E 02 00 %.2X %d%d 04' % (sat_channel, sat_band, sat_preset), "        "))
        elif sat_cmd == 'sSat':
            ser.write(make_packet('73', '68',
                                  '3E 01 00 %.2X %d%d 04' % (sat_channel, sat_band, sat_preset),
                                  "What??"))
        else:
            print "unhandled satrad command", sat_cmd
        
    
    ## elif packet[0] == 0x73:
    ##     ## ignore the SDRS packets we're sending out
    ##     pass
    else:
        print "unknown packet"
        print " ".join(['%.2x' % (b,) for b in packet[3:-1]])
        print " ".join(['%2s' % (make_printable(chr(b)),) for b in packet[3:-1]])
    

    
def main():
    global ser
    messages = [
        'start',
        'TestingAsdfDsa',
        'T estingAsdfDsa',
        'Te stingAsdfDsa',
        'Tes tingAsdfDsa',
        'Test ingAsdfDsa',
        'Testi ngAsdfDsa',
        'Testin gAsdfDsa',
        'Testing AsdfDsa',
        'TestingAsdfDsa',
        'end',
    ]
    msg = "".join([chr(b) for b in range(256)])
    msg_ind = 0
    max_msg_len = 8
    
    ser = serial.Serial(port = '/dev/tty.usbserial-FTE4Y0J6',
                        baudrate = 9600,
                        bytesize = 8,
                        parity = 'E',
                        stopbits = 1,
                        timeout = 0.25)
    
    ser.open()
    
    buf = [int(x, 16) for x in "73 04 FF 02 01 8B".split()]
    dropped = []
    
    next_sdrs_bcast = time.time() + 10
    next_sdrs_text = time.time() + 1
    
    print "sending sat radio announce"
    ser.write(make_packet('73', 'FF', '02 01'))
    text_count = 0
    while True:
        if time.time() > next_sdrs_bcast:
            # send out the announce message
            ## print "sending sat radio announce"
            ## ser.write(make_packet('73', 'FF', '02 01'))
            
            ## print "sending cd changer radio announce"
            ## ser.write("".join([chr(int(x, 16)) for x in "18 04 FF 02 01 E0".split()]))
            next_sdrs_bcast = time.time() + 10
        
        # if time.time() > next_sdrs_text:
        #     next_sdrs_text = time.time() + 1
        #     #if text_count > 2: continue
        #     
        #     print "sending text to sad rad", msg_ind
        #     if msg_ind > len(msg) - 1:
        #         msg_ind = 0
        #     
        #     text = msg[msg_ind:msg_ind+max_msg_len]
        #     #print 'text:', text
        #     
        #     ser.write(make_packet('73', '68',
        #                           '3E 01 00 %.2X %d%d 04' % (sat_channel, sat_band, sat_preset),
        #                           text))
        #     
        #     time.sleep(1)
        #     ser.write(make_packet('73', '68',
        #                           '3E 01 00 %.2X %d%d 05' % (sat_channel, sat_band, sat_preset),
        #                           text))
        #     
        #     
        #     msg_ind += 1
            
            
            
            
        if len(buf) < 2:
            # prime the buffer with two bytes
            buf = [ord(b) for b in ser.read(2)]
        
        #print "buf:", ['%.2x' % (b,) for b in buf]
        
        if len(buf) < 2:
            # no more data
            continue
        
        data_len = buf[1]
        
        if (data_len == 0): # or (data_len == 255):
            # can't have zero length; FF may be invalid, too
            dropped.append(buf.pop(0))
            #print 'dropping %.2x: invalid data length %.2x' % (dropped, data_len)
            continue
        
        if buf[0] not in id_map:
            dropped.append(buf.pop(0))
            print 'dropping %.2x: unknown src' % (dropped[-1],)
            continue
        
        # print "data_len: %d; have %d bytes" % (data_len, len(buf) - 2)
        if len(buf) < data_len + 2:
            amt_to_read = (data_len + 2) - len(buf)
            # print "reading %d bytes" % (amt_to_read,)
            buf.extend([ord(b) for b in ser.read(amt_to_read)])
        
        if len(buf) < data_len + 2:
            print "ran out of data:", " ".join(['%.2x' % (b,) for b in buf])
            continue
        
        #print "buf:", ['%.2x' % (b,) for b in buf]
        provided_checksum = buf[data_len + 1]
        calculated_checksum = 0
        for b in buf[:data_len + 1]:
            calculated_checksum ^= b
        
        if provided_checksum == calculated_checksum:
            if dropped:
                print "dropped data:", " ".join(['%.2x' % (b,) for b in dropped])
                dropped = []
            
            #print "woo hoo!"
            packet = buf[0:data_len + 2]
            #print 
            
            src = packet[0]
            src_name = "<unknown>"
            if src in id_map:
                src_name = id_map[src]
            
            dest = packet[2]
            dest_name = "<unknown>"
            if dest in id_map:
                dest_name = id_map[dest]
            
            data = packet[3:-1]
            
            if True: #src != 0x73:
                print '[%s] %.2x [%-10s] -> %.2x [%-10s]: %s' % (time.ctime(),
                                                         src, src_name,
                                                         dest, dest_name,
                                                         " ".join(['%.2x' % (b,) for b in packet]))
                ## print time.ctime()
                ## print "Source Device     : %.2x - %s" % (src, src_name)
                ## print "Destination Device: %.2x - %s" % (dest, dest_name)
                ## print "Data  - - - - - - - - - - - -"
                display_packet_data(packet, ser)
                ## print "Full Packet - - - - - - - - -"
                ## print " ".join(['%.2x' % (b,) for b in packet])
                ## print "-----------------------------"
            
            del buf[0:data_len + 2]
        else:
            dropped.append(buf.pop(0))
            # print 'dropping %.2x: invalid checksum %.2x' % (dropped, provided_checksum)
    
    ## for b in [ord(b) for b in ser.read()]:
    ##     id = None
    ##     if b in id_map:
    ##         id = id_map[b]
    ##     
    ##     if id:
    ##         print >>sys.stdout, '%.2x [%s] ' % (b,id)
    ##     else:
    ##         print >>sys.stdout, '%.2x ' % (b,)
        
    
    sys.stdout.flush()


if __name__ == '__main__':
    main()

