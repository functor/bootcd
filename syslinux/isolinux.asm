; -*- fundamental -*- (asm-mode sucks)
; $Id: isolinux.asm,v 1.113 2004/12/30 21:16:04 hpa Exp $
; ****************************************************************************
;
;  isolinux.asm
;
;  A program to boot Linux kernels off a CD-ROM using the El Torito
;  boot standard in "no emulation" mode, making the entire filesystem
;  available.  It is based on the SYSLINUX boot loader for MS-DOS
;  floppies.
;
;   Copyright (C) 1994-2004  H. Peter Anvin
;
;  This program is free software; you can redistribute it and/or modify
;  it under the terms of the GNU General Public License as published by
;  the Free Software Foundation, Inc., 53 Temple Place Ste 330,
;  Boston MA 02111-1307, USA; either version 2 of the License, or
;  (at your option) any later version; incorporated herein by reference.
;
; ****************************************************************************

%define IS_ISOLINUX 1
%include "macros.inc"
%include "config.inc"
%include "kernel.inc"
%include "bios.inc"
%include "tracers.inc"
%include "layout.inc"

;
; Some semi-configurable constants... change on your own risk.
;
my_id		equ isolinux_id
FILENAME_MAX_LG2 equ 8			; log2(Max filename size Including final null)
FILENAME_MAX	equ (1 << FILENAME_MAX_LG2)
NULLFILE	equ 0			; Zero byte == null file name
NULLOFFSET	equ 0			; Position in which to look
retry_count	equ 6			; How patient are we with the BIOS?
%assign HIGHMEM_SLOP 128*1024		; Avoid this much memory near the top
MAX_OPEN_LG2	equ 6			; log2(Max number of open files)
MAX_OPEN	equ (1 << MAX_OPEN_LG2)
SECTOR_SHIFT	equ 11			; 2048 bytes/sector (El Torito requirement)
SECTOR_SIZE	equ (1 << SECTOR_SHIFT)

;
; This is what we need to do when idle
;
%macro	RESET_IDLE 0
	; Nothing
%endmacro
%macro	DO_IDLE 0
	; Nothing
%endmacro

;
; The following structure is used for "virtual kernels"; i.e. LILO-style
; option labels.  The options we permit here are `kernel' and `append
; Since there is no room in the bottom 64K for all of these, we
; stick them at vk_seg:0000 and copy them down before we need them.
;
		struc vkernel
vk_vname:	resb FILENAME_MAX	; Virtual name **MUST BE FIRST!**
vk_rname:	resb FILENAME_MAX	; Real name
vk_appendlen:	resw 1
		alignb 4
vk_append:	resb max_cmd_len+1	; Command line
		alignb 4
vk_end:		equ $			; Should be <= vk_size
		endstruc

;
; Segment assignments in the bottom 640K
; 0000h - main code/data segment (and BIOS segment)
;
real_mode_seg	equ 3000h
vk_seg          equ 2000h		; Virtual kernels
xfer_buf_seg	equ 1000h		; Bounce buffer for I/O to high mem
comboot_seg	equ real_mode_seg	; COMBOOT image loading zone

;
; File structure.  This holds the information for each currently open file.
;
		struc open_file_t
file_sector	resd 1			; Sector pointer (0 = structure free)
file_left	resd 1			; Number of sectors left
		endstruc

%ifndef DEPEND
%if (open_file_t_size & (open_file_t_size-1))
%error "open_file_t is not a power of 2"
%endif
%endif

		struc dir_t
dir_lba		resd 1			; Directory start (LBA)
dir_len		resd 1			; Length in bytes
dir_clust	resd 1			; Length in clusters
		endstruc

; ---------------------------------------------------------------------------
;   BEGIN CODE
; ---------------------------------------------------------------------------

;
; Memory below this point is reserved for the BIOS and the MBR
;
		section .earlybss
trackbufsize	equ 8192
trackbuf	resb trackbufsize	; Track buffer goes here
getcbuf		resb trackbufsize
;		ends at 4800h

		section .bss
		alignb 4
ISOFileName	resb 64			; ISO filename canonicalization buffer
ISOFileNameEnd	equ $
CurDir		resb dir_t_size		; Current directory
RootDir		resb dir_t_size		; Root directory
FirstSecSum	resd 1			; Checksum of bytes 64-2048
ImageDwords	resd 1			; isolinux.bin size, dwords
InitStack	resd 1			; Initial stack pointer (SS:SP)
DiskSys		resw 1			; Last INT 13h call
ImageSectors	resw 1			; isolinux.bin size, sectors
DiskError	resb 1			; Error code for disk I/O
DriveNo		resb 1			; CD-ROM BIOS drive number
ISOFlags	resb 1			; Flags for ISO directory search
RetryCount      resb 1			; Used for disk access retries

_spec_start	equ $

;
; El Torito spec packet
;

		alignb 8
spec_packet:	resb 1				; Size of packet
sp_media:	resb 1				; Media type
sp_drive:	resb 1				; Drive number
sp_controller:	resb 1				; Controller index
sp_lba:		resd 1				; LBA for emulated disk image
sp_devspec:	resw 1				; IDE/SCSI information
sp_buffer:	resw 1				; User-provided buffer
sp_loadseg:	resw 1				; Load segment
sp_sectors:	resw 1				; Sector count
sp_chs:		resb 3  			; Simulated CHS geometry
sp_dummy:	resb 1				; Scratch, safe to overwrite

;
; EBIOS drive parameter packet
;
		alignb 8
drive_params:	resw 1				; Buffer size
dp_flags:	resw 1				; Information flags
dp_cyl:		resd 1				; Physical cylinders
dp_head:	resd 1				; Physical heads
dp_sec:		resd 1				; Physical sectors/track
dp_totalsec:	resd 2				; Total sectors
dp_secsize:	resw 1				; Bytes per sector
dp_dpte:	resd 1				; Device Parameter Table
dp_dpi_key:	resw 1				; 0BEDDh if rest valid
dp_dpi_len:	resb 1				; DPI len
		resb 1
		resw 1
dp_bus:		resb 4				; Host bus type
dp_interface:	resb 8				; Interface type
db_i_path:	resd 2				; Interface path
db_d_path:	resd 2				; Device path
		resb 1
db_dpi_csum:	resb 1				; Checksum for DPI info

;
; EBIOS disk address packet
;
		alignb 8
