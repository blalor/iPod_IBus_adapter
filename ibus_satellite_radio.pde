#define DEBUG 1
#define DEBUG_PACKET_PARSING 0
#define WICKED_VERBOSE 0

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include "HardwareSerial.h"

#include <SimpleRemote.h>
#include <NewSoftSerial.h>

#include "pgm_util.h"

// @todo look into whether the preprocessor will magically convert 
//   strlen("foo") -> 3
// https://lists.linux-foundation.org/pipermail/openais/2010-March/014011.html
#define IBUS_DATA_END_MARKER() "\xAA\xBB"
#define ibus_data(_DATA) PSTR((_DATA IBUS_DATA_END_MARKER()))

const char *IBUS_DATA_END_MARKER = IBUS_DATA_END_MARKER();

// pin mappings
#define INH_PIN         2

#define CONSOLE_RX_PIN  3
#define CONSOLE_TX_PIN  4

#define IPOD_RX_PIN    19 // 28 on chip
#define IPOD_TX_PIN    18 // 27 on chip

#define LED_GRN 8
#define LED_YEL 7
#define LED_RED 6

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
#define SDRS_CMD_INF1           0x0E // INF 1st press; display artist
#define SDRS_CMD_INF2           0x0F // INF 2nd press; display song
#define SDRS_CMD_SAT_HOLD       0x14 // SAT press and hold
#define SDRS_CMD_SAT            0x15 // SAT press

// number of times to retry sending messages if verification fails
#define TX_RETRY_COUNT 2

// there may well be a protocol-imposed limit to the max value of a length
// byte in a packet, but it looks like this is the biggest we'll see in
// practice.  Use this as a sort of heuristic to determine if the incoming
// data is valid.
#define MAX_EXPECTED_LEN 64

#define TX_BUF_LEN 128
#define RX_BUF_LEN (MAX_EXPECTED_LEN + 2)

/*
prescale    target timer count  rounded timer count       (D)    (E)          % diff
       1             11110.111                11110     1440    1440.0144    -0.0010
       8              1387.888                 1388     1440    1439.8848     0.0079
      32               346.222                  346     1440    1440.9221    -0.0640
      64               172.611                  173     1440    1436.7816     0.2234
     128                85.805                   86     1440    1436.7816     0.2234
     256                42.402                   42     1440    1453.4883    -0.9366
    1024                 9.850                   10     1440    1420.4545     1.3573
    
target timer count=((16000000/A2)/(960*1.5))-1
rounded timer count=ROUND(target timer count '1', 0)
(D)=(16000000/A2)/(target timer count '1'+1)
(E)=(16000000/A2)/(rounded timer count '1'+1)
% diff=100-(E2*100)/D2
*/
#define CONTENTION_TIMEOUT 173        

// buffer for building outgoing packets
// int because we need a marker in between messages to delay activity on the
// bus briefly
int tx_buf[TX_BUF_LEN];
uint8_t tx_ind;

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

unsigned long nextTestText;

// trigger time to turn off LED
unsigned long ledOffTime;

// timeout duration before giving up on a read
unsigned long readTimeout;

// NSS instance for the iPod
NewSoftSerial nssIPod(IPOD_RX_PIN, IPOD_TX_PIN);

// iPod simple remote instance
SimpleRemote simpleRemote;

#if DEBUG
    NewSoftSerial nssConsole(CONSOLE_RX_PIN, CONSOLE_TX_PIN);
#endif

