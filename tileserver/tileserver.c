/*
 * tileserver.c:
 * Serve map tiles and information about map tiles.
 *
 * Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
 * Email: chris@mysociety.org; WWW: http://www.mysociety.org/
 *
 */

static const char rcsid[] = "$Id: tileserver.c,v 1.1 2006-09-20 10:25:14 chris Exp $";

/* 
 * This is slightly complicated by the fact that we indirect tile references
 * via hashes of the tiles themselves. We support the following queries:
 *
 * http://host/path/tileserver/TILESET/HASH
 *      to get an individual tile image in TILESET identified by HASH;
 * http://host/path/tileserver/TILESET/E,N/FORMAT
 *      to get the identity of the tile at (E, N) in TILESET in the given
 *      FORMAT;
 * http://host/path/tileserver/TILESET/W-E,S-N/FORMAT
 *      to get the identities of the tiles in the block with SW corner (W, S)
 *      and NE corner (E, N) in the given FORMAT.
 * 
 * What FORMATS should we support? RABX and JSON are the obvious ones I guess.
 */

#include "tileset.h"

/* tileset_path
 * The configured path to tilesets. */
char *tileset_path;

#define HTTP_BAD_REQUEST            400
#define HTTP_UNAUTHORIZED           401
#define HTTP_FORBIDDEN              403
#define HTTP_NOT_FOUND              404
#define HTTP_INTERNAL_SERVER_ERROR  500
#define HTTP_NOT_IMPLEMENTED        501
#define HTTP_SERVICE_UNAVAILABLE    503

/* err FORMAT [ARG ...]
 * Write an error message to standard error. */
#define err(...)    \
        do { \
            fprintf(stderr, "tileserver: "); \
            fprintf(stderr, __VA_ARGS__); \
            fprintf(stderr, "\n"); \
        } while (0)

/* die FORMAT [ARG ...]
 * Write an error message to standard error and exit unsuccessfully. */
#define die(...) do { err(__VA_ARGS__); exit(1); } while (0)

/* error STATUS TEXT
 * Send an error to the client with the given HTTP STATUS and TEXT. */
void error(int status, const char *s) {
    if (status < 100 || status > 999)
        status = 500;
    printf(
        "Status: %03d\r\n"
        "Content-Type: text/plain; charset=us-ascii\r\n"
        "Content-Length: %u\r\n"
        "\r\n"
        "%s\n",
        status,
        strlen(s) + 1);
}

/* struct request
 * Definition of a request we handle. */
struct request {
    char *r_tileset;
    enum {
        FN_GET_TILE = 0,
        FN_GET_TILEIDS
    } r_function;

    uint8_t r_tilehash[TILEHASH_LEN];

    int r_west, r_east, r_south, r_north;
    enum {
        F_RABX,
        F_JSON,
        F_TEXT
    } r_format;

    char *r_buf;
};

/* request_parse PATHINFO
 * Parse a request from PATHINFO. Returns a request on success or NULL on
 * failure. */
struct request *request_parse(const char *path_info) {
    const char *p, *q;
    struct request *R = NULL, Rz = {0};

    /* Some trivial syntax checks. */
    if (!*path_info || *path_info == '/' || !strchr(path_info, '/'))
        return NULL;
    
   
    /* 
     * TILESET/HASH
     * TILESET/E,N/FORMAT
     * TILESET/W-E,S-N/FORMAT
     */

    /* Tileset name consists of alphanumerics and hyphen. */
    p = path_info + strspn(path_info,
                            "0123456789"
                            "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                            "abcdefghijklmnopqrstuvwxyz"
                            "-");

    if (*p != '/')
        return NULL;

    R = xmalloc(sizeof *R);
    *R = Rz;
    R->r_buf = xmalloc(strlen(path_info) + 1);
    R->r_tileset = R->r_buf;

    strncpy(R->r_tileset, path_info, p - path_info);
    R->r_tileset[p - path_info] = 0;

    ++p;

    /* Mode. */
    if ((q = strchr(p, '/'))) {
        /* Tile IDs request. */
        R->r_function = FN_GET_TILEIDS;

        /* Identify format requested. */
        ++q;
        if (!strcmp(q, "RABX"))
            R->r_format = F_RABX;
        else if (!strcmp(q, "JSON"))
            R->r_format = F_JSON;
        else if (!strcmp(q, "text"))
            R->r_format = F_TEXT;
        else
            goto fail;

        if (4 == sscanf(p, "%d-%d,%d-%d",
                        &R->r_west, &R->r_east, &R->r_south, &R->r_north)) {
            if (R->r_west < 0 || R->r_south < 0
                || R->r_east < R->r_west || R->r_north < R->r_south)
                goto fail;
            else
                return R;
        } else if (2 == sscanf(p, "%d,%d", &R->r_west, &R->r_south)) {
            R->r_east = R->r_west;
            R->r_north = R->r_south;
            if (R->r_west < 0 || R->r_south < 0)
                goto fail;
            else
                return R;
        }
    } else {
        size_t l;

        /* Tile request. */
        R->r_function = FN_GET_TILE;
        if (strlen(p) != TILEID_LEN_B64)
            goto fail;

        /* Decode it. Really this is "base64ish", so that we don't have to
         * deal with '+' or '/' in the URL. */
        base64_decode(p, R->r_tilehash, &l, 1);
        if (l != TILEID_LEN)
            goto fail;

        return R;
    }
    
fail:
    request_free(R);
    return NULL;
}

void request_free(struct request *R) {
    if (!R) return;
    xfree(R->r_buf);
    xfree(R);
}

