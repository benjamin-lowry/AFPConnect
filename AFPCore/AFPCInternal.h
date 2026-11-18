//
//  AFPCInternal.h
//  AFPCore
//
//  Created by Benjamin Lowry on 2026-11-07.
//
//  This file pulls in libafpclient's private headers
//  Below is a list of all the private functions we use (keep this up to date if you begin use of a new private function):
//
//  setup      libafpclient_register, init_uams, afp_main_quick_startup,
//             afp_wait_for_started_loop
//  servers    afp_parse_url, afp_default_url, afp_server_full_connect,
//             afp_server_hold, afp_server_release, afp_logout,
//             afp_server_remove, afp_server_fill_basic,
//             afp_set_auto_disconnect_on_unmount, afp_zzzzz,
//             afp_server_set_suspended, loop_disconnect
//  dsi        afpc_dsi_setup_header, afpc_dsi_send, DSI_DSICloseSession
//  volumes    find_volume_by_name, afp_connect_volume, afp_unmount_volume,
//             afp_volclose, afp_detect_mapping
//  names      afp_set_longname_encoding (not present upstream)
//  files      ml_*, ll_open, ll_read, ll_write, ll_setfork_size,
//             afp_getfiledirparms, afp_setfiledirparms, get_dirid,
//             convert_path_to_afp, afp_openfork, add_opened_fork,
//             ll_openfork_errno
//  structs    afp_server (connect_state, SERVER_STATE_*), afp_volume,
//             afp_file_info, afpc_url, afp_connection_request
//

#ifndef AFPCInternal_h
#define AFPCInternal_h

#include "afp_internal.h"
#include "client.h"
#include "codepage.h"
#include "did.h"
#include "dsi.h"
#include "dsi_protocol.h"
#include "forklist.h"
#include "lowlevel.h"
#include "midlevel.h"
#include "resource.h"
#include "users.h"
#include "utils.h"

#include "afp_srvrtime.h"

// Defined in afp.c but ommitted from its headers
void afp_set_auto_disconnect_on_unmount(int enabled);

#endif // AFPCInternal_h