char global_text_data[10];
volatile boolean bus_inhibited;
boolean announcement_sent;

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
        
        if (MCUSR & _BV(PORF))  DEBUG_PGM_PRINTLN("power-on reset");
        if (MCUSR & _BV(EXTRF)) DEBUG_PGM_PRINTLN("external reset");
        if (MCUSR & _BV(BORF))  DEBUG_PGM_PRINTLN("brown-out reset");
        if (MCUSR & _BV(WDRF))  DEBUG_PGM_PRINTLN("watchdog reset");
    #endif
    
    MCUSR = 0;

    pinMode(LED_GRN, OUTPUT);
    pinMode(LED_YEL, OUTPUT);
    pinMode(LED_RED, OUTPUT);
    
    pinMode(INH_PIN, INPUT);
    
    // indicate setup is underway
    digitalWrite(LED_YEL, HIGH);
    
    // Set up timer2 at Fcpu/1 (no prescaler) for contention detection. Must
    // be done before any serial activity!
    //     CS22:1, CS21:0, CS20:0
    TCCR2B |= _BV(CS22);
    TCCR2B &= ~(_BV(CS21) | _BV(CS20));
    
    simpleRemote.setSerial(nssIPod);
    simpleRemote.setup();
     
    announcement_sent = false;
    nextTestText = millis() + 5000L;
    
    // set up serial for IBus; 9600,8,E,1
    Serial.begin(9600);
    UCSR0C |= _BV(UPM01); // even parity
    
    // test to make sure the bus is alive; if it isn't, shut down (but do not
    // reconfigure) the USART
    
    // can't do anything while the bus is asleep.
    // bus_inhibited = true;
    // while(bus_inhibited) {
    //     configureForBusInhibition();
    // }
    // 
    // // enable INT0
    // // @todo use this interrupt to wake the µC from sleep
    // attachInterrupt(0, configureForBusInhibition, CHANGE);    
    
    // send SDRS announcement
    DEBUG_PGM_PRINTLN("sending initial announcement");
    send_packet(SDRS_ADDR, 0xFF, ibus_data("\x02\x01"), NULL, false);
    
    digitalWrite(LED_GRN, LOW);
    digitalWrite(LED_YEL, LOW);
    digitalWrite(LED_RED, LOW);

    for (int i = 0; i < 3; i++) {
        digitalWrite(LED_GRN, HIGH);
        digitalWrite(LED_YEL, HIGH);
        digitalWrite(LED_RED, HIGH);
        delay(250);
        digitalWrite(LED_GRN, LOW);
        digitalWrite(LED_YEL, LOW);
        digitalWrite(LED_RED, LOW);
        delay(250);
    }
}
// }}}

// {{{ loop
void loop() {
    if (millis() > ledOffTime) {
        digitalWrite(LED_GRN, LOW);
    }
    
    // can't do anything while the bus is asleep.
    if (bus_inhibited) {
        // @todo flash leds?
    } else {
        /*
        The serial reading is pretty naive. If we start reading in the middle of
        a packet transmission, the checksum validation will fail. All data
        received up to that point will be lost. It's expected that this loop will
        eventually synchronize with the stream during a lull in the conversation,
        where all available and "invalid" data will have been consumed.
        */
        if ((lastPoll + 20000L) < millis()) {
            DEBUG_PGM_PRINTLN("haven't seen a poll in a while; we're dead to the radio");
            digitalWrite(LED_RED, HIGH);
            send_packet(SDRS_ADDR, 0xFF, ibus_data("\x02\x01"), NULL, false);
            lastPoll = millis();
        }
        
        if (millis() >= nextTestText) {
            unsigned long now = millis();
            unsigned long seconds = now / 1000L;
            unsigned long minutes = seconds / 60L;
            
            snprintf_P(global_text_data, 10, PSTR("%lu:%02lu.%03lu"), minutes, seconds % 60L, now % 1000L);
            
            if (satelliteState.active) {
                send_packet(SDRS_ADDR, RAD_ADDR,
                            ibus_data("\x3E\x01\x00..\x04"),
                            // "........",
                            global_text_data,
                            true);
            }
            
            nextTestText = millis() + 5000L;
        }
        
        process_incoming_data();
    }
}
// }}}

// {{{ disableSerialReceive
inline void disableSerialReceive() {
    UCSR0B &= ~(_BV(RXEN0) | _BV(RXCIE0));
}
// }}}

// {{{ enableSerialReceive
inline void enableSerialReceive() {
    // @todo still (usually?) getting 2 bytes in the RX buffer after 
    //       transmitting, even with RX turned off
    
    // wait for TX buffer to flush (while TX is not complete)
    while (! (UCSR0A & _BV(TXC0)));
            
    UCSR0B |= _BV(RXEN0) | _BV(RXCIE0);
}
// }}}

