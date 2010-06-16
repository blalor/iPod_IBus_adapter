#!/usr/bin/env python
# encoding: utf-8
"""
watch_serial.py

Created by Brian Lalor on 2010-02-20.
Copyright (c) 2010 __MyCompanyName__. All rights reserved.
"""

import sys
import os
import serial

def main():
    ser = serial.Serial(port = sys.argv[1], baudrate = 115200, timeout = 0.25)
    
    # found_data = False
    # while True:
    #     b = ser.read(1)
    #     if b:
    #         found_data = True
    #         print '%.2X' % (ord(b),),
    #     else:
    #         if found_data:
    #             print ""
    #         
    #         found_data = False
    while True:
        line =  ser.readline().strip()
        if line:
            print line
        
    


if __name__ == '__main__':
    main()

