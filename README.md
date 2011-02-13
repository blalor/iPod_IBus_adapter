iPod ↔ Sirius IBus adapter
==========================

This project is an Arduino sketch that presents an iPod or iPhone as a Sirius satellite radio receiver to the head unit (radio) in some MINI and BMW models.  It supports both simple and advanced iPod protocols.  In advanced mode, the radio shows the current track name as the channel text, and artist and album are accessible via the `INF` button.

I originally started this project because I wanted to put the radio from an '06 MINI into my '91 BMW 318is.  The MINI radio must see a valid IBus message in order to operate, otherwise it displays `-DISABLE-` on the screen and doesn't do anything at all.  Spitting out a valid IBus message every now and then would be simple.  But then I realized that iPod adapters (like the Dension ice>Link:Plus I have in my MINI) aren't cheap and most don't do everything I want, so I decided to keep going.

The end result is pretty much what I was going for, but there are some bugs to be worked out.

Compiling
---------

This application currently requires the Arduino IDE.  I'm planning on switching to straight avr-libc, but I need to "port" some of the Arduino facilities, first.  In addition, I had to tweak the Arduino `HardwareSerial` class to get more access to the receive buffer.

### What you need

1. my fork of the [Arduino environment][ard_fork]
2. my fork of the [NewSoftSerial library][NSS]
3. my fork of the [iPodSerial library][ips]

### Setup

1. Build the Arduino environment according to [these steps][ard_build].
2. Find your `libraries` directory; consult [this document][ard_libs]. I'll refer to that directory as `${arduino.libs}` from here on out.
3. Set up the NewSoftSerial library so that `${arduino.libs}/SoftwareSerial/SoftwareSerial.h` exists.
4. Set up the iPodSerial library so that `${arduino.libs}/iPodSerial/iPodSerial.h` exists.
5. Build the hardware according to the [IBus adapter](ibus_adapter_schematic.png) and [iPod board](ipod_board_schematic.png) schematics.
6. Open `ibus_satellite_radio.pde` in the Arduino IDE and upload it to the target board

Hardware
--------

[Main schematic](ibus_adapter_schematic.png)  
[iPod schematic](ipod_board_schematic.png), [iPod board layout](ipod_board_layout.png)

The schematic shows an ATMega168; a '328 is required.  The iPod board goes into the iPod connector housing.  It's a total pain in the ass.  The boards I had made were at least twice as thick as the connector would allow.  I ended up making them with thinner copper clad board at home.

I've had good luck with the AMIS-30600 LIN transceiver for interfacing the µC with the IBus line.

[ard_fork]: https://github.com/blalor/Arduino
[NSS]: https://github.com/blalor/NewSoftSerial
[ips]: https://github.com/blalor/arduinaap
[ard_build]: http://code.google.com/p/arduino/wiki/BuildingArduino#3._Build_It
[ard_libs]: http://arduino.cc/en/Guide/Environment#libraries
