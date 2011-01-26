/*
    The default state for an iPod when it's connected to this adapter is in
    "simple" mode; it should revert to this state whenever it's disconnected.
    
    For our purposes, switching to advanced mode will require resetting
    iPodState to a known state and then enabling advanced mode.
    
    Next up:
    • add handler/getter to track iPod state (playing, paused, stopped)
    • keep the iPod playing even after a reconnect
    • do not pause the iPod when connecting, regardless of modes
    
    Outstanding issues:
    • occasionally gets stuck in paused mode
    • occasionally the iPodWrapper doesn't trigger a metadata update
    • occasionally the first text update has garbage at the end
 */
#define DEBUG 1
#define DEBUG_PACKET_PARSING 0
#define WICKED_VERBOSE 0

#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#include <avr/wdt.h>

#include <SoftwareSerial.h>

// this is to make the Arduino include-path kludge-ifier work for iPodWrapper.h
#include <AdvancedRemote.h>

#include "iPodWrapper.h"
#include "pgm_util.h"

// @todo look into whether the preprocessor will magically convert 
//   strlen("foo") -> 3
// https://lists.linux-foundation.org/pipermail/openais/2010-March/014011.html
#define IBUS_DATA_END_MARKER() "\xAA\xBB"
#define ibus_data(_DATA) PSTR((_DATA IBUS_DATA_END_MARKER()))

const char *IBUS_DATA_END_MARKER = IBUS_DATA_END_MARKER();

// pin mappings
#define INH_PIN 2

// RX for console is not currently supported; need special handling for
// multiple SoftwareSerial instances
#define CONSOLE_RX_PIN 14
#define CONSOLE_TX_PIN 15

#define IPOD_RX_PIN 8 // 14 on chip
#define IPOD_TX_PIN 7 // 13 on chip

#define LED_COLL 19 // red
#define LED_ACT1 18 // yellow
#define LED_ACT2 17 // green

// addresses of IBus devices
#define RAD_ADDR  0x68
#define SDRS_ADDR 0x73

// static offsets into the packet
#define PKT_SRC  0
#define PKT_LEN  1
#define PKT_DEST 2
#define PKT_CMD  3

// SDRS commands
#define SDRS_CMD_POWER          0x00 // power; not seen in Josh's car
#define SDRS_CMD_MODE           0x01 // mode
#define SDRS_CMD_NOW            0x02 // "now"
#define SDRS_CMD_CHAN_UP        0x03 // channel up
#define SDRS_CMD_CHAN_DOWN      0x04 // channel down
#define SDRS_CMD_CHAN_UP_HOLD   0x05 // channel up and hold
#define SDRS_CMD_CHAN_DOWN_HOLD 0x06 // channel down and hold
#define SDRS_CMD_START_SCAN     0x07 // "M" down and hold; start scan
#define SDRS_CMD_PRESET         0x08 // preset recall
#define SDRS_CMD_PRESET_HOLD    0x09 // preset store
#define SDRS_CMD_INF1           0x0E // INF 1st press; display artist
#define SDRS_CMD_INF2           0x0F // INF 2nd press; display song
#define SDRS_CMD_ESN_REQ        0x14 // SAT press and hold; ESN request
#define SDRS_CMD_SAT            0x15 // SAT press; preset bank change

// there may well be a protocol-imposed limit to the max value of a length
// byte in a packet, but it looks like this is the biggest we'll see in
// practice.  Use this as a sort of heuristic to determine if the incoming
// data is valid.
#define MAX_EXPECTED_LEN 64

#define TX_BUF_LEN 80
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
uint8_t tx_buf[TX_BUF_LEN];

// buffer for processing incoming packets; same size as serial buffer
uint8_t rx_buf[RX_BUF_LEN];

typedef enum __sdrs_status_enum {
    SDRS_STATUS_UNKNOWN,
    SDRS_STATUS_INACTIVE,
    SDRS_STATUS_ACTIVE
} SDRSStatusEnum;

