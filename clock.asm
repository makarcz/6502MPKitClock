; $Id: clock.asm 283 2020-11-15 07:12:35Z mkarcz $
;-----------------------------------------------------------------------------
;                          clock.asm
;-----------------------------------------------------------------------------

; Interrupt driven clock (10 ms TICK) on the 7-seg display
; for the 6502 MP Kit.
; Uses some routines from 7seg.asm (Jeff Rosengarden)
; Uses LCD driver routines provided with the kit.
; Marek Karcz, NOV 2020

;-----------------------------------------------------------------------------

; assembler directives
   .LOCALLABELCHAR "?"

;-----------------------------------------------------------------------------
; MAIN CONSTANTS 
;-----------------------------------------------------------------------------

SEGTAB         = $C906  ; 7-seg bit patterns for character disp. in ROM
GPIO1          = $8000  ; LED-s
PORT0          = $8001  ; Keypad port
PORT1          = $8002  ; 74HC573 for common cathode pins (U12 in circuit)
PORT2          = $8003  ; 74HC573 for digits (U11 in circuit)
BUSY           = $80    ; LCD busy bit       
command_write  = $9000  ; LCD write command address
data_write     = $9001  ; LCD write data address
command_read   = $9002  ; LCD read command address
data_read      = $9003  ; LCD data read address

; use / change both constants below to calibrate clock accuracy
; to compensate for imperfect system clock
; settings below are good for system clock 999,700 kHz, TICK pin
; frequency (IRQ) measured at test point TP1 to be 98.71 Hz

tick_reload    = 98     ; SYSTICK reload value (ideal would be 100 Hz: 99)
skip_reload    = 138    ; How often to skip IRQ service, SKIPCT reload value

; U12 (74HC573 data latch) pin assignments
; for 7 Segment common cathode lines

SEG1D1  = %10011111   ; PC5 
SEG1D2  = %10101111   ; PC4
SEG1D3  = %10110111   ; PC3
SEG1D4  = %10111011   ; PC2
SEG2D1  = %10111101   ; PC1
SEG2D2  = %10111110   ; PC0

; OR mask for decimal point

DPMASK  = %01000000

;-----------------------------------------------------------------------------
; Variables
;-----------------------------------------------------------------------------

; Clock registers

SYSTICK         .EQU    0000H
SECONDS         .EQU    0001H
MINUTES         .EQU    0002H
HOURS           .EQU    0003H
WLED            .EQU    0004H   ; "wandering" LED on the GPIO1 LED-s line

; 7-seg multiplexing

DISPDIGIT       .EQU    0005H   ; which digit (segment) is currently on
DIGITS          .EQU    0006H   ; $06, $07, $08, $09, $0A, $0B (HHMMSS)

; Other

SACC            .EQU    000CH   ; Temporary store for ACC
TEMP            .EQU    000DH   ; 2 bytes, temporary results from subr.
SCREG           .EQU    000FH   ; Set Clock, register being set now
                                ; (0 - hours, 1 - minutes, 2 - seconds)
BKPIRQ          .EQU    0010H   ; 2 bytes, backup of original IRQ vector
SKIPCT          .EQU    0012H   ; Counter for skipping IRQ to compensate
                                ; system clock inaccuracy

;-----------------------------------------------------------------------------
;       EXECUTABLE CODE BEGINS AT ADDRESS $0200
;
;-----------------------------------------------------------------------------

    *= $0200

INIT:    CLD
         SEI               ; disable interrupts
         LDA #tick_reload  ; initialize variables
         STA SCREG
         STA SYSTICK
         LDA #skip_reload
         STA SKIPCT
         LDA #0
         STA DISPDIGIT
         STA SECONDS
         STA MINUTES
         STA HOURS
         LDA #1
         STA WLED
         STA GPIO1
         LDA $FE           ; Backup original IRQ vector
         STA BKPIRQ
         LDA $FF
         STA BKPIRQ+1
         LDA #IRQS&0FFH    ; Set IRQ service vector
         STA $FE
         LDA #(IRQS>>8)
         STA $FF
         CLI               ; enable interrupts
         JSR SetClock
         JSR LcdClkInfo