void handle_request(void) {
    char *path_info;
    struct request *R;
    static char *path;
    static size_t pathlen;
    size_t l;
    tileset T;
    time_t when;
    struct tm tm;
    char timebuf[32];

    /* All requests are given via PATH_INFO. */
    if (!(path_info = getenv("PATH_INFO"))) {
        error(400, "No request path supplied");
        return;
    }

    if (!(R = request_parse(path_info))) {
        error(400, "Bad request");
        return;
    }

    /* So we have a valid request. */
    l = strlen(R->r_tileset) + strlen(tileset_path) + 2;
    if (pathlen < l)
        pathlen = xrealloc(path, pathlen = l);
    sprintf(path, "%s/%s", tileset_path, R->r_tileset);
    
    if (!(T = tileset_open(path))) {
        error(404, "Tileset not found");
            /* XXX assumption about the nature of the error */
        return;
    }

    if (FN_GET_TILE == R->r_function) {
        /* 
         * Send a single tile image to the client.
         */
        void *buf;
        size_t len;

        if ((buf = tileset_get_tile(T, T->r_tileid, &len))) {
            printf(
                "Content-Type: image/png\r\n"
                "Content-Length: %u\r\n"
                "\r\n");
            fwrite(stdout, 1, buf, len);
            xfree(buf);
        } else
            error(404, "Tile not found");
                /* XXX error assumption */
    } else if (FN_GET_TILEIDS = R->r_function) {
        /*
         * Send one or more tile IDs to the client, in some useful format.
         */
        unsigned x, y;
        static char *buf;
        static size_t buflen, n;
        unsigned rows, cols;
        char *p;

        rows = R->r_north + 1 - R->r_south;
        cols = R->r_east + 1 - R->r_west;
        n = cols * rows;
        if (buflen < n * TILEID_LEN_B64 + 256)
            buf = xrealloc(buf, buflen = n * TILEID_LEN_B64 + 256);

        /* Send start of array in whatever format. */
        p = buf;
        switch (R->r_format) {
            case F_RABX:
                /* Format as array of arrays. */
                *(p++) = 'L';
                p += netstring_write_int(p, (int)rows);
                break;

            case F_JSON:
                /* Ditto. */
                *(p++) = '[';
                break;

            case F_TEXT:
                /* Space and LF separated matrix so no special leader. */
                break;
        }

        /* Iterate over tile IDs. */
        for (y = R->r_south; y <= R->r_north; ++y) {
            switch (R->r_format) {
                case F_RABX:
                    *(p++) = 'L';
                    p += netstring_write_int(p, (int)cols);

                case F_JSON:
                    *(p++) = '[';

                case F_TEXT:
                    break;  /* nothing */
            }
            
            for (x = R->r_west; x <= R->r_east; ++x) {
                uint8_t id[TILEID_LEN];
                char idb64[TILEID_LEN_B64 + 1];
                bool isnull = 0;
                size_t l;
                
                if (!(tileset_get_tileid(T, x, y, id)))
                    isnull = 1;
                else
                    base64_encode(id, TILEID_LEN, idb64, 1, 1);

                if (p + 256 > buflen) {
                    size_t n;
                    n = p - buf;
                    buf = xrealloc(buf, buflen *= 2);
                    p = buf + n;
                }

                switch (R->r_format) {
                    case F_RABX:
                        if (isnull) {
                            *(p++) = 'T';
                            p += netstring_write(p, idb64);
                        } else
                            *(p++) = 'N';
                        break;

                    case F_JSON:
                        if (isnull) {
                            strcpy(p, "null");
                            p += 4;
                        } else {
                            *(p++) = '"';
                            strcpy(p, idb64);
                            p += TILEID_LEN_B64;
                            *(p++) = '"';
                        }
                        if (x < R->r_east)
                            *(p++) = ',';
                        break;

                    case F_TEXT:
                        if (isnull)
                            *(p++) = '-';
                        else {
                            strcpy(p, idb64);
                            p += TILEID_LEN_B64;
                        }
                        if (x < R->r_east)
                            *(p++) = ' ';
                        break;
                }
            }

            switch (R->r_format) {
                case F_RABX:
                    break;  /* no row terminator */

                case F_JSON:
                    *(p++) = ']';
                    if (y < R->r_north)
                        *(p++) = ',';
                    break;

                case F_TEXT:
                    *(p++) = '\n';
                    break;
            }
        }

        /* Array terminator. */
        switch (R->r_format) {
            case F_RABX:
                break;

            case F_JSON:
                *(p++) = ']';
                break;
                
            case F_TEXT:
                *(p++) = '\n';
                break;
        }
        *(p++) = 0;

        /* Actually send it. */
        printf("Content-Type: ");
        switch (R->r_format) {
            case F_RABX:
                printf("application/octet-stream");
                break;

            case F_JSON:
                /* Not really clear what CT to use here but Yahoo use
                 * "text/javascript" and presumably they've done more testing
                 * than us.... */
                printf("text/javascript");
                break;

            case F_TEXT:
                printf("text/plain; charset=us-ascii");
                break;
        }
        printf("\r\n"
            "Content-Length: %u\r\n"
            "\r\n",
            (unsigned)(p - buf));

        fwrite(buf, 1, p - buf, stdout);
    }
}

int main(int argc, char *argv[]) {
    struct stat st;
    
    if (2 != argc) {
        die("single argument is path to tile sets");
    }
    tileset_path = argv[1];
    if (-1 == stat(tileset_path, &st))
        die("%s: stat: %s", tileset_path, strerror(errno));
    else if (!S_ISDIR(st.st_mode))
        die("%s: Not a directory", tileset_path);

    while (FCGI_Accept() >= 0)
        handle_request();

    return 0;
}