http://docs.hp.com/en/B3901-90007/ch05s09.html
http://www.nongnu.org/avr-libc/user-manual/group__util__setbaud.html
http://en.wikipedia.org/wiki/Circular_buffer
http://en.wikipedia.org/wiki/Operators_in_C_and_C%2B%2B
http://en.wikipedia.org/wiki/Modulo_operation


The structure of an Ibus packet is the following :
 -	Source Device ID The device which needs to send a message to another device
 -	Length The length of the packet whithout Source ID and length it-self.
 -	Destination Device ID The device which must receive the message
 -	Data The message to send to Destination ID
 -	XOR CheckSum This byte is used to check the integrity of the message. 
         The receiver will compare that value with its own computation, and
         if not equal, will reject the packet.

Messages we understand:
    src: 0x68 (radio)
        dest: 0x73 (satellite radio)
    
            cmd: 0x01 — "are you there" from radio; sent every 10s or so
            cmd: 0x3D
                data byte 1:
                    0x00 — power @todo
                    0x01 — mode @todo
                    0x02 — now @todo
                    0x03 — channel up
                    0x04 — channel down
                    0x05 — channel up and hold
                    0x06 — channel down and hold
            
                    0x08 — preset button pressed
                    0x09 — preset button press and hold
                        data byte 2 is preset number (0x01, 0x02, … 0x06)
            
                    0x0D — "m" @todo
                
                    0x0E — INF (press?) @todo
                    0x0F — INF (press and hold?) @todo
                        may need to ack 0x0E before we get 0x0F
            
                    0x14 — SAT pressed and held
                    0x15 — SAT pressed

Messages we send:
    src: 0x73 (satellite radio)
        dest: 0xFF (broadcast)
            data: 0x02 0x00 — poll response (sent for "are you there" from radio)
            data: 0x02 0x01 — announcement when bus activates
    
        dest: 0x68
            data byte 1: 0x3E
                all follow format
                    0x3E xx yy CC BP zz .. .. .. ..
                where:
                    xx yy — sub-command bytes
                    CC    — channel
                    B     — band nibble
                    P     — preset nibble (0-6)
                    zz    — command end byte (no idea, really)
                    ..    — text
                
                0x00 0x00 CC BP 04
                    response to power, mode
                
                // what is the 2nd byte? 0x00, 0x06, 0x07
                0x01 0x00 CC BP 04 ..
                    send text to show on head unit
                    limit of 8 or 9 characters. does not need to be refreshed
                    until it changes (I think)
                
                0x01 0x06 CC 01 01 ..
                    ack INF press. note diff't end byte, band 0, preset 1
                
                0x01 0x07 CC 01 01 ..
                    ack INF2 press. note diff't end byte, band 0, preset 1
                
                0x02 0x00 CC BP 04 '        '
                    response to channel up/down, "what now", preset and sat
                    button presses; text sent is 8 spaces

Button presses and interactions that cause ACQUIRING to (re)appear
    • pressing SAT

Other observances:
    • holding "M" seems to force a "now" command, but a single press of "M" does nothing


characters:
    ~ == ->
 \x7f == <-

== 10/14/2010 ==
so, basically "now" equates to stopping a long-running button press, and/or asking for a status update.

questions for Josh's setup:
• what does the SDRS transmit on startup?
• … when the radio is powering off (if anything(?))
• … when the radio switches modes (if anything(?))
• … in response to "now"?

• verify button presses above

• what does a single "M" push do? -- nothing
• … and does it change the operation of any other buttons? -- no
• what does a single "SAT" press do? -- changes preset bank

• what sequence of commands is sent after a channel change?
• … after an ESN request (hold "sat")

• how change band (actually, preset bank)? -- sat