START:   JSR DispTime
         LDA #%00001000    ; test for '+' key press
         BIT PORT0         ; was '+' pressed?
         BNE ST_01         ; no, jump to next test
         JSR ShortDelay    ; yes, '+' pressed, debounce
         JSR SetClock      ; pause the clock, go to setup mode
         JSR LcdClkInfo    ; after return from setup, change menu
         JMP START         ; and continue
ST_01:   BVS START         ; was 'REP' pressed?
                           ; no, branch to START / yes, end program
         JSR InitLcd       ; clear LCD at exit
         SEI               ; Restore original IRQ vector
         LDA BKPIRQ        ; (monitor program uses it)
         STA $FE
         LDA BKPIRQ+1
         STA $FF
         CLI
        
         BRK               ; return to monitor
         BRK
  
;-----------------------------------------------------------------------------
; Delay routines for PWM (pulse width modulation) to control brightness of
; 7SEG display. Ratio between ON and OFF can be adjusted with the value in
; the Y register.
; PWM ratio = Y in DELAYON / 10
;-----------------------------------------------------------------------------

DELAYON:  LDY #5        
DELAY2:   DEY
          BNE DELAY2
          RTS
          
DELAYOFF: LDY #10
DELAY3:   DEY
          BNE DELAY3
          RTS
          
;-----------------------------------------------------------------------------
; 7 Segment Handling Routines (using PWM)
;-----------------------------------------------------------------------------
          
DIGONOFF: JSR DELAYON         ; run the DELAYON loop
          LDA #%00000000      ; turn the segments off
          STA PORT2
          JSR DELAYOFF        ; run the DELAYOFF loop
          RTS
          
;-----------------------------------------------------------------------------
; Put character on 7-seg display.
; cout requires Segment control value in Accum
;      requires char to display in X Reg         
;-----------------------------------------------------------------------------

COUT:     PHA
          LDA SCREG           ; SCREG < 3 - setup mode
          CMP #3              ; should segment blink?
          BCS CO_NB           ; no, carry on
          BIT SYSTICK         ; blink only if bit 6 of SYSTICK is set
          BVC CO_NB           ; (roughly every second, slightly more)
          LDA SCREG           ; it's blinky time, determine which
          CMP #2              ; digits should blink (HH, MM or SS)
          BEQ CO_BSEC         ; it's SS
          CMP #1
          BEQ CO_BMIN         ; it's MM
          PLA                 ; it's HH
          ORA #%00110000
          PHA
          JMP CO_NB
CO_BSEC:  PLA
          ORA #%00000011
          PHA
          JMP CO_NB
CO_BMIN:  PLA
          ORA #%00001100
          PHA
CO_NB:    PLA
          STA PORT1           ; indicate which digit to activate
          TXA
          STA PORT2           ; indicate which character to display
          TYA
          PHA                 ; push current Y Reg value to stack
          JSR DIGONOFF        ; turn digit on & off using PWM
          PLA
          TAY                 ; restore our Y Reg value from stack
          RTS

;-----------------------------------------------------------------------------
; Display currently active digit of time (mux) and advance to next
;-----------------------------------------------------------------------------

DispTime:   JSR ConvTime2Digits
            LDX DISPDIGIT         ; Retrieve segment control value
            LDA SEG,X
            PHA                   ; Store segment control to stack
            LDX DISPDIGIT         ; Retrieve char to display
            LDA DIGITS,X
            TAX
            LDA SEGTAB,X          ; get actual 7-seg code for digit
            PHA                   ; Store 7-seg code to stack
            LDA DISPDIGIT         ; Check if decimal point should be
            CMP #1                ; enabled (digits 1 or 3: HH.MM.SS)
            BEQ YesDP
            CMP #3
            BEQ YesDP
            CLC
            BCC NoDP
YesDP:      PLA                   ; 7-seg code, stack -> A
            ORA #DPMASK           ; Enable decimal point
            PHA                   ; Store to stack
NoDP:       PLA
            TAX                   ; Char to display, stack -> X
            PLA                   ; Segment control, stack -> A
            JSR COUT
            INC DISPDIGIT         ; Advance display mux to next digit
            LDA DISPDIGIT
            CMP #6
            BCC DispTEnd
            LDA #0                ; DISPDIGIT == 6, reset
            STA DISPDIGIT
