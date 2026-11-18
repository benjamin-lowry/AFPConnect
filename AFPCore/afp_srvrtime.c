/*
 *  afp_srvrtime.c
 */

#include <stdlib.h>
#include <string.h>

#include "afp_internal.h"
#include "afp_protocol.h"
#include "dsi.h"
#include "dsi_protocol.h"

#include "afp_srvrtime.h"

#define SRVRPARMS_REPLY_MAX 65536

int afp_getsrvrtime(struct afp_server *server, time_t *server_time)
{
    struct {
        struct dsi_header dsi_header __attribute__((__packed__));
        uint8_t command;
    } __attribute__((__packed__)) request;
    struct dsi_header hdr;
    struct afp_rx_buffer rx;
    uint32_t date;
    int rc;

    if (!server || !server_time) {
        return -EINVAL;
    }

    memset(&rx, 0, sizeof(rx));
    rx.maxsize = SRVRPARMS_REPLY_MAX;
    rx.data = malloc(rx.maxsize);

    if (!rx.data) {
        return -ENOMEM;
    }

    afpc_dsi_setup_header(server, &hdr, DSI_DSICommand);
    memcpy(&request.dsi_header, &hdr, sizeof(struct dsi_header));
    request.command = afpGetSrvrParms;

    rc = afpc_dsi_send(server, (char *) &request, sizeof(request),
                       DSI_DEFAULT_TIMEOUT, afpLogin, &rx);

    if (rc == kFPNoErr) {
        if (rx.size < sizeof(date)) {
            rc = -EPROTO;
        } else {
            memcpy(&date, rx.data, sizeof(date));
            *server_time = afp_date_to_unix(NULL, date);
        }
    }

    free(rx.data);
    return rc;
}
