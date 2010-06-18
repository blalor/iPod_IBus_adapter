#define DEBUG 1
#define DEBUG_PACKET_PARSING 1

#if DEBUG
    #include <NewSoftSerial.h>
#endif

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "HardwareSerial.h"

#include "pgm_util.h"

#define IBUS_DATA_END_MARKER() "\xAA\xBB"
#define ibus_data(_DATA) PSTR((_DATA IBUS_DATA_END_MARKER()))

const char *IBUS_DATA_END_MARKER = IBUS_DATA_END_MARKER();

// pin mappings
#define CONSOLE_RX_PIN  2
#define CONSOLE_TX_PIN  3
#define LED_PIN        13

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
#define SDRS_CMD_INF1           0x0E // INF 1st press
#define SDRS_CMD_INF2           0x0F // INF 2nd press
#define SDRS_CMD_SAT_HOLD       0x14 // SAT press and hold
#define SDRS_CMD_SAT            0x15 // SAT press

// number of times to retry sending messages if verification fails
#define TX_RETRY_COUNT 2

// there may well be a protocol-imposed limit to the max value of a length
// byte in a packet, but it looks like this is the biggest we'll see in
// practice.  Use this as a sort of heuristic to determine if the incoming
// data is valid.
#define MAX_EXPECTED_LEN 10

#define TX_BUF_LEN 128
#define RX_BUF_LEN (MAX_EXPECTED_LEN + 2)
#define TX_DELAY_MARKER -1

// buffer for building outgoing packets
// int because we need a marker in between messages to delay activity on the
// bus briefly
int tx_buf[TX_BUF_LEN];
uint8_t tx_ind;

// flag indicating that we're already in the process of sending data; helps to
// queue outgoing messages
boolean tx_active;

// buffer for processing incoming packets; same size as serial buffer
uint8_t rx_buf[RX_BUF_LEN];
uint8_t rx_ind;

typedef struct __sat_state {
    uint8_t channel;
    uint8_t band;
    uint8_t preset;
    boolean active; // whether we're playing or not
} SatState;

SatState satelliteState = {1, 1, 0, false};

// timestamp of last poll from radio
unsigned long lastPoll;

// trigger time to turn off LED
unsigned long ledOffTime;

// timeout duration before giving up on a read
unsigned long readTimeout;

#if DEBUG
    NewSoftSerial nssConsole(CONSOLE_RX_PIN, CONSOLE_TX_PIN);
#endif

char global_text_data[10];

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
        nssConsole.begin(115200);
    #endif
    
    // set up serial for IBus; 9600,8,E,1
    Serial.begin(9600);
    UCSR0C |= _BV(UPM01); // even parity
    
    pinMode(LED_PIN, OUTPUT);
    
    // send SDRS announcement
    DEBUG_PGM_PRINTLN("sending initial announcement");
    send_packet(SDRS_ADDR, 0xFF, ibus_data("\x02\x01"), NULL, false);
    
    for (int i = 0; i < 3; i++) {
        digitalWrite(LED_PIN, HIGH);
        delay(250);
        digitalWrite(LED_PIN, LOW);
        delay(250);
    }
}
// }}}

// {{{ loop
void loop() {
    if (millis() > ledOffTime) {
        digitalWrite(LED_PIN, LOW);
    }
    
    /*
    The serial reading is pretty naive. If we start reading in the middle of
    a packet transmission, the checksum validation will fail. All data
    received up to that point will be lost. It's expected that this loop will
    eventually synchronize with the stream during a lull in the conversation,
    where all available and "invalid" data will have been consumed.
    */
    if ((lastPoll + 20000L) < millis()) {
        DEBUG_PGM_PRINTLN("haven't seen a poll in a while; we're dead to the radio");
        send_packet(SDRS_ADDR, 0xFF, ibus_data("\x02\x01"), NULL, false);
        lastPoll = millis();
    }
    
    process_incoming_data();
}
// }}}