DispTEnd:   RTS

;-----------------------------------------------------------------------------
; Convert byte (A) into 2 decimal digits: TEMP, TEMP+1
; Works for A=0..99
;-----------------------------------------------------------------------------

ConvByte2Dec:
            STA SACC
            TXA
            PHA
            CLC
            LDA SACC
            ADC SACC
            TAX
            LDA DECTBL,X
            STA TEMP
            INX
            LDA DECTBL,X
            STA TEMP+1
            PLA
            TAX
            RTS

DECTBL:     .BYTE   0,0,0,1,0,2,0,3,0,4,0,5,0,6,0,7,0,8,0,9
            .BYTE   1,0,1,1,1,2,1,3,1,4,1,5,1,6,1,7,1,8,1,9
            .BYTE   2,0,2,1,2,2,2,3,2,4,2,5,2,6,2,7,2,8,2,9
            .BYTE   3,0,3,1,3,2,3,3,3,4,3,5,3,6,3,7,3,8,3,9
            .BYTE   4,0,4,1,4,2,4,3,4,4,4,5,4,6,4,7,4,8,4,9
            .BYTE   5,0,5,1,5,2,5,3,5,4,5,5,5,6,5,7,5,8,5,9
            .BYTE   6,0,6,1,6,2,6,3,6,4,6,5,6,6,6,7,6,8,6,9
            .BYTE   7,0,7,1,7,2,7,3,7,4,7,5,7,6,7,7,7,8,7,9
            .BYTE   8,0,8,1,8,2,8,3,8,4,8,5,8,6,8,7,8,8,8,9
            .BYTE   9,0,9,1,9,2,9,3,9,4,9,5,9,6,9,7,9,8,9,9

;-----------------------------------------------------------------------------
; Convert 3 clock time keeping registers to 6 decimal digits: HHMMSS
;-----------------------------------------------------------------------------

ConvTime2Digits:

         LDA HOURS
         JSR ConvByte2Dec
         LDX #0
         LDA TEMP
         STA DIGITS,X
         INX
         LDA TEMP+1
         STA DIGITS,X
         LDA MINUTES
         JSR ConvByte2Dec
         LDA TEMP
         INX
         STA DIGITS,X
         LDA TEMP+1
         INX
         STA DIGITS,X
         LDA SECONDS
         JSR ConvByte2Dec
         LDA TEMP
         INX
         STA DIGITS,X
         LDA TEMP+1
         INX
         STA DIGITS,X
         RTS

;-----------------------------------------------------------------------------
; Set clock using keypad and 7-seg LED display.
;-----------------------------------------------------------------------------

SetClock:
         JSR InitLcd
         LDX #0
         STX SCREG
SC_l001: LDA lcd_text_03,x
         BEQ SC_nxt
		   JSR putch_lcd
         INX
         BNE SC_l001
SC_nxt:  LDY #0
         LDX #1
         JSR goto_xy
         LDX #0
SC_l0a1: LDA lcd_text_04,x
         BEQ SC_l002
		   JSR putch_lcd
         INX
         BNE SC_l0a1
SC_l002: JSR DispTime
         BIT PORT0         ; test for REP key press (bit 6, flag V)
         BVS SC_l0a2       ; key not pressed, branch to next test
         LDA SCREG         ; REP pressed, which clock reg. we're increasing?
         CMP #2            ; seconds?
         BEQ SC_SS
         CMP #1            ; minutes?
         BEQ SC_SM
         INC HOURS         ; none of the above, increment hours
         LDA HOURS
         CMP #24
         BNE SC_l004
         LDA #0
         STA HOURS
         JMP SC_l004
SC_l0a2: LDA #%00000010    ; test for '-' key press
         BIT PORT0         ; was '-' pressed?
         BNE SC_l0a3       ; no, branch to next test
         LDA SCREG         ; '-' pressed, which clock reg. we're decrementing?
         CMP #2            ; seconds?
         BEQ SC_SS2
         CMP #1            ; minutes?
         BEQ SC_SM2
         DEC HOURS         ; none of the above, decrement hours
         LDA HOURS
         CMP #255
         BNE SC_l004
         LDA #23
         STA HOURS
         JMP SC_l004