typedef struct __sat_state {
    uint8_t channel;
    uint8_t presetBank;
    uint8_t presetNum;
    SDRSStatusEnum status; // whether we're playing or not
    boolean scanning;
} SatState;

SatState satelliteState = {1, 1, 0, SDRS_STATUS_UNKNOWN, false};

// timestamp of last poll from radio
unsigned long lastPoll;

// trigger time to turn off LED
unsigned long ledOffTime;

// timeout duration before giving up on a read
unsigned long readTimeout;

SoftwareSerial nssIPod(IPOD_RX_PIN, IPOD_TX_PIN, false, false, true);
IPodWrapper iPodWrapper;

IPodWrapper::IPodPlayingState iPodPlayState;

#if DEBUG
    unsigned long lastFreeMemCheck;
    
    SoftwareSerial nssConsole(CONSOLE_RX_PIN, CONSOLE_TX_PIN);
#endif

#define CHANNEL_TEXT_LENGTH 10
char channel_text_data[CHANNEL_TEXT_LENGTH + 1];
volatile boolean bus_inhibited;
boolean announcement_sent;

// this'll give me flexibility to swap between soft- and hard-ware serial 
// while developing
Print *console;

// http://www.nongnu.org/avr-libc/user-manual/group__avr__watchdog.html#_details
// http://www.nongnu.org/avr-libc/user-manual/FAQ.html#faq_startup
// http://www.nongnu.org/avr-libc/user-manual/group__largedemo.html#largedemo_code_p4
uint8_t mcusr_mirror __attribute__ ((section (".noinit")));

void get_mcusr_and_disable_wdt(void) \
  __attribute__((naked)) \
  __attribute__((section(".init3")));

void get_mcusr_and_disable_wdt(void) {
  mcusr_mirror = MCUSR;
  MCUSR = 0;
  
  wdt_disable();
}

// {{{ trackChangedHandler
void trackChangedHandler(unsigned long playlistPosition) {
    satelliteState.channel = (uint8_t) playlistPosition;
    update_sdrs_status();
}
// }}}

// {{{ metaDataChangedHandler
void metaDataChangedHandler() {
    update_sdrs_channel_text();
}
// }}}

// {{{ playStateChangedHandler
void playStateChangedHandler(IPodWrapper::IPodPlayingState playState) {
    // PLAY_STATE_UNKNOWN,
    // PLAY_STATE_PLAYING,
    // PLAY_STATE_PAUSED,
    // PLAY_STATE_STOPPED
    
    iPodPlayState = playState;
    
    update_sdrs_channel_text();
}
// }}}

// {{{ iPodModeChangedHandler
// for notification when mode changes between simple and advanced
void iPodModeChangedHandler(IPodWrapper::IPodMode mode) {
    // MODE_UNKNOWN,
    // MODE_SIMPLE,
    // MODE_ADVANCED

    #if DEBUG
        if (mode == IPodWrapper::MODE_UNKNOWN) {
            DEBUG_PGM_PRINTLN("[iPod] went away!");
        } else if (mode == IPodWrapper::MODE_SIMPLE) {
            DEBUG_PGM_PRINTLN("[iPod] switched to simple mode");
        } else if (mode == IPodWrapper::MODE_ADVANCED) {
            DEBUG_PGM_PRINTLN("[iPod] switched to advanced mode");
        }
    #endif
    
    update_sdrs_channel_text();
}
// }}}

#if DEBUG
    extern int __bss_end;
    extern int *__brkval;

    void printFreeMemory() {
        int free_mem;
        if ((int) __brkval == 0) {
            free_mem = ((int) &free_mem) - ((int) &__bss_end);
        } else {
            free_mem = ((int) &free_mem) - ((int)__brkval);
        }
    
        DEBUG_PGM_PRINT("free mem: ");
        DEBUG_PRINTLN(free_mem);
        lastFreeMemCheck = millis();
    }
