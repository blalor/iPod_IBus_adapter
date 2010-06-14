#include <avr/pgmspace.h>
#include <NewSoftSerial.h>
#include <string.h>
#include "MyHardwareSerial.h"

#define DEBUG 1

// ==== [macros] ====
#if DEBUG
    // #include "NewSoftSerial.h"
    
    /** Prints a message via Serial. */
    #define DEBUG_PRINT(...) console->print(__VA_ARGS__)
    
    /** Prints a message via Serial, with newline. */
    #define DEBUG_PRINTLN(...) console->println(__VA_ARGS__)

    #define DEBUG_PGM_PRINT(_msg) pgm_print(console, PSTR(_msg))
    #define DEBUG_PGM_PRINTLN(_msg) pgm_println(console, PSTR(_msg))
#else
    // do nothing
    #define DEBUG_PRINT(...)       /**< No-op. */
    #define DEBUG_PRINTLN(...)     /**< No-op. */
    #define DEBUG_PGM_PRINT(...)   /**< No-op. */
    #define DEBUG_PGM_PRINTLN(...) /**< No-op. */
#endif

// pin mappings
#define CONSOLE_RX_PIN 2
#define CONSOLE_TX_PIN 3

// addresses of IBus devices
#define RAD_ADDR  0x68
#define SDRS_ADDR 0x73

// static offsets into the packet
#define PKT_SRC  0
#define PKT_LEN  1
#define PKT_DEST 2
#define PKT_CMD  3

#define TX_BUF_LEN 30
#define RX_BUF_LEN 128

uint8_t tx_buf[TX_BUF_LEN + 1];
uint8_t rx_buf[RX_BUF_LEN + 1];
uint8_t rx_ind;

typedef struct __sat_state {
    uint8_t channel;
    uint8_t band;
    uint8_t preset;
    boolean active; // whether we're playing or not
} SatState;

SatState satelliteState = {1, 1, 1, false};
unsigned long lastPoll;

#if DEBUG
NewSoftSerial nssConsole(CONSOLE_RX_PIN, CONSOLE_TX_PIN);
#endif

// this'll give me flexibility to swap between soft- and hard-ware serial while developing
Print *console = 
    #if DEBUG
        &nssConsole
    #else
        NULL
    #endif
;

void setup() {
    #if DEBUG
        nssConsole.begin(9600);
    #endif
    
    // set up serial for IBus; 9600,8,E,1
    MySerial.begin(9600);
    UCSR0C |= UPM01; // even parity
    
    memset((void *)&rx_buf, '\0', (sizeof(char) * (RX_BUF_LEN + 1)));

    // send SDRS announcement
    DEBUG_PGM_PRINTLN("sending initial announcement");
    send_packet(SDRS_ADDR, 0xFF, "\x02\x01", 2);
}

void loop() {
    /*
    The serial reading is pretty naive. If we start reading in the middle of
    a packet transmission, the checksum validation will fail. All data
    received up to that point will be lost. It's expected that this loop will
    eventually synchronize with the stream during a lull in the conversation,
    where all available and "invalid" data will have been consumed.
    */
    if ((lastPoll + 20000L) < millis()) {
        DEBUG_PGM_PRINTLN("haven't seen a poll in a while; we're dead to the radio");
        while(true);
    }
    
    if (MySerial.available() > 2) {
        memset((void *)&rx_buf, '\0', (sizeof(char) * (RX_BUF_LEN + 1)));
        rx_ind = 0;
        
        rx_buf[rx_ind++] = MySerial.read(); // source
        rx_buf[rx_ind++] = MySerial.read(); // the length
        
        // DEBUG_PGM_PRINT("packet from ");
        // DEBUG_PRINT(rx_buf[PKT_SRC], HEX);
        // DEBUG_PGM_PRINT("; expect length ");
        // DEBUG_PRINTLN(rx_buf[PKT_LEN], HEX);
        
        // read until we've gotten as much data as the packet indicates.
        // ensure we don't overflow the buffer.
        int tmp;
        while ((rx_ind < (rx_buf[PKT_LEN] + 2)) && (rx_ind <= RX_BUF_LEN)) {
            tmp = MySerial.read();
            if (tmp == -1) {
                // no data
                continue;
            }
            
            rx_buf[rx_ind++] = tmp;
        }
        
        // flush any remaining data
        // MySerial.flush();
        
        // verify the checksum
        uint8_t provided_chksum = rx_buf[rx_ind];
        uint8_t calculated_chksum = 0;
        
        for (int i = 0; i < rx_ind; i++) {
            calculated_chksum ^= rx_buf[i];

            DEBUG_PRINT(rx_buf[i], HEX);
            DEBUG_PGM_PRINT(" ");
        }
        
        DEBUG_PGM_PRINTLN(" ");

        if (provided_chksum == calculated_chksum) {
            // found a valid packet
            dispatch_packet(rx_buf);
        } else {
            DEBUG_PGM_PRINT("invalid packet; got checksum ");
            DEBUG_PRINT(provided_chksum, HEX);
            DEBUG_PGM_PRINT(" expected ");
            DEBUG_PRINTLN(calculated_chksum, HEX);
        }
    }
}