SC_SS2:  DEC SECONDS       ; decrement seconds
         LDA SECONDS
         CMP #255
         BNE SC_l004
         LDA #59
         STA SECONDS
         JMP SC_l004
SC_SM2:  DEC MINUTES
         LDA MINUTES
         CMP #255
         BNE SC_l004
         LDA #59
         STA MINUTES
         JMP SC_l004
SC_l0a3: LDA #%00001000    ; test for '+' key press
         BIT PORT0         ; was '+' pressed?
         BNE SC_l002       ; no, jump to loop
SC_l003: JSR ShortDelay    ; '+' pressed, key debounce
         INC SCREG         ; and advance to next clock register
         LDA SCREG
         CMP #3            ; are we done?
         BNE SC_l002       ; nope, continue
         JMP SC_End        ; yes, jump to end
SC_SS:   INC SECONDS       ; increment seconds
         LDA SECONDS
         CMP #60
         BNE SC_l004
         LDA #0
         STA SECONDS
         JMP SC_l004
SC_SM:   INC MINUTES       ; increment minutes
         LDA MINUTES
         CMP #60
         BNE SC_l004
         LDA #0
         STA MINUTES
         JMP SC_l004
SC_l004: JSR ShortDelay    ; for key debounce
         JMP SC_l002
SC_End:  RTS

;-----------------------------------------------------------------------------
; SYSTICK is incremented in IRQ service routine if clock is in setup mode
; every 10 ms. Bit 6 is used to decide when the segments representing
; clock register currently being set should blink. Routine below clears
; bit 6 of SYSTICK to turn the segments ON, this is needed after the
; key on the keppad is pressed so user can see the changing value on the
; display uninterrupted by blinking.
;-----------------------------------------------------------------------------

TempBlinkDis:
         LDA SYSTICK
         AND #%10111111    ; clear bit 6 - temp. blink disable, for user
         STA SYSTICK       ; to see digits change while key is pressed
         RTS

;-----------------------------------------------------------------------------
; Delay used to debounce key press during clock setup.
; At the same time user needs to see changing digits without
; blinking f the key was pressed (or is held down), therefore subroutine
; TempBlinkDis is called in the inner loop before each call to DispTime.
;-----------------------------------------------------------------------------

ShortDelay:
         PHA
         LDX #$FF
SD_l000: LDY #$02       ; outer loop
         TXA
         PHA
SD_l001: DEY            ; inner loop
         TYA
         PHA
         JSR TempBlinkDis
         JSR DispTime
         PLA
         TAY
         BNE SD_l001    ; end of inner loop
         PLA
         TAX
         DEX
         BNE SD_l000    ; end of outer loop
         PLA
         RTS

;-----------------------------------------------------------------------------
; IRQ service routine, timekeeping (called every 10 ms or 100 times / sec)
;-----------------------------------------------------------------------------

IRQS:       PHA               ; Preserve A on stack
            DEC SKIPCT        ; Decrement skip IRQ counter
            LDA SKIPCT
            BNE IRQS_L00      ; Not yet 0, continue with service
            LDA #skip_reload  ; Skip counter == 0, reload and
            STA SKIPCT        ; skip the service
            PLA
            RTI
IRQS_L00:   LDA SCREG         ; check if setup mode
            CMP #3
            BCS IRQS_CLOCK    ; not setup mode, branch to full IRQ service
            INC SYSTICK       ; setup mode, only increment SYSTICK and
            PLA               ; return
            RTI
IRQS_CLOCK: TXA               ; full IRQ service / timekeeping begins here
            PHA               ; Preserve X on stack
            LDX #0
            DEC SYSTICK       ; when SYSTICK reaches 0, one second of time
            BNE IRQS_END      ; has passed, otherwise nothing to do
            LDA #tick_reload  ; SYSTICK == 0, reload
            STA SYSTICK
            INC SECONDS       ; increment seconds
            CLC               ; shift "wandering" LED on the LED-s line
            ROL WLED          ; to the left in circular fashion (disapear
            BCC IRQS_00       ; on the left, reappear on the right)
            ROL WLED
