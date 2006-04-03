#ident "$Id: menu.h,v 1.5 2005/01/21 00:49:46 hpa Exp $"
/* ----------------------------------------------------------------------- *
 *   
 *   Copyright 2004 H. Peter Anvin - All Rights Reserved
 *
 *   This program is free software; you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, Inc., 53 Temple Place Ste 330,
 *   Boston MA 02111-1307, USA; either version 2 of the License, or
 *   (at your option) any later version; incorporated herein by reference.
 *
 * ----------------------------------------------------------------------- */

/*
 * menu.h
 *
 * Header file for the simple menu system
 */

#ifndef MENU_H
#define MENU_H

struct menu_entry {
  char *displayname;
  char *label;
  char *cmdline;
  char *passwd;
  unsigned char hotkey;
};

#define MAX_CMDLINE_LEN	 256

#define MAX_ENTRIES	4096	/* Oughta be enough for anybody */
extern struct menu_entry menu_entries[];
extern struct menu_entry *menu_hotkeys[256];

extern int nentries;
extern int defentry;
extern int allowedit;
extern int timeout;

extern char *menu_title;
extern char *ontimeout;
extern char *menu_master_passwd;

void parse_config(const char *filename);

#endif /* MENU_H */