// {{{ configureForBusInhibition
/**
 * If the I-Bus is alive, enable the RX hardware.  If it's not, shut down
 * the RX hardware and flush the buffer.
 */
void configureForBusInhibition() {
    // bus is uninhibited (alive) when PORTD2 is high
    bus_inhibited = (digitalRead(INH_PIN) == LOW);
    
    if (bus_inhibited) {
        // shutdown the receive circuitry, flush any remaining data
        disableSerialReceive();
        Serial.flush();
    } else {
        // bus is now enabled; restart USART
        enableSerialReceive();
    }
}
// }}}

// {{{ process_incoming_data
boolean process_incoming_data() {
    boolean found_message = false;
    
    uint8_t bytes_availble = Serial.available();
    
    if (bytes_availble) {
        digitalWrite(LED_YEL, HIGH);

        #if DEBUG && DEBUG_PACKET_PARSING
            DEBUG_PGM_PRINT("[pkt] buf contents: ");
            for (int i = 0; i < bytes_availble; i++) {
                DEBUG_PRINT(Serial.peek(i), HEX);
                DEBUG_PGM_PRINT(" ");
            }
            DEBUG_PRINTLN();
        #endif
    }
    
    // filter out packets from sources we don't care about
    // I don't like this solution at all, but until I can implement a timer to 
    // reset in the RX interrupt I think this will at least avoid getting 
    // stuck waiting for enough data to arrive
    if (bytes_availble && (Serial.peek(PKT_SRC) != RAD_ADDR) && (Serial.peek(PKT_SRC) != SDRS_ADDR)) {
        DEBUG_PGM_PRINTLN("dropping byte from unknown source");
        Serial.remove(1);
    }
    // need at least two bytes to a packet, src and length
    else if (bytes_availble > 2) {
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

                    #if DEBUG
                        DEBUG_PGM_PRINT("received pkt ");
                    #endif

                    // read packet into buffer and dispatch
                    for (int i = 0; i < pkt_len; i++) {
                        rx_buf[i] = Serial.read();

                        #if DEBUG
                            DEBUG_PRINT(rx_buf[i], HEX);
                            DEBUG_PGM_PRINT(" ");
                        #endif
                    }

                    #if DEBUG
                        DEBUG_PRINTLN();
                    #endif
                    
                    #if WICKED_VERBOSE
                        DEBUG_PGM_PRINT("packet from ");
                        DEBUG_PRINTLN(rx_buf[PKT_SRC], HEX);
                    #endif
                    
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
                    // (10 bits/byte) => 1.042ms/byte; add a 20% fudge factor
                    readTimeout = ((125 * ((pkt_len - bytes_availble) + 1)) / 100);
                    
                    #if DEBUG && DEBUG_PACKET_PARSING
                        DEBUG_PGM_PRINT("read timeout: ");
                        DEBUG_PRINTLN(readTimeout, DEC);
                    #endif
                    
                    readTimeout += millis();
                }
                else if (millis() > readTimeout) {
                    DEBUG_PGM_PRINTLN("dropping packet due to read timeout");
                    readTimeout = 0;
                    Serial.remove(1);
                }
            }
        }
    } // if (bytes_availble  >= 2)
    
    digitalWrite(LED_YEL, LOW);

    return found_message;
}
// }}}