// {{{ process_incoming_data
boolean process_incoming_data() {
    boolean found_message = false;
    
    uint8_t bytes_availble = Serial.available();
    
    #if DEBUG && DEBUG_PACKET_PARSING
        if (bytes_availble) {
            DEBUG_PGM_PRINT("[pkt] buf contents: ");
            for (int i = 0; i < bytes_availble; i++) {
                DEBUG_PRINT(Serial.peek(i), HEX);
                DEBUG_PGM_PRINT(" ");
            }
            DEBUG_PGM_PRINTLN(" ");
        }
    #endif
    
    // need at least two bytes to a packet, src and length
   if (bytes_availble > 2) {
        // length of the data
        uint8_t data_len = Serial.peek(PKT_LEN);

        #if DEBUG && DEBUG_PACKET_PARSING
            DEBUG_PGM_PRINT("[pkt] have ");
            DEBUG_PRINT(bytes_availble, DEC);
            DEBUG_PGM_PRINTLN(" bytes available");
        
            DEBUG_PGM_PRINT("[pkt] packet length is ");
            DEBUG_PRINTLN(data_len, DEC);
        #endif
        
        if (
            (data_len == 0)                || // length cannot be zero
            (data_len >= MAX_EXPECTED_LEN) || // we don't handle messages larger than this
            (data_len >= RX_BUFFER_SIZE)      // hard limit to how much data we can buffer
        ) {
            DEBUG_PGM_PRINTLN("invalid packet length");
            
            #if DEBUG && DEBUG_PACKET_PARSING
                     if (data_len == 0) DEBUG_PGM_PRINTLN("length cannot be zero");
                else if (data_len >= MAX_EXPECTED_LEN) DEBUG_PGM_PRINTLN("we don't handle messages larger than this");
                else if (data_len >= RX_BUFFER_SIZE) DEBUG_PGM_PRINTLN("hard limit to how much data we can buffer");
            #endif
            Serial.remove(1);
        }
        else {
            // length of entire packet including source and length
            uint8_t pkt_len = data_len + 2;

            // index of the checksum byte
            uint8_t chksum_ind = pkt_len - 1;
            
            #if DEBUG && DEBUG_PACKET_PARSING
                DEBUG_PGM_PRINT("[pkt] checksum at index ");
                DEBUG_PRINT(chksum_ind, DEC);
                DEBUG_PGM_PRINT(": ");
                DEBUG_PRINTLN(Serial.peek(chksum_ind), HEX);

                DEBUG_PGM_PRINT("[pkt] need at least ");
                DEBUG_PRINT(pkt_len, DEC);
                DEBUG_PGM_PRINTLN(" bytes for complete packet");
            #endif

            // ensure we've got enough data in the buffer to comprise a
            // complete packet
            if (bytes_availble >= pkt_len) {
                // yep, have enough data
                readTimeout = 0;

                // verify the checksum
                int calculated_chksum = 0;
                for (int i = 0; i < chksum_ind; i++) {
                    calculated_chksum ^= Serial.peek(i);
                }

                if (calculated_chksum == Serial.peek(chksum_ind)) {
                    found_message = true;
                    
                    // valid checksum

                    #if DEBUG && DEBUG_PACKET_PARSING
                        DEBUG_PGM_PRINT("[pkt] received ");
                    #endif

                    // read packet into buffer and dispatch
                    for (int i = 0; i < pkt_len; i++) {
                        rx_buf[i] = Serial.read();

                        #if DEBUG && DEBUG_PACKET_PARSING
                            DEBUG_PRINT(rx_buf[i], HEX);
                            DEBUG_PGM_PRINT(" ");
                        #endif
                    }

                    #if DEBUG && DEBUG_PACKET_PARSING
                        DEBUG_PGM_PRINTLN(" ");
                    #endif

                    // DEBUG_PGM_PRINT("packet from ");
                    // DEBUG_PRINTLN(rx_buf[PKT_SRC], HEX);
                    
                    dispatch_packet(rx_buf);
                }
                else {
                    // invalid checksum; drop first byte in buffer and try
                    // again
                    DEBUG_PGM_PRINTLN("invalid checksum");
                    Serial.remove(1);
                }
            } // if (bytes_availble …)
            else {
                // provide a timeout mechanism; expire if needed bytes 
                // haven't shown up in the expected time.
                
                if (readTimeout == 0) {
                    // 0.83ms/byte
                    readTimeout = ((83 * (pkt_len - bytes_availble)) / 100);
                    DEBUG_PGM_PRINT("read timeout: ");
                    DEBUG_PRINTLN(readTimeout, DEC);
                    readTimeout += millis();
                } else if (millis() > readTimeout) {
                    DEBUG_PGM_PRINTLN("dropping packet due to read timeout");
                    readTimeout = 0;
                    Serial.remove(1);
                }
            }
        }
    } // if (bytes_availble  >= 2)
    
    return found_message;
}
// }}}