dapa:		resw 1				; Packet size
.count:		resw 1				; Block count
.off:		resw 1				; Offset of buffer
.seg:		resw 1				; Segment of buffer
.lba:		resd 2				; LBA (LSW, MSW)

;
; Spec packet for disk image emulation
;
		alignb 8
dspec_packet:	resb 1				; Size of packet
dsp_media:	resb 1				; Media type
dsp_drive:	resb 1				; Drive number
dsp_controller:	resb 1				; Controller index
dsp_lba:	resd 1				; LBA for emulated disk image
dsp_devspec:	resw 1				; IDE/SCSI information
dsp_buffer:	resw 1				; User-provided buffer
dsp_loadseg:	resw 1				; Load segment
dsp_sectors:	resw 1				; Sector count
dsp_chs:	resb 3				; Simulated CHS geometry
dsp_dummy:	resb 1				; Scratch, safe to overwrite

		alignb 4
_spec_end	equ $
_spec_len	equ _spec_end - _spec_start

		alignb open_file_t_size
Files		resb MAX_OPEN*open_file_t_size

;
; Constants for the xfer_buf_seg
;
; The xfer_buf_seg is also used to store message file buffers.  We
; need two trackbuffers (text and graphics), plus a work buffer
; for the graphics decompressor.
;
xbs_textbuf	equ 0			; Also hard-coded, do not change
xbs_vgabuf	equ trackbufsize
xbs_vgatmpbuf	equ 2*trackbufsize

		section .text
;;
;; Primary entry point.  Because BIOSes are buggy, we only load the first
;; CD-ROM sector (2K) of the file, so the number one priority is actually
;; loading the rest.
;;
bootsec		equ $

StackBuf	equ $-44

_start:		; Far jump makes sure we canonicalize the address
		cli
		jmp 0:_start1
		times 8-($-$$) nop		; Pad to file offset 8

		; This table hopefully gets filled in by mkisofs using the
		; -boot-info-table option.  If not, the values in this
		; table are default values that we can use to get us what
		; we need, at least under a certain set of assumptions.
bi_pvd:		dd 16				; LBA of primary volume descriptor
bi_file:	dd 0				; LBA of boot file
bi_length:	dd 0xdeadbeef			; Length of boot file
bi_csum:	dd 0xdeadbeef			; Checksum of boot file
bi_reserved:	times 10 dd 0xdeadbeef		; Reserved

_start1:	mov [cs:InitStack],sp		; Save initial stack pointer
		mov [cs:InitStack+2],ss
		xor ax,ax
		mov ss,ax
		mov sp,StackBuf			; Set up stack
		mov ds,ax
		mov es,ax
		mov fs,ax
		mov gs,ax
		sti

		cld
		; Show signs of life
		mov si,syslinux_banner
		call writestr
%ifdef DEBUG_MESSAGES
		mov si,copyright_str
		call writestr
%endif

		;
		; Before modifying any memory, get the checksum of bytes
		; 64-2048
		;
initial_csum:	xor edi,edi
		mov si,_start1
		mov cx,(SECTOR_SIZE-64) >> 2
.loop:		lodsd
		add edi,eax
		loop .loop
		mov [FirstSecSum],edi

		mov [DriveNo],dl
%ifdef DEBUG_MESSAGES
		mov si,startup_msg
		call writemsg
		mov al,dl
		call writehex2
		call crlf
%endif
		;
		; Initialize spec packet buffers
		;
		mov di,_spec_start
		mov cx,_spec_len >> 2
		xor eax,eax
		rep stosd

		; Initialize length field of the various packets
		mov byte [spec_packet],13h
		mov byte [drive_params],30
		mov byte [dapa],16
		mov byte [dspec_packet],13h

		; Other nonzero fields
		inc word [dsp_sectors]

		; Now figure out what we're actually doing
		; Note: use passed-in DL value rather than 7Fh because
		; at least some BIOSes will get the wrong value otherwise
		mov ax,4B01h			; Get disk emulation status
		mov dl,[DriveNo]
		mov si,spec_packet
		int 13h
		jc award_hack			; changed for BrokenAwardHack
		mov dl,[DriveNo]
		cmp [sp_drive],dl		; Should contain the drive number
		jne spec_query_failed

%ifdef DEBUG_MESSAGES
		mov si,spec_ok_msg
		call writemsg
		mov al,byte [sp_drive]
		call writehex2
		call crlf
%endif

found_drive:
		; Alright, we have found the drive.  Now, try to find the
		; boot file itself.  If we have a boot info table, life is
		; good; if not, we have to make some assumptions, and try
		; to figure things out ourselves.  In particular, the
		; assumptions we have to make are:
		; - single session only
		; - only one boot entry (no menu or other alternatives)

		cmp dword [bi_file],0		; Address of code to load
		jne found_file			; Boot info table present :)

%ifdef DEBUG_MESSAGES
		mov si,noinfotable_msg
		call writemsg
%endif
		
		; No such luck.  See if the the spec packet contained one.
		mov eax,[sp_lba]
		and eax,eax
		jz set_file			; Good enough

%ifdef DEBUG_MESSAGES
		mov si,noinfoinspec_msg
		call writemsg
%endif
		
		; No such luck.  Get the Boot Record Volume, assuming single
		; session disk, and that we're the first entry in the chain
		mov eax,17			; Assumed address of BRV
		mov bx,trackbuf
		call getonesec

		mov eax,[trackbuf+47h]		; Get boot catalog address
		mov bx,trackbuf
		call getonesec			; Get boot catalog

		mov eax,[trackbuf+28h]		; First boot entry
		; And hope and pray this is us...

		; Some BIOSes apparently have limitations on the size 
		; that may be loaded (despite the El Torito spec being very
		; clear on the fact that it must all be loaded.)  Therefore,
		; we load it ourselves, and *bleep* the BIOS.

set_file:
		mov [bi_file],eax

found_file:
		; Set up boot file sizes
		mov eax,[bi_length]
		sub eax,SECTOR_SIZE-3
		shr eax,2			; bytes->dwords
		mov [ImageDwords],eax		; boot file dwords
		add eax,(2047 >> 2)
		shr eax,9			; dwords->sectors
		mov [ImageSectors],ax		; boot file sectors

		mov eax,[bi_file]		; Address of code to load
		inc eax				; Don't reload bootstrap code
