#include <NewSoftSerial.h>
#include <string.h>
#include "MyHardwareSerial.h"

#define DEBUG 1
#include "pgm_util.h"

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

// SDRS commands
#define SDRS_CMD_POWER          0x00 // power
#define SDRS_CMD_MODE           0x01 // mode
#define SDRS_CMD_NOW            0x02 // "now"
#define SDRS_CMD_CHAN_UP        0x03 // channel up
#define SDRS_CMD_CHAN_DOWN      0x04 // channel down
#define SDRS_CMD_CHAN_UP_HOLD   0x05 // channel up and hold
#define SDRS_CMD_CHAN_DOWN_HOLD 0x06 // channel down and hold
#define SDRS_CMD_PRESET         0x08 // preset selected
#define SDRS_CMD_PRESET_HOLD    0x09 // preset held
#define SDRS_CMD_M              0x0D // "m"
#define SDRS_CMD_INF            0x0E // INF press
#define SDRS_CMD_INF_HOLD       0x0F // INF press and hold
#define SDRS_CMD_SAT_HOLD       0x14 // SAT press and hold
#define SDRS_CMD_SAT            0x15 // SAT press


// number of times to retry sending messages if verification fails
#define TX_RETRY_COUNT 2

#define TX_BUF_LEN 30

// buffer for building outgoing packets
uint8_t tx_buf[TX_BUF_LEN];
uint8_t tx_ind;

// flag indicating that we're already in the process of sending data; helps to
// queue outgoing messages
boolean tx_active;

// buffer for processing incoming packets; same size as serial buffer
uint8_t rx_buf[RX_BUFFER_SIZE];
uint8_t rx_ind;

typedef struct __sat_state {
    uint8_t channel;
    uint8_t band;
    uint8_t preset;
    boolean active; // whether we're playing or not
} SatState;

SatState satelliteState = {1, 1, 1, false};

// timestamp of last poll from radio
unsigned long lastPoll;

// length of data in IBus packet
uint8_t data_len;

// length of entire packet including source and length
uint8_t pkt_len;

// index of the checksum byte
uint8_t chksum_ind;

int calculated_chksum;

#if DEBUG
NewSoftSerial nssConsole(CONSOLE_RX_PIN, CONSOLE_TX_PIN);
#endif

// this'll give me flexibility to swap between soft- and hard-ware serial 
// while developing
Print *console = 
    #if DEBUG
        &nssConsole
    #else
        NULL
    #endif
;

// {{{ setup
void setup() {
    #if DEBUG
        nssConsole.begin(9600);
    #endif
    
    // set up serial for IBus; 9600,8,E,1
    UCSR0C |= UPM01; // even parity
    MySerial.begin(9600);
    
    // send SDRS announcement
    DEBUG_PGM_PRINTLN("sending initial announcement");
    send_packet(SDRS_ADDR, 0xFF, "\x02\x01", 2);
}
// }}}

// {{{ loop
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
        send_packet(SDRS_ADDR, 0xFF, "\x02\x01", 2);
    }
    
    process_incoming_data();
}
// }}}

// {{{ process_incoming_data
boolean process_incoming_data() {
    boolean found_message = false;
    
    // need at least two bytes to a packet, src and length
    if (MySerial.available() > 2) {
        // length of the data
        data_len = MySerial.peek(1);
        
        if (data_len >= RX_BUFFER_SIZE) {
            DEBUG_PGM_PRINTLN("packet too big for RX buffer");
            MySerial.remove(0);
        }
        else {
            // length of entire packet including source and length
            pkt_len = data_len + 2;

            // index of the checksum byte
            chksum_ind = pkt_len - 1;

            // ensure we've got enough data in the buffer to comprise a complete 
            // packet
            if (MySerial.available() >= pkt_len) {
                // yep, have enough data

                // verify the checksum
                calculated_chksum = 0;
                for (int i = 0; i < chksum_ind; i++) {
                    calculated_chksum ^= MySerial.peek(i);
                }

                if (calculated_chksum == MySerial.peek(chksum_ind)) {
                    // valid checksum

                    // read packet into buffer and dispatch
                    for (int i = 0; i < pkt_len; i++) {
                        rx_buf[i] = MySerial.read();

                        DEBUG_PRINT(rx_buf[i], HEX);
                        DEBUG_PGM_PRINT(" ");
                    }

                    DEBUG_PGM_PRINTLN(" ");

                    // DEBUG_PGM_PRINT("packet from ");
                    // DEBUG_PRINTLN(rx_buf[PKT_SRC], HEX);
                    
                    dispatch_packet(rx_buf);
                }
                else {
                    // invalid checksum; drop first byte in buffer and try again
                    MySerial.remove(0);
                }
            } // if (MySerial.available() …)
        }
    } // if (MySerial.available()  > 2)
    
    return found_message;
}
// }}}