#endif /* DEBUG */

// {{{ setup
void setup() {
    #if DEBUG
        // RX not supported; see comment near CONSOLE_RX_PIN define
        nssConsole.begin(115200);
        
        console = &nssConsole;
        
        printFreeMemory();
        
        if (mcusr_mirror & _BV(PORF))  DEBUG_PGM_PRINTLN("==== power-on reset ====");
        if (mcusr_mirror & _BV(EXTRF)) DEBUG_PGM_PRINTLN("==== external reset ====");
        if (mcusr_mirror & _BV(BORF))  DEBUG_PGM_PRINTLN("==== brown-out reset ====");
        if (mcusr_mirror & _BV(WDRF))  DEBUG_PGM_PRINTLN("==== watchdog reset ====");
    #endif /* DEBUG */
    
    pinMode(LED_COLL, OUTPUT);
    pinMode(LED_ACT2, OUTPUT);
    pinMode(LED_ACT1, OUTPUT);
    
    pinMode(INH_PIN, INPUT);
    
    // indicate setup is underway
    digitalWrite(LED_ACT1, HIGH);
    
    digitalWrite(LED_ACT1, LOW);
    digitalWrite(LED_ACT2, HIGH);
    announcement_sent = false;
    
    memset(channel_text_data, 0, CHANNEL_TEXT_LENGTH + 1);
    
    // Set up timer2 at Fcpu/1 (no prescaler) for contention detection. Must
    // be done before any IBus serial activity!
    //     CS22:1, CS21:0, CS20:0
    TCCR2B |= _BV(CS22);
    TCCR2B &= ~(_BV(CS21) | _BV(CS20));
    
    // set up serial for IBus; 9600,8,E,1
    Serial.begin(9600);
    UCSR0C |= _BV(UPM01); // even parity
    
    // start the watchdog timer w/ 4s timeout
    wdt_enable(WDTO_4S);

    // test to make sure the bus is alive; if it isn't, shut down (but do not
    // reconfigure) the USART
    
    if (digitalRead(INH_PIN) == LOW) {
        // bus is inhibited
        DEBUG_PGM_PRINTLN("[IBus] bus is inhibited");
    } else {
        DEBUG_PGM_PRINTLN("[IBus] bus is alive");
    }
    
    // can't do anything while the bus is asleep.
    // bus_inhibited = true;
    // while (bus_inhibited) {
    //     wdt_reset();
    //     configureForBusInhibition();
    // }
    // 
    // // enable INT0
    // // @todo use this interrupt to wake the µC from sleep
    // attachInterrupt(0, configureForBusInhibition, CHANGE);    
    
    // baud rate for iPodSerial
    // not having much luck with 38,400; maybe related to my "buffer"
    // implementation (emitter-follower)?  19,200 works in both simple and
    // advanced modes, however, even with the iPhone, it seems!
    
    nssIPod.begin(19200);
    // nssIPod.begin(iPodSerial::IPOD_SERIAL_RATE);
    
    iPodPlayState = IPodWrapper::PLAY_STATE_UNKNOWN;
    
    // for notification when the currently-playing track changes
    iPodWrapper.setTrackChangedHandler(trackChangedHandler);
    iPodWrapper.setMetaDataChangedHandler(metaDataChangedHandler);
    iPodWrapper.setPlayStateChangedHandler(playStateChangedHandler);
    
    // for notification when mode changes between simple and advanced
    iPodWrapper.setModeChangedHandler(iPodModeChangedHandler);

    iPodWrapper.init(&nssIPod, IPOD_RX_PIN);
    
    iPodWrapper.setAdvanced();
    
    // send SDRS announcement
    DEBUG_PGM_PRINTLN("[IBus] sending initial announcement");
    send_sdrs_device_ready_after_reset();
    
    #if DEBUG
        printFreeMemory();
    #endif /* DEBUG */
    
    digitalWrite(LED_COLL, LOW);
    digitalWrite(LED_ACT1, LOW);
    digitalWrite(LED_ACT2, LOW);

    for (int i = 0; i < 3; i++) {
        wdt_reset();
        
        digitalWrite(LED_COLL, HIGH);
        digitalWrite(LED_ACT1, HIGH);
        digitalWrite(LED_ACT2, HIGH);
        delay(250);
        digitalWrite(LED_COLL, LOW);
        digitalWrite(LED_ACT1, LOW);
        digitalWrite(LED_ACT2, LOW);
        delay(250);
    }
}
// }}}

