/*
 *  afp_srvrtime.h
 */

#ifndef AFP_SRVRTIME_H
#define AFP_SRVRTIME_H

#include <time.h>

struct afp_server;

int afp_getsrvrtime(struct afp_server *server, time_t *server_time);

#endif
