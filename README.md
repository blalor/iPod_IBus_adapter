iPod ↔ Sirius IBus adapter
==========================

This project is an Arduino sketch that presents an iPod or iPhone as a Sirius satellite radio receiver to the head unit (radio) in some MINI and BMW models.  It supports both simple and advanced iPod protocols.  In advanced mode, the radio shows the current track name as the channel text, and artist and album are accessible via the `INF` button.

I originally started this project because I wanted to put the radio from an '06 MINI into my '91 BMW 318is.  The MINI radio must see a valid IBus message in order to operate, otherwise it displays `-DISABLE-` on the screen and doesn't do anything at all.  Spitting out a valid IBus message every now and then would be simple.  But then I realized that iPod adapters (like the Dension ice>Link:Plus I have in my MINI) aren't cheap and most don't do everything I want, so I decided to keep going.

The end result is pretty much what I was going for, but there are some bugs to be worked out.

For more info, see the [Wiki](https://github.com/blalor/iPod_IBus_adapter/wiki/)