void dispatch_packet(const uint8_t *packet) {
    char *data_buf;
    
    // determine if the packet is from the radio and addressed to us, or if there
    // are any other packets we should use as a trigger.
    // DEBUG_PGM_PRINT("got packet from ");
    // DEBUG_PRINTLN(rx_buf[PKT_SRC], HEX);
    
    if ((rx_buf[PKT_SRC] == RAD_ADDR) && (rx_buf[PKT_DEST] == 0xFF)) {
        // broadcast from the radio
        if (rx_buf[PKT_CMD] == 0x02) {
            // device status ready
            
            // use this as a trigger to send our initial announcment.
            // @todo read up on IBus protocol to see when I should really send 
            // my announcements
            
            DEBUG_PGM_PRINTLN("sending SDRS announcement because radio sent device status ready");
            
            // send SDRS announcement
            send_packet(SDRS_ADDR, 0xFF, "\x02\x01", 2);
        }
    }
    else if ((rx_buf[PKT_SRC] == RAD_ADDR) && (rx_buf[PKT_DEST] == SDRS_ADDR)) {
        // check the command byte
        if (rx_buf[PKT_CMD] == 0x01) {
            // handle poll request
            lastPoll = millis();
            
            DEBUG_PGM_PRINTLN("responding to poll request");
            send_packet(SDRS_ADDR, 0xFF, "\x02\x00", 2);
        }
        else if (rx_buf[PKT_CMD] == 0x3D) {
            // command sent that we must reply to
            
            switch(rx_buf[4]) {
                case 0x00: // power
                    DEBUG_PGM_PRINT("got power command, ");
                    DEBUG_PRINTLN(rx_buf[5], HEX);
                    // fall through
                
                case 0x01: // mode
                    DEBUG_PGM_PRINT("got mode command, ");
                    DEBUG_PRINTLN(rx_buf[5], HEX);
                    
                    data_buf = "\x3E\x00\x00..\x04";
                    data_buf[3] = satelliteState.channel;
                    data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                    
                    DEBUG_PGM_PRINTLN("responding to mode command");
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 6);
                    break;
                    
                case 0x03: // channel up
                    DEBUG_PGM_PRINTLN("got channel up");
                
                case 0x04: // channel down
                    DEBUG_PGM_PRINTLN("got channel down");
                
                case 0x05: // channel up and hold
                    DEBUG_PGM_PRINTLN("got channel up and hold");
                
                case 0x06: // channel down and hold
                    DEBUG_PGM_PRINTLN("got channel down and hold");
                
                case 0x08: // preset selected
                    DEBUG_PGM_PRINTLN("got preset");
                
                case 0x09: // preset held
                    DEBUG_PGM_PRINTLN("got preset hold");
                    
                    handle_buttons(rx_buf[4], rx_buf[5]);
                    
                    // a little something for the display
                    data_buf = "\x3E\x01\x00..\x04Hi, there!";
                    data_buf[3] = satelliteState.channel;
                    data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                    
                    DEBUG_PGM_PRINTLN("sending text after channel change");
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 16);
                    
                    // fall through!

                case 0x02: // "now"
                    DEBUG_PGM_PRINTLN("got \"now\"");
                
                case 0x15: // SAT press
                    DEBUG_PGM_PRINTLN("got sat press");

                    data_buf = "\x3E\x02\x00..\x04   !!   ";
                    data_buf[3] = satelliteState.channel;
                    data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                    
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 14);
                    
                    if (rx_buf[4] == 0x02) {
                        // a little something for the display
                        data_buf = "\x3E\x01\x00..\x04Hi, there!";
                        data_buf[3] = satelliteState.channel;
                        data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                        DEBUG_PGM_PRINTLN("sending text for \"now\"");
                        send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 16);
                    }
                    break;
                    
                case 0x0E: // INF press
                    DEBUG_PGM_PRINTLN("got inf press");
                    
                    data_buf = "\x3E\x01\x06..\x01dummy1"; // this text actually shows! (kind of; chopped 1st char, garbled last)
                    data_buf[3] = satelliteState.channel;
                    data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                    
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 12);
                    break;
                
                case 0x0F: // INF press and hold
                    DEBUG_PGM_PRINTLN("got inf press and hold");
                
                    data_buf = "\x3E\x01\x07.\x01\x01dummy2";
                    data_buf[3] = satelliteState.channel;
            
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 12);
                    break;
                
                case 0x0D: // "m"
                    DEBUG_PGM_PRINTLN("[UNHANDLED] got \"m\"");
                
                case 0x14: // SAT press and hold
                    // this actually looks like RAD requesting the ESN
                    DEBUG_PGM_PRINTLN("[UNHANDLED] got sat press and hold");
                
                default:
                    // not handled
                    break;
            }
        }
    }
}