%ifdef DEBUG_MESSAGES
		mov si,offset_msg
		call writemsg
		call writehex8
		call crlf
%endif

		; Just in case some BIOSes have problems with
		; segment wraparound, use the normalized address
		mov bx,((7C00h+2048) >> 4)
		mov es,bx
		xor bx,bx
		mov bp,[ImageSectors]
%ifdef DEBUG_MESSAGES
		push ax
		mov si,size_msg
		call writemsg
		mov ax,bp
		call writehex4
		call crlf
		pop ax
%endif
		call getlinsec

		push ds
		pop es

%ifdef DEBUG_MESSAGES
		mov si,loaded_msg
		call writemsg
%endif

		; Verify the checksum on the loaded image.
verify_image:
		mov si,7C00h+2048
		mov bx,es
		mov ecx,[ImageDwords]
		mov edi,[FirstSecSum]		; First sector checksum
.loop		es lodsd
		add edi,eax
		dec ecx
		jz .done
		and si,si
		jnz .loop
		; SI wrapped around, advance ES
		add bx,1000h
		mov es,bx
		jmp short .loop
.done:		mov ax,ds
		mov es,ax
		cmp [bi_csum],edi
		je integrity_ok

		mov si,checkerr_msg
		call writemsg
		jmp kaboom

integrity_ok:
%ifdef DEBUG_MESSAGES
		mov si,allread_msg
		call writemsg
%endif
		jmp all_read			; Jump to main code

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Start of BrokenAwardHack --- 10-nov-2002           Knut_Petersen@t-online.de
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; There is a problem with certain versions of the AWARD BIOS ... 
;; the boot sector will be loaded and executed correctly, but, because the
;; int 13 vector points to the wrong code in the BIOS, every attempt to
;; load the spec packet will fail. We scan for the equivalent of
;;
;;	mov	ax,0201h
;;	mov	bx,7c00h
;;	mov	cx,0006h
;;	mov	dx,0180h
;;	pushf
;;	call	<direct far>
;;
;; and use <direct far> as the new vector for int 13. The code above is
;; used to load the boot code into ram, and there should be no reason
;; for anybody to change it now or in the future. There are no opcodes
;; that use encodings relativ to IP, so scanning is easy. If we find the
;; code above in the BIOS code we can be pretty sure to run on a machine
;; with an broken AWARD BIOS ... 
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
									     ;;
%ifdef DEBUG_MESSAGES							     ;;
									     ;;
award_notice	db	"Trying BrokenAwardHack first ...",CR,LF,0	     ;;
award_not_orig	db	"BAH: Original Int 13 vector   : ",0		     ;;
award_not_new	db	"BAH: Int 13 vector changed to : ",0		     ;;
award_not_succ	db	"BAH: SUCCESS",CR,LF,0				     ;;
award_not_fail	db	"BAH: FAILURE"					     ;;
award_not_crlf	db	CR,LF,0						     ;;
									     ;;
%endif									     ;;
									     ;;
award_oldint13	dd	0						     ;;
award_string	db	0b8h,1,2,0bbh,0,7ch,0b9h,6,0,0bah,80h,1,09ch,09ah    ;;
									     ;;
						;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
award_hack:	mov 	si,spec_err_msg		; Moved to this place from
		call 	writemsg		; spec_query_faild
						;
%ifdef DEBUG_MESSAGES				;
						;
		mov	si,award_notice		; display our plan
		call	writemsg		;
		mov	si,award_not_orig	; display original int 13
		call	writemsg		; vector
%endif						;
		mov	eax,[13h*4]		;
		mov	[award_oldint13],eax	;
						;
%ifdef DEBUG_MESSAGES				;
						;
		call	writehex8		;
		mov	si,award_not_crlf	; 
		call	writestr		;
%endif						;
		push	es			; save ES
		mov 	ax,0f000h		; ES = BIOS Seg
		mov 	es,ax			;
	    	cld				;
		xor 	di,di			; start at ES:DI = f000:0
award_loop:	push 	di			; save DI
		mov 	si,award_string		; scan for award_string
		mov	cx,7			; length of award_string = 7dw
		repz 	cmpsw			; compare
		pop 	di			; restore DI
		jcxz 	award_found		; jmp if found
		inc 	di			; not found, inc di
		jno	award_loop		; 
						;