// {{{ dispatch_packet
void dispatch_packet(const uint8_t *packet) {
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
            send_packet(SDRS_ADDR, 0xFF, ibus_data("\x02\x01"), NULL, false);
        }
    }
    else if ((rx_buf[PKT_SRC] == RAD_ADDR) && (rx_buf[PKT_DEST] == SDRS_ADDR)) {
        // check the command byte
        if (rx_buf[PKT_CMD] == 0x01) {
            // handle poll request
            lastPoll = millis();
            
            DEBUG_PGM_PRINTLN("responding to poll request");
            send_packet(SDRS_ADDR, 0xFF, ibus_data("\x02\x00"), NULL, false);
        }
        else if (rx_buf[PKT_CMD] == 0x3D) {
            // command sent that we must reply to
            
            switch(rx_buf[4]) {
                case SDRS_CMD_POWER:
                    // this is sometimes sent by the radio immediately after
                    // our initial announcemnt if the ignition is off (ACC
                    // isn't hot). Perhaps only after the IBus is first
                    // initialized.  Either way, it seems to indicate that the
                    // radio's off and we shouldn't be doing anything.
                    DEBUG_PGM_PRINT("got power command, ");
                    DEBUG_PRINTLN(rx_buf[5], HEX);
                    // fall through
                
                case SDRS_CMD_MODE:
                    // sent when the mode on the radio is changed away from
                    // SIRIUS, and when the radio is turned off while SIRIUS
                    // is active.
                    DEBUG_PGM_PRINT("got mode command, ");
                    DEBUG_PRINTLN(rx_buf[5], HEX);
                    
                    DEBUG_PGM_PRINTLN("responding to mode command");
                    send_packet(SDRS_ADDR, RAD_ADDR,
                                ibus_data("\x3E\x00\x00..\x04"),
                                NULL, true);

                    satelliteState.active = false;
                    break;
                    
                case SDRS_CMD_CHAN_UP:
                case SDRS_CMD_CHAN_DOWN:
                case SDRS_CMD_CHAN_UP_HOLD:
                case SDRS_CMD_CHAN_DOWN_HOLD:
                case SDRS_CMD_PRESET:
                case SDRS_CMD_PRESET_HOLD:
                    handle_buttons(rx_buf[4], rx_buf[5]);
                    
                    // a little something for the display
                    DEBUG_PGM_PRINTLN("sending text after channel change");
                    send_packet(SDRS_ADDR, RAD_ADDR,
                                ibus_data("\x3E\x01\x00..\x04"),
                                "Yo.", true);
                    
                    // fall through!

                case SDRS_CMD_NOW:
                    // this is the command received when the mode is changed
                    // on the radio to select SIRIUS. It is also sent
                    // periodically if we don't respond quickly enough with an
                    // updated display command (3D 01 00 …)
                    DEBUG_PGM_PRINTLN("got \"now\"");
                    satelliteState.active = true;
                
                case SDRS_CMD_SAT:
                    DEBUG_PGM_PRINTLN("got sat press");
                    send_packet(SDRS_ADDR, RAD_ADDR,
                                ibus_data("\x3E\x02\x00..\x04   !!   "),
                                NULL, true);
                    
                    if (rx_buf[4] == SDRS_CMD_NOW) {
                        delay(10);
                        // a little something for the display
                        DEBUG_PGM_PRINTLN("sending text for \"now\"");
                        snprintf_P(global_text_data, 10, PSTR("chan %3d!"), satelliteState.channel);
                        send_packet(SDRS_ADDR, RAD_ADDR,
                                    ibus_data("\x3E\x01\x00..\x04"),
                                    // "........",
                                    global_text_data,
                                    true);
                    }
                    break;
                    
                case SDRS_CMD_INF1:
                    DEBUG_PGM_PRINTLN("got first inf press");
                    
                    // this text actually shows! (kind of; chopped 1st char,
                    // garbled last));
                     send_packet(SDRS_ADDR, RAD_ADDR,
                                ibus_data("\x3E\x01\x06..\x01dummy1"),
                                NULL, true);
                    break;
                
                case SDRS_CMD_INF2:
                    DEBUG_PGM_PRINTLN("got second inf press");
                
                    // @todo reconcile this with dbroome's code
                    send_packet(SDRS_ADDR, RAD_ADDR,
                                ibus_data("\x3E\x01\x07..\x01dummy2"),
                                NULL, true);
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

/*
    pgm_data is the static part of the message being sent, ie. without any
    text that may be dynamically generated. It's just a byte (char) array, but
    terminated with the "special" sequence \xAA\xBB, so that I don't need to
    manually keep track of the length. This means that none of these PROGMEM
    strings can have that sequence embedded in them!
*/
void send_packet(uint8_t src,
                 uint8_t dest,
                 // const prog_int16_t *pgm_data,
                 PGM_P pgm_data,
                 const char *text,
                 boolean send_channel_preset_and_band)
    {
    // flag indicating that this invocation should actually transmit the data
    boolean do_tx; /* = false */
    
    // length of pgm_data
    size_t pgm_data_len = 0;
    
    // add length of text data (the display only shows 8 chars…)
    size_t text_len = 0;

    // length of text and pgm data
    size_t data_len; /* = 0 */
    
    // determine length of pgm_data
    while (
        ! (
            (pgm_read_byte(&pgm_data[pgm_data_len])     == ((uint8_t) IBUS_DATA_END_MARKER[0])) &&
            (pgm_read_byte(&pgm_data[pgm_data_len + 1]) == ((uint8_t) IBUS_DATA_END_MARKER[1]))
        )
    ) {
        pgm_data_len += 1;
    }
    
    DEBUG_PGM_PRINT("pgm_data_len: ");
    DEBUG_PRINTLN(pgm_data_len, DEC);

    if (text != NULL) {
        text_len = strlen(text);
        DEBUG_PRINT(text);
        DEBUG_PGM_PRINT(" has length ");
        DEBUG_PRINTLN(text_len, DEC);
    } else {
        DEBUG_PGM_PRINTLN("no text");
    }
    
    data_len = pgm_data_len + text_len;
    DEBUG_PGM_PRINT("data_len: ");
    DEBUG_PRINTLN(data_len, DEC);
    
    uint8_t *data = (uint8_t *) malloc((size_t) data_len);
    if (data == NULL) {
        DEBUG_PGM_PRINT("[ERROR] Unable to malloc data of length ");
        DEBUG_PRINTLN(data_len, DEC);
        return;
    } else {
        DEBUG_PGM_PRINTLN("malloc()'d data successfully");
    }
    
    DEBUG_PGM_PRINT("pgm_data: ");
    for (uint8_t i = 0; i < pgm_data_len; i++) {
        data[i] = pgm_read_byte(&pgm_data[i]);
        DEBUG_PRINT(data[i], HEX);
        DEBUG_PGM_PRINT(" ");
    }
    DEBUG_PGM_PRINTLN(" ");
        
    // fill in the blanks for the channel, band, and preset
    if (send_channel_preset_and_band) {
        data[3] = satelliteState.channel;
        data[4] = ((satelliteState.band << 4) | satelliteState.preset);
    }
    
    // append text
    if (text != NULL) {
        DEBUG_PGM_PRINT("text: ");
        for (uint8_t i = 0; i < text_len; i++) {
            data[pgm_data_len + i] = text[i];
            DEBUG_PRINT(data[pgm_data_len + i], HEX);
            DEBUG_PGM_PRINT(" ");
        }
        DEBUG_PGM_PRINTLN(" ");
        // memcpy((void *)&data[pgm_data_len], (void *)&text, text_len);
    }
    
    // add space for dest and checksum bytes
    size_t packet_len = data_len + 2;
    DEBUG_PGM_PRINT("packet_len: ");
    DEBUG_PRINTLN(packet_len, DEC);

    // ensure sufficient space in tx buffer
    // add two more for src and packet_len bytes
    if ((tx_ind + packet_len + 2) >= TX_BUF_LEN) {
        DEBUG_PGM_PRINTLN("dropping message because TX buffer is full!");
        #if DEBUG
            DEBUG_PGM_PRINT("src: ");
            DEBUG_PRINT(src, HEX);
            DEBUG_PGM_PRINT(", dest: ");
            DEBUG_PRINT(dest, HEX);
            DEBUG_PGM_PRINT(", data: ");
            for (int i = 0; i < data_len; i++) {
                DEBUG_PRINT((uint8_t) data[i], HEX);
                DEBUG_PGM_PRINT(" ");
            }
            DEBUG_PGM_PRINTLN("");
        #endif
    }
    else {
        if (! tx_active) {
            do_tx = true;
            tx_active = true;
        }
        
        if (! do_tx) {
            DEBUG_PGM_PRINTLN("re-entered send_packet()");
            // insert delay marker between outgoing messages
            tx_buf[tx_ind++] = TX_DELAY_MARKER;
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
                unsigned long expire = millis() + 10L;
                while (Serial.available() && (millis() < expire)) {
                    DEBUG_PGM_PRINTLN("forcing process_incoming_data() while sending");
                    if (process_incoming_data()) {
                        expire = millis() + 10L;
                    }
                }
                Serial.flush(); // @todo warning!
                
                digitalWrite(LED_PIN, HIGH);
                ledOffTime = millis() + 500L;
                
                uint8_t sent_count = 0;
                for (int i = 0; i < tx_ind; i++) {
                    if (tx_buf[i] == TX_DELAY_MARKER) {
                        DEBUG_PGM_PRINTLN(" pause marker found");
                        delay(1); // delay 1ms
                    }
                    else {
                        #if DEBUG && DEBUG_PACKET_PARSING
                            DEBUG_PRINT((uint8_t) tx_buf[i], HEX);
                            DEBUG_PGM_PRINT(" ");
                        #endif
                        
                        Serial.write((uint8_t) tx_buf[i]);
                        sent_count++;
                    }
                }
                
                #if DEBUG && DEBUG_PACKET_PARSING
                    DEBUG_PGM_PRINTLN("done sending");
                #endif
                
                // wait for data to show up
                while (Serial.available() < sent_count);
                
                boolean verification_failed = false;
                uint8_t rx_data_ind = 0;
                for (int i = 0; (i < tx_ind) && (! verification_failed); i++) {
                    if (tx_buf[i] == TX_DELAY_MARKER) {
                        // delay marker
                        continue;
                    }
                    
                    if (Serial.peek(rx_data_ind++) != tx_buf[i]) {
                        verification_failed = true;
                    }
                }
                
                sent_successfully = (! verification_failed);
                
                if (! verification_failed) {
                    Serial.remove(sent_count);
                    DEBUG_PGM_PRINTLN("verification of sent data succeeded");
                }
                else {
                    DEBUG_PGM_PRINTLN("verification of sent data failed");
                }
            }
            
            tx_ind = 0;
            tx_active = false;
        } // if (do_tx)
    }
    
    free(data);
}
// }}}

// {{{ calc_checksum
int calc_checksum(int *buf, uint8_t buf_len) {
    int checksum = 0;
    
    for (size_t i = 0; i < buf_len; i++) {
        checksum ^= buf[i];
    }
    
    return checksum;
}
// }}}