void handle_buttons(uint8_t button_id, uint8_t button_data) {
    switch(button_id) {
        case 0x03: // — channel up
            satelliteState.channel += 1;
            break;
        
        case 0x04: // — channel down
            satelliteState.channel -= 1;
            break;
        
        case 0x08: // — preset button pressed
            // data byte 2 is preset number (0x01, 0x02, … 0x06)
            satelliteState.preset = button_data;
            break;
        
        case 0x05: // — channel up and hold
        case 0x06: // — channel down and hold
        
        case 0x09: // — preset button press and hold
            // data byte 2 is preset number (0x01, 0x02, … 0x06)
        
        default:
            break;
    }
}

// return true if successfully sent and verified packet
boolean send_packet(uint8_t src, uint8_t dest, const char *data, size_t data_len) {
    memset((void *)&tx_buf, '\0', (sizeof(char) * (TX_BUF_LEN + 1)));

    // add space for dest and checksum bytes
    size_t packet_len = data_len + 2;
    uint8_t tx_ind = 0;
    
    // copy all data into the tx buffer
    tx_buf[tx_ind++] = src;
    tx_buf[tx_ind++] = packet_len;
    tx_buf[tx_ind++] = dest;
    
    for (size_t i = 0; i < data_len; i++) {
        tx_buf[tx_ind++] = data[i];
    }
    
    // calculate checksum, which goes into the last byte of the tx buffer
    uint8_t checksum = 0;
    
    for (size_t i = 0; i < tx_ind; i++) {
        checksum ^= tx_buf[i];
    }
    
    tx_buf[tx_ind++] = checksum;
    
    boolean sent_successfully = false;
    uint8_t retry_count = 0;
    while (! sent_successfully && (retry_count++ < 10)) {
        MySerial.write((uint8_t *)&tx_buf, tx_ind);

        // @todo verify that our data appeared in the buffer, indicating that it was
        // sent.  if there was a collision, our data got trampled

        // wait for data to show up
        while (MySerial.available() < tx_ind);

        rx_ind = 0;
        while (rx_ind < tx_ind) {
            rx_buf[rx_ind++] = MySerial.read();
        }

        // return true if the buffers are identical
        sent_successfully = (memcmp((void *)&tx_buf, (void *)&rx_buf, tx_ind) == 0);
        
        if (! sent_successfully) {
            DEBUG_PGM_PRINT("failed to send message; found: ");
            
            for (int i = 0; i < rx_ind; i++) {
                DEBUG_PRINT(rx_buf[i], HEX);
                DEBUG_PGM_PRINT(" ");
            }

            DEBUG_PGM_PRINTLN(" ");
            
        } else {
            DEBUG_PGM_PRINTLN("sent message successfully");
        }
    }
    
    return sent_successfully;
}

// {{{ pgm_print
// http://www.nongnu.org/avr-libc/user-manual/FAQ.html#faq_flashstrings
void pgm_print(Print *dest, PGM_P str) {
    if (dest == NULL) return;
    
    char c;
    
    while ((c = pgm_read_byte(str++))) {
        dest->print(c);
    }
}
// }}}

// {{{ pgm_println
void pgm_println(Print *dest, PGM_P str) {
    if (dest == NULL) return;
    
    pgm_print(dest, str);
    dest->println();
}
// }}}

