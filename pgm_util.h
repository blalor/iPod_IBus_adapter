#ifndef PGM_UTIL_H
#define PGM_UTIL_H

#include <avr/pgmspace.h>
#include "Print.h"

// ==== [macros] ====
#if DEBUG
    /** Prints a message via Serial. **/
    #define DEBUG_PRINT(...) console->print(__VA_ARGS__)
    
    /** Prints a message via Serial, with newline. **/
    #define DEBUG_PRINTLN(...) console->println(__VA_ARGS__)

    #define DEBUG_PGM_PRINT(_msg) pgm_print(console, PSTR(_msg))
    #define DEBUG_PGM_PRINTLN(_msg) pgm_println(console, PSTR(_msg))
#else
    // do nothing
    #define DEBUG_PRINT(...)       /**< No-op. **/
    #define DEBUG_PRINTLN(...)     /**< No-op. **/
    #define DEBUG_PGM_PRINT(...)   /**< No-op. **/
    #define DEBUG_PGM_PRINTLN(...) /**< No-op. **/
#endif

// do like PSTR -> (uint8_t *), but for (int16_t *)
#define PINT(s) \
    ( \
        __extension__ ( \
            { \
                static int16_t *__c PROGMEM = ((int16_t *)(s)); \
                &__c[0]; \
            } \
        ) \
    )

void pgm_print(Print *dest, PGM_P);
void pgm_println(Print *dest, PGM_P);

#endif /* end of include guard: PGM_UTIL_H */
