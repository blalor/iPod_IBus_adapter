#include "pgm_util.h"

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

