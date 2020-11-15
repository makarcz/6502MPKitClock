# $Id: makefile 286 2020-11-15 07:18:23Z mkarcz $
#
# Makefile for clock program on 6502 MP Kit
# Copyright (C) by Marek Karcz 2020.
# All rights reserved.
# Free for personal use.
#
# Uses Telemark Assembler 32-bit to compile:
# Copyright 1985-1993 by Speech Technology Incorporated, all rights reserved.
# Copyright 1998,1999,2001 by Thomas N. Anderson       , all rights reserved.
#
# Uses make tool from Mingw64 package, make sure it is included on your path:
#
#    	set PATH=C:\mingw-w64\x86_64-5.3.0\mingw64\bin;%PATH%
#		mingw32-make clean all
# 

TASM="c:\bin\TASM_32\tasm.exe"

clock.hex: clock.asm
	$(TASM) -65 clock.asm clock.hex

clock: clock.hex

clean:
	del clock.hex clock.lst

all: clock