// {{{ dispatch_packet
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
                case SDRS_CMD_POWER:
                    DEBUG_PGM_PRINT("got power command, ");
                    DEBUG_PRINTLN(rx_buf[5], HEX);
                    // fall through
                
                case SDRS_CMD_MODE:
                    DEBUG_PGM_PRINT("got mode command, ");
                    DEBUG_PRINTLN(rx_buf[5], HEX);
                    
                    data_buf = "\x3E\x00\x00..\x04";
                    data_buf[3] = satelliteState.channel;
                    data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                    
                    DEBUG_PGM_PRINTLN("responding to mode command");
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 6);
                    break;
                    
                case SDRS_CMD_CHAN_UP:
                case SDRS_CMD_CHAN_DOWN:
                case SDRS_CMD_CHAN_UP_HOLD:
                case SDRS_CMD_CHAN_DOWN_HOLD:
                case SDRS_CMD_PRESET:
                case SDRS_CMD_PRESET_HOLD:
                    handle_buttons(rx_buf[4], rx_buf[5]);
                    
                    // a little something for the display
                    data_buf = "\x3E\x01\x00..\x04Hi there!";
                    data_buf[3] = satelliteState.channel;
                    data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                    
                    DEBUG_PGM_PRINTLN("sending text after channel change");
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 15);
                    
                    // fall through!

                case SDRS_CMD_NOW:
                    DEBUG_PGM_PRINTLN("got \"now\"");
                
                case SDRS_CMD_SAT:
                    DEBUG_PGM_PRINTLN("got sat press");

                    data_buf = "\x3E\x02\x00..\x04   !!   ";
                    data_buf[3] = satelliteState.channel;
                    data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                    
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 14);
                    
                    if (rx_buf[4] == SDRS_CMD_NOW) {
                        // a little something for the display
                        data_buf = "\x3E\x01\x00..\x04Hi there!";
                        data_buf[3] = satelliteState.channel;
                        data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                        DEBUG_PGM_PRINTLN("sending text for \"now\"");
                        send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 15);
                    }
                    break;
                    
                case SDRS_CMD_INF:
                    DEBUG_PGM_PRINTLN("got inf press");
                    
                    data_buf = "\x3E\x01\x06..\x01dummy1"; // this text actually shows! (kind of; chopped 1st char, garbled last)
                    data_buf[3] = satelliteState.channel;
                    data_buf[4] = (satelliteState.band << 4) | satelliteState.preset;
                    
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 12);
                    break;
                
                case SDRS_CMD_INF_HOLD:
                    DEBUG_PGM_PRINTLN("got inf press and hold");
                
                    data_buf = "\x3E\x01\x07.\x01\x01dummy2";
                    data_buf[3] = satelliteState.channel;
            
                    send_packet(SDRS_ADDR, RAD_ADDR, data_buf, 12);
                    break;
                
                case SDRS_CMD_M:
                    DEBUG_PGM_PRINTLN("[UNHANDLED] got \"m\"");
                
                case SDRS_CMD_SAT_HOLD:
                    // this actually looks like RAD requesting the ESN
                    DEBUG_PGM_PRINTLN("[UNHANDLED] got sat press and hold");
                
                default:
                    // not handled
                    break;
            }
        }
    }
}
// }}}

// {{{ handle_buttons
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
// }}}

// {{{ send_packet
// send and verify packet
// may be recalled recursively:
//      send_packet
//          process_incoming_data
//              send_packet
// Data only gets transmitted by outermost loop
void send_packet(uint8_t src, uint8_t dest, const char *data, size_t data_len) {
    // flag indicating that this invocation should actually transmit the data
    boolean do_tx = false;
    
    // add space for dest and checksum bytes
    size_t packet_len = data_len + 2;

    // ensure sufficient space in tx buffer
    // add two more for src and packet_len bytes
    if ((tx_ind + packet_len + 2) >= TX_BUF_LEN) {
        DEBUG_PGM_PRINTLN("dropping message because TX buffer is full!");
    }
    else {
        if (! tx_active) {
            do_tx = true;
            tx_active = true;
        }
        
        uint8_t tmp_ind = tx_ind;
        
        // copy all data into the tx buffer
        tx_buf[tx_ind++] = src;
        tx_buf[tx_ind++] = packet_len;
        tx_buf[tx_ind++] = dest;

        for (size_t i = 0; i < data_len; i++) {
            tx_buf[tx_ind++] = data[i];
        }

        // calculate checksum, which goes immediately after the last data byte
        tx_buf[tx_ind++] = calc_checksum(&tx_buf[tmp_ind], tx_ind - tmp_ind);

        if (do_tx) {
            boolean sent_successfully = false;
            uint8_t retry_count = 0;
            
            while ((! sent_successfully) && (retry_count++ < TX_RETRY_COUNT)) {
                // force all pending data to be processed. could potentially spin
                // for a while, if there's fewer than 3 bytes in the buffer 
                // because process_incoming_data() won't do anything until then.
                while (MySerial.available()) {
                    process_incoming_data();
                }
                
                MySerial.write(tx_buf, tx_ind);
                
                // wait for data to show up
                while (MySerial.available() < tx_ind);
                
                boolean verification_failed = false;
                for (int i = 0; (i < tx_ind) && (! verification_failed); i++) {
                    if (MySerial.peek(i) != tx_buf[i]) {
                        verification_failed = true;
                        DEBUG_PGM_PRINTLN("verification of sent data failed");
                    }
                }
                
                sent_successfully = (! verification_failed);
            }
            
            tx_ind = 0;
            tx_active = false;
        } // if (do_tx)
    }
}
// }}}

// {{{ calc_checksum
int calc_checksum(uint8_t *buf, uint8_t buf_len) {
    int checksum = 0;
    
    for (size_t i = 0; i < buf_len; i++) {
        checksum ^= buf[i];
    }
    
    return checksum;
}
// }}}