IRQS_00:    LDA WLED
            STA GPIO1
            LDA SECONDS
            CMP #60
            BCC IRQS_END
            STX SECONDS       ; SECONDS >= 60, reset
            INC MINUTES       ; and increment MINUTES
            LDA MINUTES
            CMP #60
            BCC IRQS_END
            STX MINUTES       ; MINUTES >= 60, reset
            INC HOURS         ; and increment hours
            LDA HOURS
            CMP #24
            BCC IRQS_END
            STX HOURS         ; HOURS >= 24, reset
IRQS_END:   PLA               ; Restore X from stack
            TAX
            PLA               ; Restore A from stack
            RTI

;-----------------------------------------------------------------------------
; LCD driver routines.
;-----------------------------------------------------------------------------

; Wait until LCD ready bit set

LcdReady:   PHA
ready:      LDA command_read
            AND #BUSY
            BNE ready   ; loop if busy flag = 1
            PLA
		      RTS
		
; Write command to LCD module

LCD_command_write: 
            JSR LcdReady
            STA command_write
		      RTS

; Write data to LCD module

LCD_data_write:
            JSR LcdReady
            STA data_write
            RTS

; Clear screen of LCD module

clr_screen: JSR LcdReady
            LDA #1
		      JSR LCD_command_write
            RTS

; Initialize LCD module

InitLcd:    LDA #38H
            JSR LCD_command_write
            LDA #0CH
	         JSR LCD_command_write
            JSR clr_screen
            LDX #0
		      LDY #0
		      JSR goto_xy
            RTS

; goto_xy(x,y)
; entry: Y = y position
;        X = x position

goto_xy:    TXA
            CMP #0
		      BNE case1
            TYA
		      CLC
            ADC #80H
            JSR LCD_command_write
		      RTS
                 
case1:      CMP #1
            BNE case2
            TYA
		      CLC
		      ADC #0C0H
		      JSR LCD_command_write
		      RTS
                 
case2:      RTS

; write ASCII code to LCD at current position
; entry: A

putch_lcd:  JSR LcdReady
            JSR LCD_data_write
            RTS

LcdClkInfo: JSR InitLcd
            LDX #0
l001:       LDA lcd_text_01,x
            BEQ nxttext
		      JSR putch_lcd
            INX
            BNE l001
nxttext:    LDY #0
            LDX #1
            JSR goto_xy
            LDX #0
l002:       LDA lcd_text_02,x
            BEQ lci_end
		      JSR putch_lcd
            INX
            BNE l002
lci_end:    RTS
      
;-----------------------------------------------------------------------------
; Data for 7-seg display.
;
;         Dig0    Dig1    Dig2    Dig3    Dig4    Dig5
;-----------------------------------------------------------------------------

SEG .byte SEG1D1, SEG1D2, SEG1D3, SEG1D4, SEG2D1, SEG2D2

; Data below exists in ROM (firmware), so I use that instead
;SEGTAB: ;7 segment bit patterns for character display 
;  .BYTE 0BDH    ;'0'
;  .BYTE 030H    ;'1'
;  .BYTE 09BH    ;'2'
;  .BYTE 0BAH    ;'3'
;  .BYTE 036H    ;'4'
;  .BYTE 0AEH    ;'5'
;  .BYTE 0AFH    ;'6'
;  .BYTE 038H    ;'7'
;  .BYTE 0BFH    ;'8'
;  .BYTE 0BEH    ;'9'
;  .BYTE 03FH    ;'A'
;  .BYTE 0A7H    ;'B'
;  .BYTE 08DH    ;'C'
;  .BYTE 0B3H    ;'D'
;  .BYTE 08FH    ;'E'
;  .BYTE 00FH    ;'F'

;-----------------------------------------------------------------------------
; Data for LCD
;-----------------------------------------------------------------------------

lcd_text_01:   .byte "Clock running...", 0
lcd_text_02:   .byte "[REP]End [+]Set", 0
lcd_text_03:   .byte "Setting clock...", 0
lcd_text_04:   .byte "[REP/-]+/-[+]Nxt", 0
  

  .END
  