award_failed:	pop	es			; No, not this way :-((
award_fail2:					;
						;
%ifdef DEBUG_MESSAGES				;
						;
		mov	si,award_not_fail	; display failure ...
		call	writemsg		;
%endif						;
		mov	eax,[award_oldint13]	; restore the original int
		or	eax,eax			; 13 vector if there is one
		jz	spec_query_failed	; and try other workarounds
		mov	[13h*4],eax		;
		jmp	spec_query_failed	;
						;
award_found:	mov	eax,[es:di+0eh]		; load possible int 13 addr
		pop	es			; restore ES
						;
		cmp	eax,[award_oldint13]	; give up if this is the
		jz	award_failed		; active int 13 vector,
		mov	[13h*4],eax		; otherwise change 0:13h*4
						;
						;
%ifdef DEBUG_MESSAGES				;
						;
		push	eax			; display message and 
		mov	si,award_not_new	; new vector address
		call	writemsg		;
		pop	eax			;
		call	writehex8		;
		mov	si,award_not_crlf	;
		call	writestr		;
%endif						;
		mov 	ax,4B01h		; try to read the spec packet
		mov 	dl,[DriveNo]		; now ... it should not fail
		mov 	si,spec_packet		; any longer
		int 	13h			; 
		jc	award_fail2		;
						;
%ifdef DEBUG_MESSAGES				;
						;
		mov	si,award_not_succ	; display our SUCCESS
		call	writemsg		;
%endif						;
		jmp	found_drive		; and leave error recovery code
						;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; End of BrokenAwardHack ----            10-nov-2002 Knut_Petersen@t-online.de
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


		; INT 13h, AX=4B01h, DL=<passed in value> failed.
		; Try to scan the entire 80h-FFh from the end.

spec_query_failed:

		; some code moved to BrokenAwardHack

		mov dl,0FFh
.test_loop:	pusha
		mov ax,4B01h
		mov si,spec_packet
		mov byte [si],13		; Size of buffer
		int 13h
		popa
		jc .still_broken

		mov si,maybe_msg
		call writemsg
		mov al,dl
		call writehex2
		call crlf

		cmp byte [sp_drive],dl
		jne .maybe_broken

		; Okay, good enough...
		mov si,alright_msg
		call writemsg
		mov [DriveNo],dl
.found_drive:	jmp found_drive

		; Award BIOS 4.51 apparently passes garbage in sp_drive,
		; but if this was the drive number originally passed in
		; DL then consider it "good enough"
.maybe_broken:
		cmp byte [DriveNo],dl
		je .found_drive

.still_broken:	dec dx
		cmp dl, 80h
		jnb .test_loop

		; No spec packet anywhere.  Some particularly pathetic
		; BIOSes apparently don't even implement function
		; 4B01h, so we can't query a spec packet no matter
		; what.  If we got a drive number in DL, then try to
		; use it, and if it works, then well...
		mov dl,[DriveNo]
		cmp dl,81h			; Should be 81-FF at least
		jb fatal_error			; If not, it's hopeless

		; Write a warning to indicate we're on *very* thin ice now
		mov si,nospec_msg
		call writemsg
		mov al,dl
		call writehex2
		call crlf
		mov si,trysbm_msg
		call writemsg
		jmp .found_drive		; Pray that this works...

fatal_error:
		mov si,nothing_msg
		call writemsg

.norge:		jmp short .norge

		; Information message (DS:SI) output
		; Prefix with "isolinux: "
		;
writemsg:	push ax
		push si
		mov si,isolinux_str
		call writestr
		pop si
		call writestr
		pop ax				
		ret

;
; Write a character to the screen.  There is a more "sophisticated"
; version of this in the subsequent code, so we patch the pointer
; when appropriate.
;

writechr:
		jmp near writechr_simple	; 3-byte jump

writechr_simple:
		pushfd
		pushad
		mov ah,0Eh
		xor bx,bx
		int 10h
		popad
		popfd
		ret

;
; Get one sector.  Convenience entry point.
;
getonesec:
		mov bp,1
		; Fall through to getlinsec

;
; Get linear sectors - EBIOS LBA addressing, 2048-byte sectors.
;
; Note that we can't always do this as a single request, because at least
; Phoenix BIOSes has a 127-sector limit.  To be on the safe side, stick
; to 32 sectors (64K) per request.
;
; Input:
;	EAX	- Linear sector number
;	ES:BX	- Target buffer
;	BP	- Sector count
;
getlinsec:
		mov si,dapa			; Load up the DAPA
		mov [si+4],bx
		mov bx,es
		mov [si+6],bx
		mov [si+8],eax
.loop:
		push bp				; Sectors left
		cmp bp,[MaxTransfer]
		jbe .bp_ok
		mov bp,[MaxTransfer]
.bp_ok:
		mov [si+2],bp
		push si
		mov dl,[DriveNo]
		mov ah,42h			; Extended Read
		call xint13
		pop si
		pop bp
		movzx eax,word [si+2]		; Sectors we read
		add [si+8],eax			; Advance sector pointer
		sub bp,ax			; Sectors left
		shl ax,SECTOR_SHIFT-4		; 2048-byte sectors -> segment
		add [si+6],ax			; Advance buffer pointer
		and bp,bp
		jnz .loop
		mov eax,[si+8]			; Next sector
		ret

		; INT 13h with retry
xint13:		mov byte [RetryCount],retry_count
.try:		pushad
		int 13h
		jc .error
		add sp,byte 8*4			; Clean up stack
		ret
.error:
		mov [DiskError],ah		; Save error code
		popad
		mov [DiskSys],ax		; Save system call number
		dec byte [RetryCount]
		jz .real_error
		push ax
		mov al,[RetryCount]
		mov ah,[dapa+2]			; Sector transfer count
		cmp al,2			; Only 2 attempts left
		ja .nodanger
		mov ah,1			; Drop transfer size to 1
		jmp short .setsize
.nodanger:
		cmp al,retry_count-2
		ja .again			; First time, just try again
		shr ah,1			; Otherwise, try to reduce
		adc ah,0			; the max transfer size, but not to 0
.setsize:
		mov [MaxTransfer],ah
		mov [dapa+2],ah
.again:
		pop ax
		jmp .try

.real_error:	mov si,diskerr_msg
		call writemsg
		mov al,[DiskError]
		call writehex2
		mov si,oncall_str
		call writestr
		mov ax,[DiskSys]
		call writehex4
		mov si,ondrive_str
		call writestr
		mov al,dl
		call writehex2
		call crlf
		; Fall through to kaboom

;
; kaboom: write a message and bail out.  Wait for a user keypress,
;	  then do a hard reboot.
;
kaboom:
		lss sp,[cs:Stack]
		mov ax,cs
		mov ds,ax
		mov es,ax
		mov fs,ax
		mov gs,ax
		sti
		mov si,err_bootfailed
		call cwritestr
		call getchar
		cli
		mov word [BIOS_magic],0	; Cold reboot
		jmp 0F000h:0FFF0h	; Reset vector address

; -----------------------------------------------------------------------------
;  Common modules needed in the first sector
; -----------------------------------------------------------------------------

%include "writestr.inc"		; String output
writestr	equ cwritestr
%include "writehex.inc"		; Hexadecimal output

; -----------------------------------------------------------------------------
; Data that needs to be in the first sector
; -----------------------------------------------------------------------------

syslinux_banner	db CR, LF, 'ISOLINUX ', version_str, ' ', date, ' ', 0
copyright_str   db ' Copyright (C) 1994-', year, ' H. Peter Anvin'
		db CR, LF, 0
isolinux_str	db 'isolinux: ', 0
%ifdef DEBUG_MESSAGES
startup_msg:	db 'Starting up, DL = ', 0
spec_ok_msg:	db 'Loaded spec packet OK, drive = ', 0
secsize_msg:	db 'Sector size appears to be ', 0
offset_msg:	db 'Loading main image from LBA = ', 0
size_msg:	db 'Sectors to load = ', 0
loaded_msg:	db 'Loaded boot image, verifying...', CR, LF, 0
verify_msg:	db 'Image checksum verified.', CR, LF, 0
allread_msg	db 'Main image read, jumping to main code...', CR, LF, 0
%endif
noinfotable_msg	db 'No boot info table, assuming single session disk...', CR, LF, 0
noinfoinspec_msg db 'Spec packet missing LBA information, trying to wing it...', CR, LF, 0
spec_err_msg:	db 'Loading spec packet failed, trying to wing it...', CR, LF, 0
maybe_msg:	db 'Found something at drive = ', 0
alright_msg:	db 'Looks like it might be right, continuing...', CR, LF, 0
nospec_msg	db 'Extremely broken BIOS detected, last ditch attempt with drive = ', 0
nothing_msg:	db 'Failed to locate CD-ROM device; boot failed.', CR, LF
trysbm_msg	db 'See http://syslinux.zytor.com/sbm for more information.', CR, LF, 0
diskerr_msg:	db 'Disk error ', 0
oncall_str:	db ', AX = ',0
ondrive_str:	db ', drive ', 0
checkerr_msg:	db 'Image checksum error, sorry...', CR, LF, 0

err_bootfailed	db CR, LF, 'Boot failed: press a key to retry...'
bailmsg		equ err_bootfailed
crlf_msg	db CR, LF
null_msg	db 0

		alignb 4, db 0
Stack		dw _start, 0			; SS:SP for stack reset
MaxTransfer	dw 32				; Max sectors per transfer

rl_checkpt	equ $				; Must be <= 800h

rl_checkpt_off	equ ($-$$)
;%ifndef DEPEND
;%if rl_checkpt_off > 0x800
;%error "Sector 0 overflow"
;%endif
;%endif

; ----------------------------------------------------------------------------
;  End of code and data that have to be in the first sector
; ----------------------------------------------------------------------------

all_read:
;
; Initialize screen (if we're using one)
;
		; Now set up screen parameters
		call adjust_screen

		; Wipe the F-key area
		mov al,NULLFILE
		mov di,FKeyName
		mov cx,10*(1 << FILENAME_MAX_LG2)
		rep stosb

		; Patch the writechr routine to point to the full code
		mov word [writechr+1], writechr_full-(writechr+3)

; Tell the user we got this far...
%ifndef DEBUG_MESSAGES			; Gets messy with debugging on
		mov si,copyright_str
		call writestr
%endif

; Test tracers
		TRACER 'T'
		TRACER '>'

;
; Common initialization code
;
%include "init.inc"
%include "cpuinit.inc"

;
; Now we're all set to start with our *real* business.	First load the
; configuration file (if any) and parse it.
;
; In previous versions I avoided using 32-bit registers because of a
; rumour some BIOSes clobbered the upper half of 32-bit registers at
; random.  I figure, though, that if there are any of those still left
; they probably won't be trying to install Linux on them...
;
; The code is still ripe with 16-bitisms, though.  Not worth the hassle
; to take'm out.  In fact, we may want to put them back if we're going
; to boot ELKS at some point.
;

;
; Now, we need to sniff out the actual filesystem data structures.
; mkisofs gave us a pointer to the primary volume descriptor
; (which will be at 16 only for a single-session disk!); from the PVD
; we should be able to find the rest of what we need to know.
; 
get_fs_structures:
		mov eax,[bi_pvd]
		mov bx,trackbuf
		call getonesec

		mov eax,[trackbuf+156+2]
		mov [RootDir+dir_lba],eax
		mov [CurDir+dir_lba],eax
%ifdef DEBUG_MESSAGES
		mov si,dbg_rootdir_msg
		call writemsg
		call writehex8
		call crlf
%endif
		mov eax,[trackbuf+156+10]
		mov [RootDir+dir_len],eax		
		mov [CurDir+dir_len],eax
		add eax,SECTOR_SIZE-1
		shr eax,SECTOR_SHIFT
		mov [RootDir+dir_clust],eax
		mov [CurDir+dir_clust],eax

		; Look for an isolinux directory, and if found,
		; make it the current directory instead of the root
		; directory.
		mov di,boot_dir			; Search for /boot/isolinux
		mov al,02h
		call searchdir_iso
		jnz .found_dir
		mov di,isolinux_dir
		mov al,02h			; Search for /isolinux
		call searchdir_iso
		jz .no_isolinux_dir
.found_dir:
		mov [CurDir+dir_len],eax
		mov eax,[si+file_left]
		mov [CurDir+dir_clust],eax
		xor eax,eax			; Free this file pointer entry
		xchg eax,[si+file_sector]
		mov [CurDir+dir_lba],eax
%ifdef DEBUG_MESSAGES
		push si
		mov si,dbg_isodir_msg
		call writemsg
		pop si
		call writehex8
		call crlf
%endif
.no_isolinux_dir:

;
; Locate the configuration file
;
load_config:
%ifdef DEBUG_MESSAGES
		mov si,dbg_config_msg
		call writemsg
%endif

		mov di,isolinux_cfg
		call open
		jz no_config_file		; Not found or empty

%ifdef DEBUG_MESSAGES
		mov si,dbg_configok_msg
		call writemsg
%endif

;
; Now we have the config file open.  Parse the config file and
; run the user interface.
;
%include "ui.inc"

;
; Linux kernel loading code is common.
;
%include "runkernel.inc"

;
; COMBOOT-loading code
;
%include "comboot.inc"
%include "com32.inc"
%include "cmdline.inc"

;
; Boot sector loading code
;
%include "bootsect.inc"

;
; Enable disk emulation.  The kind of disk we emulate is dependent on the size of
; the file: 1200K, 1440K or 2880K floppy, otherwise harddisk.
;
is_disk_image:
		TRACER CR
		TRACER LF
		TRACER 'D'
		TRACER ':'

		shl edx,16
		mov dx,ax			; Set EDX <- file size
		mov di,img_table
		mov cx,img_table_count
		mov eax,[si+file_sector]	; Starting LBA of file
		mov [dsp_lba],eax		; Location of file
		mov byte [dsp_drive], 0		; 00h floppy, 80h hard disk
.search_table:
		TRACER 't'
		mov eax,[di+4]
		cmp edx,[di]
		je .type_found
		add di,8
		loop .search_table

		; Hard disk image.  Need to examine the partition table
		; in order to deduce the C/H/S geometry.  Sigh.
.hard_disk_image:
		TRACER 'h'
		cmp edx,512
		jb .bad_image

		mov bx,trackbuf
		mov cx,1			; Load 1 sector
		call getfssec
		
		cmp word [trackbuf+510],0aa55h	; Boot signature
		jne .bad_image		; Image not bootable

		mov cx,4			; 4 partition entries
		mov di,trackbuf+446		; Start of partition table

		xor ax,ax			; Highest sector(al) head(ah)

.part_scan:
		cmp byte [di+4], 0
		jz .part_loop
		lea si,[di+1]
		call .hs_check
		add si,byte 4
		call .hs_check
.part_loop:
		add di,byte 16
		loop .part_scan
		
		push eax			; H/S
		push edx			; File size
		mov bl,ah
		xor bh,bh
		inc bx				; # of heads in BX
		xor ah,ah			; # of sectors in AX
		cwde				; EAX[31:16] <- 0
		mul bx
		shl eax,9			; Convert to bytes
		; Now eax contains the number of bytes per cylinder
		pop ebx				; File size
		xor edx,edx
		div ebx
		and edx,edx
		jz .no_remainder
		inc eax				; Fractional cylinder...
		; Now (e)ax contains the number of cylinders
.no_remainder:	cmp eax,1024
		jna .ok_cyl
		mov ax,1024			; Max possible #
.ok_cyl:	dec ax				; Convert to max cylinder no
		pop ebx				; S(bl) H(bh)
		shl ah,6
		or bl,ah
		xchg ax,bx
		shl eax,16
		mov ah,bl
		mov al,4			; Hard disk boot
		mov byte [dsp_drive], 80h	; Drive 80h = hard disk

.type_found:
		TRACER 'T'
		mov bl,[sp_media]
		and bl,0F0h			; Copy controller info bits
		or al,bl
		mov [dsp_media],al		; Emulation type
		shr eax,8
		mov [dsp_chs],eax		; C/H/S geometry
		mov ax,[sp_devspec]		; Copy device spec
		mov [dsp_devspec],ax
		mov al,[sp_controller]		; Copy controller index
		mov [dsp_controller],al

		TRACER 'V'
		call vgaclearmode		; Reset video

		mov ax,4C00h			; Enable emulation and boot
		mov si,dspec_packet
		mov dl,[DriveNo]
		lss sp,[InitStack]
		TRACER 'X'

		int 13h

		; If this returns, we have problems
.bad_image:
		mov si,err_disk_image
		call cwritestr
		jmp enter_command

;
; Look for the highest seen H/S geometry
; We compute cylinders separately
;
.hs_check:
		mov bl,[si]			; Head #
		cmp bl,ah
		jna .done_track
		mov ah,bl			; New highest head #
.done_track:	mov bl,[si+1]
		and bl,3Fh			; Sector #
		cmp bl,al
		jna .done_sector
		mov al,bl
.done_sector:	ret

;
; Boot a specified local disk.  AX specifies the BIOS disk number; or
; 0xFFFF in case we should execute INT 18h ("next device.")
;
local_boot:
		call vgaclearmode
		lss sp,[cs:Stack]		; Restore stack pointer
		xor dx,dx
		mov ds,dx
		mov es,dx
		mov fs,dx
		mov gs,dx
		mov si,localboot_msg
		call writestr
		cmp ax,-1
		je .int18
		
		; Load boot sector from the specified BIOS device and jump to it.
		mov dl,al
		xor dh,dh
		push dx
		xor ax,ax			; Reset drive
		call xint13
		mov ax,0201h			; Read one sector
		mov cx,0001h			; C/H/S = 0/0/1 (first sector)
		mov bx,trackbuf
		call xint13
		pop dx
		cli				; Abandon hope, ye who enter here
		mov si,trackbuf
		mov di,07C00h
		mov cx,512			; Probably overkill, but should be safe
		rep movsd
		lss sp,[cs:InitStack]
		jmp 0:07C00h			; Jump to new boot sector

.int18:
		int 18h				; Hope this does the right thing...
		jmp kaboom			; If we returned, oh boy...

;
; abort_check: let the user abort with <ESC> or <Ctrl-C>
;
abort_check:
		call pollchar
		jz ac_ret1
		pusha
		call getchar
		cmp al,27			; <ESC>
		je ac_kill
		cmp al,3			; <Ctrl-C>
		jne ac_ret2
ac_kill:	mov si,aborted_msg

;
; abort_load: Called by various routines which wants to print a fatal
;             error message and return to the command prompt.  Since this
;             may happen at just about any stage of the boot process, assume
;             our state is messed up, and just reset the segment registers
;             and the stack forcibly.
;
;             SI    = offset (in _text) of error message to print
;
abort_load:
                mov ax,cs                       ; Restore CS = DS = ES
                mov ds,ax
                mov es,ax
                cli
		lss sp,[cs:Stack]		; Reset the stack
                sti
                call cwritestr                  ; Expects SI -> error msg
al_ok:          jmp enter_command               ; Return to command prompt
;
; End of abort_check
;
ac_ret2:	popa
ac_ret1:	ret


;
; searchdir:
;
;	Open a file
;
;	     On entry:
;		DS:DI	= filename
;	     If successful:
;		ZF clear
;		SI		= file pointer
;		DX:AX or EAX	= file length in bytes
;	     If unsuccessful
;		ZF set
;

;
; searchdir_iso is a special entry point for ISOLINUX only.  In addition
; to the above, searchdir_iso passes a file flag mask in AL.  This is useful
; for searching for directories.
;
alloc_failure:
		xor ax,ax			; ZF <- 1
		ret

searchdir:
		xor al,al
searchdir_iso:
		mov [ISOFlags],al
		TRACER 'S'
		call allocate_file		; Temporary file structure for directory
		jnz alloc_failure
		push es
		push ds
		pop es				; ES = DS
		mov si,CurDir
		cmp byte [di],'/'		; If filename begins with slash
		jne .not_rooted
		inc di				; Skip leading slash
		mov si,RootDir			; Reference root directory instead
.not_rooted:
		mov eax,[si+dir_clust]
		mov [bx+file_left],eax
		mov eax,[si+dir_lba]
		mov [bx+file_sector],eax
		mov edx,[si+dir_len]

.look_for_slash:
		mov ax,di
.scan:
		mov cl,[di]
		inc di
		and cl,cl
		jz .isfile
		cmp cl,'/'
		jne .scan
		mov [di-1],byte 0		; Terminate at directory name
		mov cl,02h			; Search for directory
		xchg cl,[ISOFlags]

		push di				; Save these...
		push cx

		; Create recursion stack frame...
		push word .resume		; Where to "return" to
		push es
.isfile:	xchg ax,di

.getsome:
		; Get a chunk of the directory
		; This relies on the fact that ISOLINUX doesn't change SI
		mov si,trackbuf
		TRACER 'g'
		pushad
		xchg bx,si
		mov cx,[BufSafe]
		call getfssec
		popad

.compare:
		movzx eax,byte [si]		; Length of directory entry
		cmp al,33
		jb .next_sector
		TRACER 'c'
		mov cl,[si+25]
		xor cl,[ISOFlags]
		test cl, byte 8Eh		; Unwanted file attributes!
		jnz .not_file
		pusha
		movzx cx,byte [si+32]		; File identifier length
		add si,byte 33			; File identifier offset
		TRACER 'i'
		call iso_compare_names
		popa
		je .success
.not_file:
		sub edx,eax			; Decrease bytes left
		jbe .failure
		add si,ax			; Advance pointer

.check_overrun:
		; Did we finish the buffer?
		cmp si,trackbuf+trackbufsize
		jb .compare			; No, keep going

		jmp short .getsome		; Get some more directory

.next_sector:
		; Advance to the beginning of next sector
		lea ax,[si+SECTOR_SIZE-1]
		and ax,~(SECTOR_SIZE-1)
		sub ax,si
		jmp short .not_file		; We still need to do length checks

.failure:	xor eax,eax			; ZF = 1
		mov [bx+file_sector],eax
		pop es
		ret

.success:
		mov eax,[si+2]			; Location of extent
		mov [bx+file_sector],eax
		mov eax,[si+10]			; Data length
		push eax
		add eax,SECTOR_SIZE-1
		shr eax,SECTOR_SHIFT
		mov [bx+file_left],eax
		pop eax
		mov edx,eax
		shr edx,16
		and bx,bx			; ZF = 0
		mov si,bx
		pop es
		ret

.resume:	; We get here if we were only doing part of a lookup
		; This relies on the fact that .success returns bx == si
		xchg edx,eax			; Directory length in edx
		pop cx				; Old ISOFlags
		pop di				; Next filename pointer
		mov byte [di-1], '/'		; Restore slash
		mov [ISOFlags],cl		; Restore the flags
		jz .failure			; Did we fail?  If so fail for real!
		jmp .look_for_slash		; Otherwise, next level

;
; allocate_file: Allocate a file structure
;
;		If successful:
;		  ZF set
;		  BX = file pointer
;		In unsuccessful:
;		  ZF clear
;
allocate_file:
		TRACER 'a'
		push cx
		mov bx,Files
		mov cx,MAX_OPEN
.check:		cmp dword [bx], byte 0
		je .found
		add bx,open_file_t_size		; ZF = 0
		loop .check
		; ZF = 0 if we fell out of the loop
.found:		pop cx
		ret

;
; iso_compare_names: 
;	Compare the names DS:SI and DS:DI and report if they are
;	equal from an ISO 9660 perspective.  SI is the name from
;	the filesystem; CX indicates its length, and ';' terminates.
;	DI is expected to end with a null.
;
;	Note: clobbers AX, CX, SI, DI; assumes DS == ES == base segment
;

iso_compare_names:
		; First, terminate and canonicalize input filename
		push di
		mov di,ISOFileName
.canon_loop:	jcxz .canon_end
		lodsb
		dec cx
		cmp al,';'
		je .canon_end
		and al,al
		je .canon_end
		stosb
		cmp di,ISOFileNameEnd-1		; Guard against buffer overrun
		jb .canon_loop
.canon_end:
		cmp di,ISOFileName
		jbe .canon_done
		cmp byte [di-1],'.'		; Remove terminal dots
		jne .canon_done
		dec di
		jmp short .canon_end
.canon_done:
		mov [di],byte 0			; Null-terminate string
		pop di
		mov si,ISOFileName
.compare:
		lodsb
		mov ah,[di]
		inc di
		and ax,ax
		jz .success			; End of string for both
		and al,al			; Is either one end of string?
		jz .failure			; If so, failure
		and ah,ah
		jz .failure
		or ax,2020h			; Convert to lower case
		cmp al,ah
		je .compare
.failure:	and ax,ax			; ZF = 0 (at least one will be nonzero)
.success:	ret

;
; mangle_name: Mangle a filename pointed to by DS:SI into a buffer pointed
;	       to by ES:DI; ends on encountering any whitespace.
;
;	       This verifies that a filename is < FILENAME_MAX characters,
;	       doesn't contain whitespace, zero-pads the output buffer,
;	       and removes trailing dots and redundant slashes,
;	       so "repe cmpsb" can do a compare, and the
;	       path-searching routine gets a bit of an easier job.
;	       
mangle_name:
		push bx
		xor ax,ax
		mov cx,FILENAME_MAX-1
		mov bx,di

.mn_loop:
		lodsb
		cmp al,' '			; If control or space, end
		jna .mn_end
		cmp al,ah			; Repeated slash?
		je .mn_skip
		xor ah,ah
		cmp al,'/'
		jne .mn_ok
		mov ah,al
.mn_ok		stosb
.mn_skip:	loop .mn_loop
.mn_end:
		cmp bx,di			; At the beginning of the buffer?
		jbe .mn_zero
		cmp byte [di-1],'.'		; Terminal dot?
		je .mn_kill
		cmp byte [di-1],'/'		; Terminal slash?
		jne .mn_zero
.mn_kill:	dec di				; If so, remove it
		inc cx
		jmp short .mn_end
.mn_zero:
		inc cx				; At least one null byte
		xor ax,ax			; Zero-fill name
		rep stosb
		pop bx
		ret				; Done

;
; unmangle_name: Does the opposite of mangle_name; converts a DOS-mangled
;                filename to the conventional representation.  This is needed
;                for the BOOT_IMAGE= parameter for the kernel.
;                NOTE: A 13-byte buffer is mandatory, even if the string is
;                known to be shorter.
;
;                DS:SI -> input mangled file name
;                ES:DI -> output buffer
;
;                On return, DI points to the first byte after the output name,
;                which is set to a null byte.
;
unmangle_name:	call strcpy
		dec di				; Point to final null byte
		ret

;
; getfssec: Get multiple clusters from a file, given the file pointer.
;
;  On entry:
;	ES:BX	-> Buffer
;	SI	-> File pointer
;	CX	-> Cluster count
;  On exit:
;	SI	-> File pointer (or 0 on EOF)
;	CF = 1	-> Hit EOF
;
getfssec:
		TRACER 'F'

		push ds
		push cs
		pop ds				; DS <- CS

		movzx ecx,cx
		cmp ecx,[si+file_left]
		jna .ok_size
		mov ecx,[si+file_left]
.ok_size:

		mov bp,cx
		push cx
		push si
		mov eax,[si+file_sector]
		TRACER 'l'
		call getlinsec
		xor ecx,ecx
		pop si
		pop cx

		add [si+file_sector],ecx
		sub [si+file_left],ecx
		ja .not_eof			; CF = 0

		xor ecx,ecx
		mov [si+file_sector],ecx	; Mark as unused
		xor si,si
		stc

.not_eof:
		pop ds
		TRACER 'f'
		ret

; -----------------------------------------------------------------------------
;  Common modules
; -----------------------------------------------------------------------------

%include "getc.inc"		; getc et al
%include "conio.inc"		; Console I/O
%include "parseconfig.inc"	; High-level config file handling
%include "parsecmd.inc"		; Low-level config file handling
%include "bcopy32.inc"		; 32-bit bcopy
%include "loadhigh.inc"		; Load a file into high memory
%include "font.inc"		; VGA font stuff
%include "graphics.inc"		; VGA graphics
%include "highmem.inc"		; High memory sizing
%include "strcpy.inc"		; strcpy()
%include "rawcon.inc"		; Console I/O w/o using the console functions

; -----------------------------------------------------------------------------
;  Begin data section
; -----------------------------------------------------------------------------

		section .data

boot_prompt	db 'boot: ', 0
wipe_char	db BS, ' ', BS, 0
err_notfound	db 'Could not find kernel image: ',0
err_notkernel	db CR, LF, 'Invalid or corrupt kernel image.', CR, LF, 0
err_noram	db 'It appears your computer has less than '
		asciidec dosram_k
		db 'K of low ("DOS")'
		db CR, LF
		db 'RAM.  Linux needs at least this amount to boot.  If you get'
		db CR, LF
		db 'this message in error, hold down the Ctrl key while'
		db CR, LF
		db 'booting, and I will take your word for it.', CR, LF, 0
err_badcfg      db 'Unknown keyword in config file.', CR, LF, 0
err_noparm      db 'Missing parameter in config file.', CR, LF, 0
err_noinitrd    db CR, LF, 'Could not find ramdisk image: ', 0
err_nohighmem   db 'Not enough memory to load specified kernel.', CR, LF, 0
err_highload    db CR, LF, 'Kernel transfer failure.', CR, LF, 0
err_oldkernel   db 'Cannot load a ramdisk with an old kernel image.'
                db CR, LF, 0
err_notdos	db ': attempted DOS system call', CR, LF, 0
err_comlarge	db 'COMBOOT image too large.', CR, LF, 0
err_bssimage	db 'BSS images not supported.', CR, LF, 0
err_a20		db CR, LF, 'A20 gate not responding!', CR, LF, 0
notfound_msg	db 'not found', CR, LF, 0
localboot_msg	db 'Booting from local disk...', CR, LF, 0
cmdline_msg	db 'Command line: ', CR, LF, 0
ready_msg	db 'Ready.', CR, LF, 0
trying_msg	db 'Trying to load: ', 0
crlfloading_msg	db CR, LF			; Fall through
loading_msg     db 'Loading ', 0
dotdot_msg      db '.'
dot_msg         db '.', 0
fourbs_msg	db BS, BS, BS, BS, 0
aborted_msg	db ' aborted.', CR, LF, 0
crff_msg	db CR, FF, 0
default_str	db 'default', 0
default_len	equ ($-default_str)
boot_dir	db '/boot'			; /boot/isolinux
isolinux_dir	db '/isolinux', 0
ConfigName	equ $
isolinux_cfg	db 'isolinux.cfg', 0
err_disk_image	db 'Cannot load disk image (invalid file)?', CR, LF, 0

%ifdef DEBUG_MESSAGES
dbg_rootdir_msg	db 'Root directory at LBA = ', 0
dbg_isodir_msg	db 'isolinux directory at LBA = ', 0
dbg_config_msg	db 'About to load config file...', CR, LF, 0
dbg_configok_msg	db 'Configuration file opened...', CR, LF, 0
%endif
;
; Command line options we'd like to take a look at
;
; mem= and vga= are handled as normal 32-bit integer values
initrd_cmd	db 'initrd='
initrd_cmd_len	equ 7

;
; Config file keyword table
;
%include "keywords.inc"

;
; Extensions to search for (in *forward* order).
;
		align 4, db 0
exten_table:	db '.cbt'		; COMBOOT (specific)
		db '.img'		; Disk image
		db '.bin'		; CD boot sector
		db '.com'		; COMBOOT (same as DOS)
		db '.c32'		; COM32
exten_table_end:
		dd 0, 0			; Need 8 null bytes here

;
; Floppy image table
;
		align 4, db 0
img_table_count	equ 3
img_table:
		dd 1200*1024		; 1200K floppy
		db 1			; Emulation type
		db 80-1			; Max cylinder
		db 15			; Max sector
		db 2-1			; Max head

		dd 1440*1024		; 1440K floppy
		db 2			; Emulation type
		db 80-1			; Max cylinder
		db 18			; Max sector
		db 2-1			; Max head

		dd 2880*1024		; 2880K floppy
		db 3			; Emulation type
		db 80-1			; Max cylinder
		db 36			; Max sector
		db 2-1			; Max head

;
; Misc initialized (data) variables
;

;
; Variables that are uninitialized in SYSLINUX but initialized here
;
; **** ISOLINUX:: We may have to make this flexible, based on what the
; **** BIOS expects our "sector size" to be.
;
		alignb 4, db 0
BufSafe		dw trackbufsize/SECTOR_SIZE	; Clusters we can load into trackbuf
BufSafeSec	dw trackbufsize/SECTOR_SIZE	; = how many sectors?
BufSafeBytes	dw trackbufsize		; = how many bytes?
EndOfGetCBuf	dw getcbuf+trackbufsize	; = getcbuf+BufSafeBytes
%ifndef DEPEND
%if ( trackbufsize % SECTOR_SIZE ) != 0
%error trackbufsize must be a multiple of SECTOR_SIZE
%endif
%endif