// {{{ loop
void loop() {
    wdt_reset();
    
    if (millis() > ledOffTime) {
        digitalWrite(LED_ACT2, LOW);
    }
    
    iPodWrapper.update();
    
    #if DEBUG
        if (millis() > (lastFreeMemCheck + 10000L)) {
            printFreeMemory();
        }
    #endif /* DEBUG */
    
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
            DEBUG_PGM_PRINTLN("[IBus] haven't seen a poll in a while; we're dead to the radio");
            digitalWrite(LED_COLL, HIGH);
            send_sdrs_device_ready_after_reset();
            lastPoll = millis();
        }
        
        process_incoming_data();
    }
    
    // if (
    //     (iPodPlayState == IPodWrapper::PLAY_STATE_PAUSED) &&
    //     (satelliteState.status == SDRS_STATUS_ACTIVE)
    // ) {
    //     DEBUG_PGM_PRINTLN("[iPod] paused; playing");
    //     iPodWrapper.play();
    // }
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
/*
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
        digitalWrite(LED_ACT1, HIGH);

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
        DEBUG_PGM_PRINTLN("[IBus] dropping byte from unknown source");
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
            DEBUG_PGM_PRINTLN("[IBus] invalid packet length");
            
            #if DEBUG && DEBUG_PACKET_PARSING
                     if (data_len == 0) DEBUG_PGM_PRINTLN("[pkt] length cannot be zero");
                else if (data_len >= MAX_EXPECTED_LEN) DEBUG_PGM_PRINTLN("[pkt] we don't handle messages larger than this");
                else if (data_len >= RX_BUFFER_SIZE) DEBUG_PGM_PRINTLN("[pkt] hard limit to how much data we can buffer");
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

                    #if DEBUG_PACKET_PARSING
                        DEBUG_PGM_PRINT("[pkt] received pkt ");
                    #endif

                    // read packet into buffer and dispatch
                    for (int i = 0; i < pkt_len; i++) {
                        rx_buf[i] = Serial.read();

                        #if DEBUG_PACKET_PARSING
                            DEBUG_PRINT(rx_buf[i], HEX);
                            DEBUG_PGM_PRINT(" ");
                        #endif
                    }

                    #if DEBUG_PACKET_PARSING
                        DEBUG_PRINTLN();
                    #endif
                    
                    #if WICKED_VERBOSE
                        DEBUG_PGM_PRINT("[IBus] packet from ");
                        DEBUG_PRINTLN(rx_buf[PKT_SRC], HEX);
                    #endif
                    
                    dispatch_packet(rx_buf);
                }
                else {
                    // invalid checksum; drop first byte in buffer and try
                    // again
                    DEBUG_PGM_PRINTLN("[IBus] invalid checksum");
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
                        DEBUG_PGM_PRINT("[pkt] read timeout: ");
                        DEBUG_PRINTLN(readTimeout, DEC);
                    #endif
                    
                    readTimeout += millis();
                }
                else if (millis() > readTimeout) {
                    DEBUG_PGM_PRINTLN("[IBus] dropping packet due to read timeout");
                    readTimeout = 0;
                    Serial.remove(1);
                }
            }
        }
    } // if (bytes_availble  >= 2)
    
    digitalWrite(LED_ACT1, LOW);

    return found_message;
}
// }}}

// {{{ dispatch_packet
void dispatch_packet(const uint8_t *packet) {
    // determine if the packet is from the radio and addressed to us, or if there
    // are any other packets we should use as a trigger.
    #if WICKED_VERBOSE
        DEBUG_PGM_PRINT("[IBus] got packet from ");
        DEBUG_PRINTLN(rx_buf[PKT_SRC], HEX);
    #endif
    
    if ((packet[PKT_SRC] == RAD_ADDR) && (packet[PKT_DEST] == 0xFF)) {
        // broadcast from the radio
        
        if (packet[PKT_CMD] == 0x02) {
            // device status ready
            
            // use this as a trigger to send our initial announcment.
            // @todo read up on IBus protocol to see when I should really send 
            // my announcements
            
            DEBUG_PGM_PRINTLN("[IBus] sending SDRS announcement because radio sent device status ready");
            
            // send SDRS announcement
            send_sdrs_device_ready();
        }
    }
    else if ((packet[PKT_SRC] == RAD_ADDR) && (packet[PKT_DEST] == SDRS_ADDR)) {
        // packet sent to SDRS
        
        // check the command byte
        if (packet[PKT_CMD] == 0x01) {
            // handle poll request
            lastPoll = millis();
            
            DEBUG_PGM_PRINTLN("[IBus] responding to poll request");
            send_sdrs_device_ready();
        }
        else if (packet[PKT_CMD] == 0x3D) {
            // command sent that we must reply to
            
            if (packet[4] == SDRS_CMD_POWER) {
                // <3D 00>
                // this is sometimes sent by the radio immediately after
                // our initial announcemnt if the ignition is off (ACC
                // isn't hot). Perhaps only after the IBus is first
                // initialized.  Either way, it seems to indicate that the
                // radio's off and we shouldn't be doing anything.
                
                // respond with
                //   73 .. 68 3E 00 00 1A 11 04
                // -or-
                //   73 .. 68 3E 00 00 95 20 04
                
                DEBUG_PGM_PRINT("[cmd] power, ");
                DEBUG_PRINTLN(packet[5], HEX);
                
                set_state_inactive();
            }
            else if (packet[4] == SDRS_CMD_MODE) {
                // <3D 01>
                // sent when the mode on the radio is changed away from
                // SIRIUS, and when the radio is turned off while SIRIUS
                // is active.
                
                // respond with
                //   73 .. 68 3E 00 00 1A 11 04
                // -or-
                //   73 .. 68 3E 00 00 95 20 04
                
                DEBUG_PGM_PRINT("[cmd] mode, ");
                DEBUG_PRINTLN(packet[5], HEX);
            
                set_state_inactive();
            }
            else if (packet[4] == SDRS_CMD_NOW) {
                // <3D 02>
                // this is the command received when the mode is changed
                // on the radio to select SIRIUS. It is also sent
                // periodically if we don't respond quickly enough with an
                // updated display command (3D 01 00 …)
                DEBUG_PGM_PRINTLN("[cmd] \"now\"");
                
                cancel_current_operation();
                set_state_active();
            }
            else if (packet[4] == SDRS_CMD_CHAN_UP) {
                // <3D 03>
                DEBUG_PGM_PRINTLN("[cmd] channel up");
                
                handle_buttons(packet[4], packet[5]);
                
                // send ACK; <3D 02>
                update_sdrs_status();
                
                delay(100);
                
                update_sdrs_channel_text();
            }
            else if (packet[4] == SDRS_CMD_CHAN_DOWN) {
                // <3D 04>
                DEBUG_PGM_PRINTLN("[cmd] channel down");
                
                handle_buttons(packet[4], packet[5]);
                
                // send ACK; <3E 03>
                send_sdrs_packet(ibus_data("\x3E\x03\x00..\x04"),
                                 NULL, true, true);
                
                delay(100);
                
                update_sdrs_channel_text();
            }
            else if (packet[4] == SDRS_CMD_CHAN_UP_HOLD) {
                // <3D 05>
                DEBUG_PGM_PRINTLN("[cmd] channel up hold");
                
                // @todo
            }
            else if (packet[4] == SDRS_CMD_CHAN_DOWN_HOLD) {
                // <3D 06>
                DEBUG_PGM_PRINTLN("[cmd] channel down hold");

                // @todo
            }
            else if (packet[4] == SDRS_CMD_PRESET) {
                // <3D 08>
                DEBUG_PGM_PRINTLN("[cmd] preset recall");
                
                handle_buttons(packet[4], packet[5]);
                
                // send ACK; <3E 02>
                update_sdrs_status();
                
                delay(100);
                
                update_sdrs_channel_text();
            }
            else if (packet[4] == SDRS_CMD_PRESET_HOLD) {
                // <3D 09>
                DEBUG_PGM_PRINTLN("[cmd] preset set");
                
                handle_buttons(packet[4], packet[5]);
                
                // send ACK; <3E 01 01 00 BP> (Band, Preset)
                // special case of update_sdrs_status
                send_sdrs_packet(ibus_data("\x3E\x01\x01\x00."),
                                 NULL, false, true);
            }
            else if (packet[4] == SDRS_CMD_INF1) {
                // <3D 0E>
                DEBUG_PGM_PRINTLN("[cmd] first inf press");
                
                // send artist
                send_sdrs_packet(ibus_data("\x3E\x01\x06.\x01\x01"),
                                 iPodWrapper.getArtist(),
                                 true, false);
            }
            else if (packet[4] == SDRS_CMD_INF2) {
                // <3D 0F>
                DEBUG_PGM_PRINTLN("[cmd] second inf press");
                
                // send album name
                send_sdrs_packet(ibus_data("\x3E\x01\x07.\x01\x01"),
                                 iPodWrapper.getAlbum(),
                                 true, false);
            }
            else if (packet[4] == SDRS_CMD_ESN_REQ) {
                // <3D 14>
                DEBUG_PGM_PRINTLN("[cmd] ESN request");
                
                // 9 chars displayed, max, prefixed on display with "000"
                // @todo send ipod name?
                send_sdrs_packet(ibus_data("\x3E\x01\x0C\x30\x30\x30"),
                                 "forty two",
                                 false, false);
            }
            else if (packet[4] == SDRS_CMD_SAT) {
                // <3D 15>
                DEBUG_PGM_PRINTLN("[cmd] SAT");
                
                satelliteState.presetBank += 1;
                if (satelliteState.presetBank > 3) {
                    satelliteState.presetBank = 1;
                }
                
                // @todo perform some activity
                
                update_sdrs_status();
            }
            else if (packet[4] == SDRS_CMD_START_SCAN) {
                // <3D 07>
                DEBUG_PGM_PRINTLN("[cmd] starting scan");
                
                satelliteState.scanning = true;
            }
        }
    }
    #if DEBUG && DEBUG_PACKET_PARSING
        else if (packet[PKT_SRC] == SDRS_ADDR) {
            DEBUG_PGM_PRINTLN("[pkt] ignoring packet from myself");
        }
    #endif
}
// }}}

// {{{ handle_buttons
void handle_buttons(uint8_t button_id, uint8_t button_data) {
    switch(button_id) {
        case 0x03: // — channel up
            satelliteState.channel += 1;
            iPodWrapper.nextTrack();
            break;
        
        case 0x04: // — channel down
            satelliteState.channel -= 1;
            iPodWrapper.prevTrack();
            break;
        
        case 0x08: // — preset button pressed
            // data byte 2 is preset number (0x01, 0x02, … 0x06)
            satelliteState.presetNum = button_data;
            break;
        
        case 0x05: // — channel up and hold
            iPodWrapper.nextAlbum();
            break;
            
        case 0x06: // — channel down and hold
            iPodWrapper.prevAlbum();
            break;
        
        case 0x09: // — preset button press and hold
            // data byte 2 is preset number (0x01, 0x02, … 0x06)
            
            // @todo kludge alert!
            // hijack "set preset 6" to switch between advanced and simple modes
            
            if (iPodWrapper.isAdvancedModeActive()) {
                iPodWrapper.setSimple();
            } else {
                iPodWrapper.setAdvanced();
            }
            
            break;
        
        default:
            break;
    }
}
// }}}

// {{{ send_raw_ibus_packet_P
void send_raw_ibus_packet_P(PGM_P pgm_data, size_t pgm_data_len) {
    for (uint8_t i = 0; i < pgm_data_len; i++) {
        tx_buf[i] = pgm_read_byte(&pgm_data[i]);
    }
    
    send_raw_ibus_packet(tx_buf, pgm_data_len);
}
// }}}

// {{{ 
boolean send_raw_ibus_packet(uint8_t *data, size_t data_len) {
    boolean sent_successfully = false;
    
    #if DEBUG && DEBUG_PACKET_PARSING
        DEBUG_PGM_PRINT("[pkt] packet to send: ");
        for (int i = 0; i < data_len; i++) {
            DEBUG_PRINT((uint8_t) data[i], HEX);
            DEBUG_PGM_PRINT(" ");
        }
        DEBUG_PRINTLN();
    #endif
    
    digitalWrite(LED_ACT2, HIGH);
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
            digitalWrite(LED_COLL, HIGH);
            DEBUG_PGM_PRINT("[IBus] CONTENTION SENDING ");
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
            digitalWrite(LED_COLL, LOW);
        
            // disableSerialReceive();
            // Serial.flush();
        
            Serial.write(data, data_len);

            // enableSerialReceive();

            #if DEBUG && DEBUG_PACKET_PARSING
                DEBUG_PGM_PRINTLN("[pkt] done sending");
            #endif

            sent_successfully = true;
        }
    }
    
    return sent_successfully;
}
// }}}

// {{{ send_sdrs_packet
/*
    pgm_data is the static part of the message being sent, ie. without any
    text that may be dynamically generated. It's just a byte (char) array, but
    terminated with the "special" sequence \xAA\xBB, so that I don't need to
    manually keep track of the length. This means that none of these PROGMEM
    strings can have that sequence embedded in them!
*/
void send_sdrs_packet(PGM_P pgm_data,
                      const char *text,
                      boolean send_channel,
                      boolean send_preset)
{
    uint8_t tx_ind;
    
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
    
    uint8_t *data = (uint8_t *) malloc((size_t) (data_len + 2));
    if (data == NULL) {
        DEBUG_PGM_PRINT("[ERROR] Unable to malloc data of length ");
        DEBUG_PRINTLN(data_len + 2, DEC);
        return;
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
    
    // enable scanning flag
    if (satelliteState.scanning && (data[0] == 0x3E)) {
        // 0x01 is channel text update, 0x02 is status update
        // first nibble goes to 1 for these (01 -> 11, 02 -> 12)
        if ((data[1] == 0x01) || (data[1] == 0x02)) {
            data[1] |= (1 << 4);
        }
    }
    
    // fill in the blanks for the channel, preset bank, and preset number
    if (send_channel) {
        data[3] = satelliteState.channel;
    }
    
    if (send_preset) {
        data[4] = ((satelliteState.presetBank << 4) | satelliteState.presetNum);
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
        #if DEBUG
            DEBUG_PGM_PRINTLN("[IBus] dropping message because TX buffer is full!");
            
            DEBUG_PGM_PRINT("data: ");
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
        tx_buf[tx_ind++] = SDRS_ADDR;
        tx_buf[tx_ind++] = packet_len;
        tx_buf[tx_ind++] = RAD_ADDR;

        for (size_t i = 0; i < data_len; i++) {
            tx_buf[tx_ind++] = data[i];
        }

        // calculate checksum, which goes immediately after the last data byte
        tx_buf[tx_ind++] = calc_checksum(&tx_buf[tmp_ind], tx_ind - tmp_ind);
        
        if (! send_raw_ibus_packet(tx_buf, tx_ind)) {
            DEBUG_PGM_PRINTLN("[IBus] unable to send after repeated retries");
        }
    }
    
    free(data);
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

// {{{ send_sdrs_device_ready_after_reset
void send_sdrs_device_ready_after_reset() {
    send_raw_ibus_packet_P(PSTR("\x73\x04\x68\x02\x01\x1c"), 6);
}
// }}}

// {{{ send_sdrs_device_ready
void send_sdrs_device_ready() {
    send_raw_ibus_packet_P(PSTR("\x73\x04\x68\x02\x00\x1d"), 6);
}
// }}}

// {{{ update_sdrs_status
void update_sdrs_status() {
    DEBUG_PGM_PRINTLN("[IBus] updating status");
    
    send_sdrs_packet(ibus_data("\x3E\x02\x00..\x04"),
                     NULL, true, true);
}
// }}}

// {{{ update_sdrs_channel_text
void update_sdrs_channel_text() {
    DEBUG_PGM_PRINTLN("[IBus] updating channel text");

    if (iPodWrapper.isPresent()) {
        if (iPodPlayState == IPodWrapper::PLAY_STATE_PLAYING) {
            if (iPodWrapper.isAdvancedModeActive() && (iPodWrapper.getTitle() != NULL)) {
                strncpy(channel_text_data, iPodWrapper.getTitle(), CHANNEL_TEXT_LENGTH);
            } else {
                strncpy_P(channel_text_data, PSTR("playing"), CHANNEL_TEXT_LENGTH);
            }
        }
        else if (iPodPlayState == IPodWrapper::PLAY_STATE_STOPPED) {
            strncpy_P(channel_text_data, PSTR("stopped"), CHANNEL_TEXT_LENGTH);
        }
        else if (iPodPlayState == IPodWrapper::PLAY_STATE_PAUSED) {
            strncpy_P(channel_text_data, PSTR("paused"), CHANNEL_TEXT_LENGTH);
        }
        else {
            strncpy_P(channel_text_data, PSTR("confused"), CHANNEL_TEXT_LENGTH);
        }
    } else {
        strncpy_P(channel_text_data, PSTR("no iPod"), CHANNEL_TEXT_LENGTH);
    }
    
    send_sdrs_packet(ibus_data("\x3E\x01\x00..\x04"),
                     channel_text_data, true, true);
}
// }}}

// {{{ set_state_active
void set_state_active() {
    if (satelliteState.status != SDRS_STATUS_ACTIVE) {
        // if we're transitioning to "on", wake up the iPod and start playing
        
        iPodWrapper.play();
    }
    
    satelliteState.status = SDRS_STATUS_ACTIVE;
                
    // @todo experiment with returning 3E 01 instead of 3E 02; 01
    // includes text…
    
    // commented for @todo above
    // // text is ignored
    // update_sdrs_status();
    // 
    // // might need to be longer; these two generally follow around
    // // 1.5 to 2 seconds after 3E 02
    // delay(100);
    
    update_sdrs_channel_text();
}
// }}}

// {{{ set_state_inactive
void set_state_inactive() {
    DEBUG_PGM_PRINTLN("[IBus] going inactive for mode/power command");
    send_sdrs_packet(ibus_data("\x3E\x00\x00\x1A\x11\x04"),
                     NULL, false, false);

    iPodWrapper.pause();
    
    satelliteState.status = SDRS_STATUS_INACTIVE;
}
// }}}

// {{{ cancel_current_operation
void cancel_current_operation() {
    if (satelliteState.scanning) {
        satelliteState.scanning = false;
    }
}
// }}}
