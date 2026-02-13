/*
 * sic-watcher — lightweight directory watcher using macOS kqueue
 *
 * Watches a single directory for new files and outputs their paths.
 * Drop-in replacement for fswatch in the screenshot-watcher pipeline.
 *
 * Usage: sic-watcher [-0] <directory>
 *   -0    Null-terminated output (like fswatch -0)
 *
 * Requires: macOS (kqueue). No third-party dependencies.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/types.h>

/* Maximum files we track in the seen-set */
#define MAX_SEEN 4096

static volatile sig_atomic_t g_running = 1;

static void handle_signal(int sig) {
    (void)sig;
    g_running = 0;
}

/* Simple inode tracking to detect new files */
static ino_t seen_inodes[MAX_SEEN];
static int   seen_count = 0;

static int is_seen(ino_t inode) {
    for (int i = 0; i < seen_count; i++) {
        if (seen_inodes[i] == inode)
            return 1;
    }
    return 0;
}

static void mark_seen(ino_t inode) {
    if (seen_count < MAX_SEEN) {
        seen_inodes[seen_count++] = inode;
    } else {
        /* Wrap around — shouldn't happen with typical screenshot dirs */
        memmove(seen_inodes, seen_inodes + 1, (MAX_SEEN - 1) * sizeof(ino_t));
        seen_inodes[MAX_SEEN - 1] = inode;
    }
}

/*
 * Scan directory, report files not in the seen set.
 * Returns number of new files found.
 */
static int scan_and_report(const char *dirpath, int null_term) {
    DIR *d = opendir(dirpath);
    if (!d)
        return 0;

    int found = 0;
    struct dirent *entry;

    while ((entry = readdir(d)) != NULL) {
        /* Skip . and .. and hidden files */
        if (entry->d_name[0] == '.')
            continue;

        /* Build full path */
        char fullpath[PATH_MAX];
        snprintf(fullpath, sizeof(fullpath), "%s/%s", dirpath, entry->d_name);

        struct stat st;
        if (stat(fullpath, &st) != 0)
            continue;

        /* Only report regular files */
        if (!S_ISREG(st.st_mode))
            continue;

        if (!is_seen(st.st_ino)) {
            mark_seen(st.st_ino);
            /* Output the path */
            fputs(fullpath, stdout);
            if (null_term)
                fputc('\0', stdout);
            else
                fputc('\n', stdout);
            fflush(stdout);
            found++;
        }
    }

    closedir(d);
    return found;
}

static void usage(const char *progname) {
    fprintf(stderr, "Usage: %s [-0] <directory>\n", progname);
    fprintf(stderr, "  -0    Null-terminated output\n");
    exit(1);
}

int main(int argc, char *argv[]) {
    int null_term = 0;
    const char *dirpath = NULL;

    /* Parse arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-0") == 0) {
            null_term = 1;
        } else if (argv[i][0] == '-') {
            usage(argv[0]);
        } else {
            dirpath = argv[i];
        }
    }

    if (!dirpath)
        usage(argv[0]);

    /* Set up signal handlers for clean shutdown */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    /* Open the directory */
    int dirfd = open(dirpath, O_RDONLY | O_DIRECTORY);
    if (dirfd < 0) {
        fprintf(stderr, "sic-watcher: cannot open '%s': %s\n",
                dirpath, strerror(errno));
        return 1;
    }

    /* Create kqueue */
    int kq = kqueue();
    if (kq < 0) {
        perror("sic-watcher: kqueue");
        close(dirfd);
        return 1;
    }

    /* Register EVFILT_VNODE on the directory for NOTE_WRITE events.
     * NOTE_WRITE fires when files are created, deleted, or renamed
     * within the directory — exactly what we need. */
    struct kevent change;
    EV_SET(&change, dirfd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE, 0, NULL);

    if (kevent(kq, &change, 1, NULL, 0, NULL) < 0) {
        perror("sic-watcher: kevent register");
        close(kq);
        close(dirfd);
        return 1;
    }

    /* Initial scan — populate seen set with existing files (don't report them) */
    {
        DIR *d = opendir(dirpath);
        if (d) {
            struct dirent *entry;
            while ((entry = readdir(d)) != NULL) {
                if (entry->d_name[0] == '.')
                    continue;
                char fullpath[PATH_MAX];
                snprintf(fullpath, sizeof(fullpath), "%s/%s",
                         dirpath, entry->d_name);
                struct stat st;
                if (stat(fullpath, &st) == 0 && S_ISREG(st.st_mode)) {
                    mark_seen(st.st_ino);
                }
            }
            closedir(d);
        }
    }

    /* Main event loop */
    while (g_running) {
        struct kevent event;
        struct timespec timeout = { 1, 0 };  /* 1 second timeout for signal check */

        int n = kevent(kq, NULL, 0, &event, 1, &timeout);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            perror("sic-watcher: kevent wait");
            break;
        }

        if (n > 0) {
            /* Directory changed — scan for new files.
             * Small delay to let macOS finish writing (e.g., screenshot rename). */
            usleep(50000);  /* 50ms */
            scan_and_report(dirpath, null_term);
        }
    }

    close(kq);
    close(dirfd);
    return 0;
}
