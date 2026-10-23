/**
 * The precision the database actually stores, applied before anything is
 * totalled from it.
 *
 * Every rate column in the database is `numeric(14,4)`. A rate this app works
 * out by division usually is not: a carton of 60 at 2,200 is
 * 36.666666666666664 a piece, seventeen digits, because that is what binary
 * floating point makes of two thirds.
 *
 * That difference is not cosmetic. The posting functions compute a document's
 * header total from the number they are sent, while each line's amount is
 * generated from the rate as *stored*. Send seventeen digits and those are two
 * different numbers; on 240 pieces they differ by a whole paisa, and a
 * deferred trigger refuses the document at COMMIT with nothing the person at
 * the screen can act on. Migrations 039 and 040 round at the database end so
 * that can no longer refuse a save. This is the other half: round here too, so
 * the figure on the screen is the figure on the document.
 *
 * Use `rate4` on any rate that came out of a division, and `money2` wherever a
 * line amount or a running total is worked out for display, so the screen adds
 * up the way the database does — line by line, each rounded to the paisa.
 */

/** A rate, at the four decimal places every rate column holds. */
export const rate4 = (n: number) => Math.round(n * 1e4) / 1e4

/** An amount, at the paisa, the way every amount column is generated. */
export const money2 = (n: number) => Math.round(n * 100) / 100