// {{{ dispatch_packet
void dispatch_packet(const uint8_t *packet) {
    // determine if the packet is from the radio and addressed to us, or if there
    // are any other packets we should use as a trigger.
    #if WICKED_VERBOSE
        DEBUG_PGM_PRINT("got packet from ");
        DEBUG_PRINTLN(rx_buf[PKT_SRC], HEX);
    #endif
    
    if ((packet[PKT_SRC] == RAD_ADDR) && (packet[PKT_DEST] == 0xFF)) {
        // broadcast from the radio
        
        if (packet[PKT_CMD] == 0x02) {
            // device status ready
            
            // use this as a trigger to send our initial announcment.
            // @todo read up on IBus protocol to see when I should really send 
            // my announcements
            
            DEBUG_PGM_PRINTLN("sending SDRS announcement because radio sent device status ready");
            
            // send SDRS announcement
            send_packet(SDRS_ADDR, 0xFF, ibus_data("\x02\x01"), NULL, false);
        }
    }
    else if ((packet[PKT_SRC] == RAD_ADDR) && (packet[PKT_DEST] == SDRS_ADDR)) {
        // check the command byte
        if (packet[PKT_CMD] == 0x01) {
            // handle poll request
            lastPoll = millis();
            
            DEBUG_PGM_PRINTLN("responding to poll request");
            send_packet(SDRS_ADDR, 0xFF, ibus_data("\x02\x00"), NULL, false);
        }
        else if (packet[PKT_CMD] == 0x3D) {
            // command sent that we must reply to
            
            switch(packet[4]) {
                case SDRS_CMD_POWER:
                    // this is sometimes sent by the radio immediately after
                    // our initial announcemnt if the ignition is off (ACC
                    // isn't hot). Perhaps only after the IBus is first
                    // initialized.  Either way, it seems to indicate that the
                    // radio's off and we shouldn't be doing anything.
                    DEBUG_PGM_PRINT("got power command, ");
                    DEBUG_PRINTLN(packet[5], HEX);
                    
                    // fall through
                
                case SDRS_CMD_MODE:
                    // sent when the mode on the radio is changed away from
                    // SIRIUS, and when the radio is turned off while SIRIUS
                    // is active.
                    DEBUG_PGM_PRINT("[cmd] got mode command, ");
                    DEBUG_PRINTLN(packet[5], HEX);
                
                    set_state_inactive();
                    
                    DEBUG_PGM_PRINTLN("responding to mode command");
                    send_packet(SDRS_ADDR, RAD_ADDR,
                                ibus_data("\x3E\x00\x00..\x04"),
                                NULL, true);
                    
                    break;
            
                case SDRS_CMD_CHAN_UP:
                case SDRS_CMD_CHAN_DOWN:
                case SDRS_CMD_CHAN_UP_HOLD:
                case SDRS_CMD_CHAN_DOWN_HOLD:
                case SDRS_CMD_PRESET:
                case SDRS_CMD_PRESET_HOLD:
                    DEBUG_PGM_PRINT("[cmd] got nav command, ");
                    DEBUG_PRINT(packet[4], HEX);
                    DEBUG_PGM_PRINT(" ");
                    DEBUG_PRINTLN(packet[5], HEX);
                    
                    handle_buttons(packet[4], packet[5]);
                    
                    // a little something for the display
                    DEBUG_PGM_PRINTLN("sending text after channel change");
                    send_packet(SDRS_ADDR, RAD_ADDR,
                                ibus_data("\x3E\x01\x00..\x04"),
                                "Yo.", true);
                    delay(50);
                    // fall through!

                case SDRS_CMD_NOW:
                    // this is the command received when the mode is changed
                    // on the radio to select SIRIUS. It is also sent
                    // periodically if we don't respond quickly enough with an
                    // updated display command (3D 01 00 …)
                    DEBUG_PGM_PRINTLN("got \"now\"");
                
                    set_state_active();
                    // fall through!
                
                case SDRS_CMD_SAT:
                    DEBUG_PGM_PRINTLN("got sat press");
                    send_packet(SDRS_ADDR, RAD_ADDR,
                                ibus_data("\x3E\x02\x00..\x04   !!   "),
                                NULL, true);
                    
                    if (packet[4] == SDRS_CMD_NOW) {
                        delay(50);
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
                                ibus_data("\x3E\x01\x06..\x01dummy1.0 dummy1.1 dummy1.2"),
                                NULL, true);
                    break;
                
                case SDRS_CMD_INF2:
                    DEBUG_PGM_PRINTLN("got second inf press");
                
                    // @todo reconcile this with dbroome's code
                    send_packet(SDRS_ADDR, RAD_ADDR,
                                ibus_data("\x3E\x01\x07..\x01dummy2.0 dummy2.1 dummy2.2"),
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
    #if DEBUG && DEBUG_PACKET_PARSING
        else if (packet[PKT_SRC] == SDRS_ADDR) {
            DEBUG_PGM_PRINTLN("ignoring packet from myself");
        }
    #endif
}
// }}}

// {{{ handle_buttons
void handle_buttons(uint8_t button_id, uint8_t button_data) {
    switch(button_id) {
        case 0x03: // — channel up
            satelliteState.channel += 1;
            simpleRemote.sendSkipForward();
            simpleRemote.sendButtonReleased();
            break;
        
        case 0x04: // — channel down
            satelliteState.channel -= 1;
            simpleRemote.sendSkipBackward();
            simpleRemote.sendButtonReleased();
            break;
        
        case 0x08: // — preset button pressed
            // data byte 2 is preset number (0x01, 0x02, … 0x06)
            satelliteState.preset = button_data;
            break;
        
        case 0x05: // — channel up and hold
            simpleRemote.sendNextAlbum();
            simpleRemote.sendButtonReleased();
            break;
            
        case 0x06: // — channel down and hold
            simpleRemote.sendPreviousAlbum();
            simpleRemote.sendButtonReleased();
            break;
        
        case 0x09: // — preset button press and hold
            // data byte 2 is preset number (0x01, 0x02, … 0x06)
            break;
        
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
    boolean sent_successfully = false;
    
    // length of pgm_data
    size_t pgm_data_len = 0;
    
    // add length of text data (the display only shows 8 chars [sometimes]…)
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
    
    #if WICKED_VERBOSE
        DEBUG_PGM_PRINT("pgm_data_len: ");
        DEBUG_PRINTLN(pgm_data_len, DEC);
    #endif
    
    if (pgm_data_len > TX_BUF_LEN) {
        DEBUG_PGM_PRINT("pgm_data_len > TX_BUF_LEN");
        return;
    }
    
    if (text != NULL) {
        text_len = strlen(text);
    //     DEBUG_PRINT(text);
    //     DEBUG_PGM_PRINT(" has length ");
    //     DEBUG_PRINTLN(text_len, DEC);
    // } else {
    //     DEBUG_PGM_PRINTLN("no text");
    }
    
    data_len = pgm_data_len + text_len;
    if (data_len > TX_BUF_LEN) {
        DEBUG_PGM_PRINT("trimming text to fit with pgm data in TX_BUF_LEN bytes");
        text_len -= (data_len - (TX_BUF_LEN + 1)); // @todo I suck at index math; do I need the +1?

        data_len = pgm_data_len + text_len;
    } 
    
    #if WICKED_VERBOSE
        DEBUG_PGM_PRINT("data_len: ");
        DEBUG_PRINTLN(data_len, DEC);
    #endif
    
    uint8_t *data = (uint8_t *) malloc((size_t) data_len);
    if (data == NULL) {
        DEBUG_PGM_PRINT("[ERROR] Unable to malloc data of length ");
        DEBUG_PRINTLN(data_len, DEC);
        return;
    // } else {
    //     DEBUG_PGM_PRINTLN("malloc()'d data successfully");
    }
    
    #if WICKED_VERBOSE
        DEBUG_PGM_PRINT("pgm_data: ");
    #endif
    for (uint8_t i = 0; i < pgm_data_len; i++) {
        data[i] = pgm_read_byte(&pgm_data[i]);
        #if WICKED_VERBOSE
            DEBUG_PRINT(data[i], HEX);
            DEBUG_PGM_PRINT(" ");
        #endif
    }
    #if WICKED_VERBOSE
        DEBUG_PRINTLN();
    #endif
    
    // fill in the blanks for the channel, band, and preset
    if (send_channel_preset_and_band) {
        data[3] = satelliteState.channel;
        data[4] = ((satelliteState.band << 4) | satelliteState.preset);
    }
    
    // append text
    if (text != NULL) {
        #if DEBUG && DEBUG_PACKET_PARSING
            DEBUG_PGM_PRINT("text: '");
            DEBUG_PRINT(text);
            DEBUG_PGM_PRINT("'");
        #endif
        
        for (uint8_t i = 0; i < text_len; i++) {
            data[pgm_data_len + i] = text[i];
            
            #if DEBUG && DEBUG_PACKET_PARSING
                DEBUG_PGM_PRINT(" ");
                DEBUG_PRINT(data[pgm_data_len + i], HEX);
            #endif
        }
        #if DEBUG && DEBUG_PACKET_PARSING
            DEBUG_PRINTLN();
        #endif
    }
    
    // add space for dest and checksum bytes
    size_t packet_len = data_len + 2;
    #if WICKED_VERBOSE
        DEBUG_PGM_PRINT("packet_len: ");
        DEBUG_PRINTLN(packet_len, DEC);
    #endif
    
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
            DEBUG_PRINTLN();
        #endif
    }
    else {
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
        
        #if DEBUG /* && DEBUG_PACKET_PARSING */
            DEBUG_PGM_PRINT("packet to send: ");
            for (int i = 0; i < tx_ind; i++) {
                DEBUG_PRINT((uint8_t) tx_buf[i], HEX);
                DEBUG_PGM_PRINT(" ");
            }
            DEBUG_PRINTLN();
        #endif

        digitalWrite(LED_GRN, HIGH);
        ledOffTime = millis() + 500L;
        
        // check for bus contention before sending
        // 10 retries before failing (which should be *very* generous)
        for (uint8_t retryCnt = 0; (retryCnt < 10) && (! sent_successfully); retryCnt++) {
            // wait for line to become clear
            boolean contention = false;
            
            // reset timer2 value
            TCNT2 = 0;
            
            // check that the receive buffer doesn't get any data during the timer cycle
            while ((TCNT2 < CONTENTION_TIMEOUT) && (! contention)) {
                if (! (PIND & _BV(0))) { // pin was pulled low, so data being received
                // if (UCSR0A & _BV(RXC0)) { // unread data in the RX buffer
                    contention = true;
                }
            }
            
            if (contention) {
                // someone's sending data; we cannot send
                digitalWrite(LED_RED, HIGH);
                DEBUG_PGM_PRINT("CONTENTION SENDING ");
                DEBUG_PRINTLN(retryCnt, DEC);

                #if DEBUG && DEBUG_PACKET_PARSING
                    uint8_t bytes_availble = Serial.available();
                    if (bytes_availble) {
                        DEBUG_PGM_PRINT("[pkt] buf contents: ");
                        for (int i = 0; i < bytes_availble; i++) {
                            DEBUG_PRINT(Serial.peek(i), HEX);
                            DEBUG_PGM_PRINT(" ");
                        }
                        DEBUG_PRINTLN();
                    }
                #endif
                
                delay(20 * (retryCnt + 1));
            }
            else {
                digitalWrite(LED_RED, LOW);
            
                // disableSerialReceive();
                // Serial.flush();
            
                for (int i = 0; i < tx_ind; i++) {
                    Serial.write((uint8_t) tx_buf[i]);
                }

                // enableSerialReceive();

                #if DEBUG && DEBUG_PACKET_PARSING
                    DEBUG_PGM_PRINTLN("[pkt] done sending");
                #endif

                tx_ind = 0;
            
                sent_successfully = true;
            }
        }
    }
    
    free(data);
    
    if (! sent_successfully) {
        DEBUG_PGM_PRINTLN("unable to send after repeated retries");
    }
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

// {{{ set_state_active
void set_state_active() {
    // if we're transitioning to "on", wake up the iPod and
    // start playing
    if (! satelliteState.active) {
        simpleRemote.sendiPodOn();
        delay(50);
        simpleRemote.sendButtonReleased();
        
        simpleRemote.sendJustPlay();
        simpleRemote.sendButtonReleased();
    }
    
    satelliteState.active = true;
}
// }}}

// {{{ set_state_inactive
void set_state_inactive() {
    // pause the iPod if we're transitioning to inactive
    if (satelliteState.active) {
        simpleRemote.sendJustPause();
        simpleRemote.sendButtonReleased();
    }
    
    satelliteState.active = false;
}
// }}}

